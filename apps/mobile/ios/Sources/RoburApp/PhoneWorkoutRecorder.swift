import Combine
import Foundation
import HealthKit
import UIKit

/// A manually controlled phone/iPad timer. Sensor-based workouts run on Apple Watch.
/// HKWorkoutBuilder is available on iOS 17; an iOS HKWorkoutSession is not required.
@MainActor
final class PhoneWorkoutRecorder: ObservableObject {
  static let shared = PhoneWorkoutRecorder()

  @Published private(set) var phase: WorkoutRecordingPhase = .idle
  @Published private(set) var error: String?
  @Published private(set) var saveNotice: String?
  @Published private(set) var lastWorkout: WorkoutRecord?
  @Published private(set) var activity: WorkoutActivity = .functionalStrength
  @Published var muscleGroups: Set<MuscleGroup> = [] { didSet { persistDraft() } }
  @Published var notes = "" { didSet { persistDraft() } }
  @Published private(set) var pendingActivity: WorkoutActivity?
  @Published var presentationRequested = false
  @Published private(set) var watchLaunchInProgress = false
  @Published private(set) var watchMessage: String?

  private let store: HKHealthStore
  private let defaults: UserDefaults
  private let draftKey = "RoburPhoneWorkoutDraft.v1"
  private var recordingID = UUID()
  private struct Draft: Codable {
    let id: UUID
    let activity: WorkoutActivity
    let clock: WorkoutRecordingClock
    let pauseDates: [Date]
    let pauseKinds: [Bool]
    let stoppedAt: Date?
    let muscles: Set<MuscleGroup>
    let notes: String
  }
  private var builder: HKWorkoutBuilder?
  private var clock: WorkoutRecordingClock?
  private var events: [HKWorkoutEvent] = []
  private var stoppedAt: Date?
  private var eventsAdded = false
  private var metadataAdded = false
  private var collectionEnded = false

  var hasStopped: Bool { stoppedAt != nil }
  var canResume: Bool { phase == .paused && !hasStopped }
  var canFinish: Bool { (phase == .running || phase == .paused) && clock != nil }
  var isActive: Bool { phase == .running || phase == .paused || phase == .saving || phase == .preparing }
  var supportsWatchLaunch: Bool { UIDevice.current.userInterfaceIdiom == .phone }
  var startedAt: Date? { clock?.startedAt }

  init(store: HKHealthStore = HKHealthStore(), defaults: UserDefaults = .standard) {
    self.store = store
    self.defaults = defaults
    if let data = defaults.data(forKey: draftKey), let draft = try? JSONDecoder().decode(Draft.self, from: data) {
      recordingID = draft.id; activity = draft.activity; clock = draft.clock; stoppedAt = draft.stoppedAt
      events = zip(draft.pauseDates, draft.pauseKinds).map { date, isPause in
        HKWorkoutEvent(type: isPause ? .pause : .resume, dateInterval: DateInterval(start: date, duration: 0), metadata: nil)
      }
      if clock?.pausedAt == nil && stoppedAt == nil {
        let now = Date(); clock?.pause(at: now)
        events.append(HKWorkoutEvent(type: .pause, dateInterval: DateInterval(start: now, duration: 0), metadata: nil))
      }
      muscleGroups = draft.muscles; notes = draft.notes; phase = .paused
      error = "Recovered your timed workout. Review its duration, then resume, save or discard it."
      persistDraft()
    }
  }

  private func persistDraft() {
    guard let clock else { return }
    let draft = Draft(id: recordingID, activity: activity, clock: clock,
      pauseDates: events.map { $0.dateInterval.start }, pauseKinds: events.map { $0.type == .pause },
      stoppedAt: stoppedAt, muscles: muscleGroups, notes: String(notes.prefix(2000)))
    if let data = try? JSONEncoder().encode(draft) { defaults.set(data, forKey: draftKey) }
  }

  func elapsed(at date: Date = Date()) -> TimeInterval {
    clock?.elapsed(asOf: stoppedAt ?? date) ?? 0
  }

  /// Shortcuts open this explicit confirmation/setup route rather than requesting Health
  /// permission inside the intent's short execution window.
  func queueStart(activity: WorkoutActivity) {
    pendingActivity = activity
    presentationRequested = true
    if !isActive { self.activity = activity; muscleGroups = []; notes = "" }
  }

  func clearPendingStart() { pendingActivity = nil }

  func start(activity: WorkoutActivity) async {
    guard !isActive else {
      error = "A phone workout is already active. Finish or discard it before starting another."
      presentationRequested = true
      return
    }
    phase = .preparing
    error = nil
    watchMessage = nil
    saveNotice = nil
    do {
      guard HKHealthStore.isHealthDataAvailable() else { throw RecorderError.unavailable }
      let type = HKObjectType.workoutType()
      if store.authorizationStatus(for: type) == .notDetermined {
        try await store.requestAuthorization(toShare: [type], read: [type])
      }
      guard store.authorizationStatus(for: type) == .sharingAuthorized else { throw RecorderError.writeAccess }
      let candidate = HKWorkoutBuilder(healthStore: store,
        configuration: activity.workoutConfiguration(), device: .local())
      let start = Date()
      do {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
          candidate.beginCollection(withStart: start) { success, error in
            if let error { continuation.resume(throwing: error) }
            else if success { continuation.resume() }
            else { continuation.resume(throwing: RecorderError.startFailed) }
          }
        }
      } catch {
        candidate.discardWorkout()
        throw error
      }
      self.activity = activity
      recordingID = UUID()
      builder = candidate
      clock = WorkoutRecordingClock(startedAt: start)
      events = []
      stoppedAt = nil
      eventsAdded = false
      metadataAdded = false
      collectionEnded = false
      lastWorkout = nil
      pendingActivity = nil
      phase = .running
      persistDraft()
    } catch {
      phase = .idle
      self.error = error.localizedDescription
    }
  }

  func pause() async {
    guard phase == .running, !hasStopped else { return }
    let date = Date()
    clock?.pause(at: date)
    events.append(HKWorkoutEvent(type: .pause, dateInterval: DateInterval(start: date, duration: 0), metadata: nil))
    phase = .paused
    persistDraft()
  }

  func resume() async {
    guard canResume else { return }
    let date = Date()
    clock?.resume(at: date)
    events.append(HKWorkoutEvent(type: .resume, dateInterval: DateInterval(start: date, duration: 0), metadata: nil))
    phase = .running
    persistDraft()
  }

  func finish() async {
    guard canFinish, let start = clock?.startedAt else { return }
    error = nil
    if stoppedAt == nil {
      let end = Date()
      stoppedAt = end
      if phase == .paused {
        // Close the pause at the finish instant so HealthKit excludes paused time.
        clock?.resume(at: end)
        events.append(HKWorkoutEvent(type: .resume, dateInterval: DateInterval(start: end, duration: 0), metadata: nil))
      }
    }
    guard let end = stoppedAt, end > start else {
      error = "Record a little more time before saving this workout."
      stoppedAt = nil
      return
    }
    phase = .saving
    persistDraft()
    do {
      if let saved = try await existingSavedWorkout() { complete(saved); return }
      if self.builder == nil {
        let restored = HKWorkoutBuilder(healthStore: store, configuration: activity.workoutConfiguration(), device: .local())
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
          restored.beginCollection(withStart: start) { success, error in
            if let error { continuation.resume(throwing: error) }
            else if success { continuation.resume() }
            else { continuation.resume(throwing: RecorderError.startFailed) }
          }
        }
        self.builder = restored
      }
      guard let builder = self.builder else { throw RecorderError.saveFailed }
      if !eventsAdded {
        if !events.isEmpty {
          try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            builder.addWorkoutEvents(events) { success, error in
              if let error { continuation.resume(throwing: error) }
              else if success { continuation.resume() }
              else { continuation.resume(throwing: RecorderError.saveFailed) }
            }
          }
        }
        eventsAdded = true
      }
      if !metadataAdded {
        var metadata = WorkoutRecordingMetadata.dictionary(muscles: muscleGroups, notes: notes)
        metadata[HKMetadataKeySyncIdentifier] = "robur." + recordingID.uuidString
        metadata[HKMetadataKeySyncVersion] = 1
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
          builder.addMetadata(metadata) { success, error in
            if let error { continuation.resume(throwing: error) }
            else if success { continuation.resume() }
            else { continuation.resume(throwing: RecorderError.saveFailed) }
          }
        }
        metadataAdded = true
      }
      if !collectionEnded {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
          builder.endCollection(withEnd: end) { success, error in
            if let error { continuation.resume(throwing: error) }
            else if success { continuation.resume() }
            else { continuation.resume(throwing: RecorderError.saveFailed) }
          }
        }
        collectionEnded = true
      }
      let workout: HKWorkout? = try await withCheckedThrowingContinuation { continuation in
        builder.finishWorkout { workout, error in
          if let error { continuation.resume(throwing: error) }
          else { continuation.resume(returning: workout) }
        }
      }
      if let workout { complete(workout) } else { completeUnavailable() }
    } catch {
      // Keep the stopped timer and builder. Retry Save never restarts collection,
      // repeats successful metadata/event stages, or extends the workout duration.
      collectionEnded = collectionEnded || self.builder?.endDate != nil
      phase = .paused
      self.error = "Unable to save the workout: \(error.localizedDescription) Your timer is retained. Retry Save or explicitly discard it."
    }
  }

  /// The caller must ask for confirmation before discarding an active workout.
  func discard() {
    guard phase != .preparing && phase != .saving else { return }
    builder?.discardWorkout()
    builder = nil
    clock = nil
    events = []
    stoppedAt = nil
    eventsAdded = false
    metadataAdded = false
    collectionEnded = false
    lastWorkout = nil
    error = nil
    phase = .idle
    defaults.removeObject(forKey: draftKey)
  }

  private func existingSavedWorkout() async throws -> HKWorkout? {
    let predicate = HKQuery.predicateForObjects(withMetadataKey: HKMetadataKeySyncIdentifier,
      allowedValues: ["robur." + recordingID.uuidString])
    return try await withCheckedThrowingContinuation { continuation in
      let query = HKSampleQuery(sampleType: HKObjectType.workoutType(), predicate: predicate, limit: 1, sortDescriptors: nil) { _, samples, error in
        if let error { continuation.resume(throwing: error) }
        else { continuation.resume(returning: samples?.first as? HKWorkout) }
      }
      store.execute(query)
    }
  }

  private func complete(_ workout: HKWorkout) {
    lastWorkout = WorkoutRecord(id: workout.uuid.uuidString, start: workout.startDate, end: workout.endDate,
      title: activity.title, symbol: activity.symbol, minutes: workout.duration / 60,
      distanceKm: nil, energyKcal: nil, averageHeartRate: nil, source: "Robur Health", activityType: activity)
    builder = nil
    clock = nil
    events = []
    stoppedAt = nil
    phase = .finished
    defaults.removeObject(forKey: draftKey)
  }

  private func completeUnavailable() {
    // HealthKit explicitly reports nil/nil for a successful save while locked.
    // Do not retry a completed builder or recreate this workout after relaunch.
    builder = nil; clock = nil; events = []; stoppedAt = nil
    lastWorkout = nil
    saveNotice = "Workout saved to Apple Health. Unlock your device and refresh to review it when Health makes it available."
    phase = .finished
    defaults.removeObject(forKey: draftKey)
  }

  func startOnWatch(activity: WorkoutActivity) async {
    guard supportsWatchLaunch, !watchLaunchInProgress, !isActive else {
      error = supportsWatchLaunch ? "Finish the phone workout before opening a Watch workout." : "Starting a paired Watch workout is available on iPhone."
      return
    }
    watchLaunchInProgress = true
    error = nil
    watchMessage = nil
    defer { watchLaunchInProgress = false }
    do {
      guard HKHealthStore.isHealthDataAvailable() else { throw RecorderError.unavailable }
      let configuration = activity.workoutConfiguration()
      try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
        store.startWatchApp(with: configuration) { success, error in
          if let error { continuation.resume(throwing: error) }
          else if success { continuation.resume() }
          else { continuation.resume(throwing: RecorderError.watchLaunchFailed) }
        }
      }
      watchMessage = "Robur opened on your Watch. Confirm any Health permissions and manage the workout on the Watch."
    } catch {
      self.error = "Could not open Robur on your Watch: \(error.localizedDescription)"
    }
  }

  private enum RecorderError: LocalizedError {
    case unavailable, writeAccess, startFailed, saveFailed, watchLaunchFailed
    var errorDescription: String? {
      switch self {
      case .unavailable: return "Apple Health is unavailable on this device."
      case .writeAccess: return "Allow Robur to save workouts in Health permissions before starting a phone workout."
      case .startFailed: return "The workout timer could not start. Try again."
      case .saveFailed: return "Apple Health could not save this workout."
      case .watchLaunchFailed: return "The paired Watch app did not open. Check that the Watch is connected and Robur is installed."
      }
    }
  }
}
