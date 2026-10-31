import Combine
import Foundation
import HealthKit

/// Watch owns sensor collection and the single Health workout saved by this recorder.
@MainActor
final class WatchWorkoutRecorder: NSObject, ObservableObject {
  static let shared = WatchWorkoutRecorder()

  @Published private(set) var phase: WorkoutRecordingPhase = .idle
  @Published private(set) var activity: WorkoutActivity = .functionalStrength
  @Published private(set) var error: String?
  @Published private(set) var saveNotice: String?
  @Published private(set) var lastWorkout: WorkoutRecord?
  @Published private(set) var heartRateBPM: Double?
  @Published private(set) var energyKcal: Double?
  @Published private(set) var distanceMeters: Double?
  @Published private(set) var elapsedSeconds: TimeInterval = 0
  @Published var muscleGroups: Set<MuscleGroup> = []
  @Published var notes = ""

  private let store = HKHealthStore()
  private var session: HKWorkoutSession?
  private var builder: HKLiveWorkoutBuilder?
  private var clock: WorkoutRecordingClock?
  private var timer: Timer?
  private var generation = UUID()
  private var collectionStarted = false
  private var metadataAdded = false
  private var collectionEnded = false
  private var savingInProgress = false
  private var recoveryInProgress = false
  private var stoppedAt: Date?
  private var stopContinuation: CheckedContinuation<Void, Never>?

  var canRetrySave: Bool { stoppedAt != nil && builder != nil && !savingInProgress && error != nil }

  func elapsed(at date: Date = Date()) -> TimeInterval {
    let date = stoppedAt ?? date
    if collectionStarted, let builder { return max(0, builder.elapsedTime(at: date)) }
    return clock?.elapsed(asOf: date) ?? 0
  }

  func start(activity: WorkoutActivity) async {
    await start(configuration: activity.workoutConfiguration(), recordedActivity: activity)
  }

  func start(configuration: HKWorkoutConfiguration) async {
    await start(configuration: configuration, recordedActivity: .fromHealthKit(configuration.activityType))
  }

  private func start(configuration: HKWorkoutConfiguration, recordedActivity: WorkoutActivity) async {
    guard !phase.isActive, !recoveryInProgress else {
      error = "A Watch workout is already active. Finish or discard it before starting another."
      return
    }
    prepare(configuration: configuration)
    activity = recordedActivity
    let token = generation
    do {
      try await requestAuthorization()
      guard generation == token else { return }
      try createSession(configuration: configuration)
      try await beginCollection(token: token)
    } catch {
      failStart(error, token: token)
    }
  }

  /// Apple's Action button contract requires a real session before perform returns.
  /// Permission UI and collection run afterward, outside the intent's time limit.
  func startFromIntent(activity: WorkoutActivity) throws {
    guard !phase.isActive, !recoveryInProgress else { throw RecordingError.alreadyActive }
    let configuration = activity.workoutConfiguration()
    prepare(configuration: configuration)
    self.activity = activity
    let token = generation
    do {
      try createSession(configuration: configuration)
    } catch {
      failStart(error, token: token)
      throw error
    }
    Task {
      do {
        try await requestAuthorization()
        guard generation == token else { return }
        try await beginCollection(token: token)
      } catch {
        failStart(error, token: token)
      }
    }
  }

  func pause() {
    guard phase == .running, stoppedAt == nil else { return }
    session?.pause()
    clock?.pause()
    phase = .paused
    elapsedSeconds = elapsed()
  }

  func resume() {
    guard phase == .paused, stoppedAt == nil else { return }
    session?.resume()
    clock?.resume()
    phase = .running
  }

  func finish() async {
    guard !savingInProgress, collectionStarted, let session, let builder,
          phase == .running || phase == .paused || canRetrySave else { return }
    savingInProgress = true
    phase = .saving
    error = nil
    let token = generation
    if stoppedAt == nil { stoppedAt = Date() }
    guard let end = stoppedAt else { savingInProgress = false; return }
    elapsedSeconds = elapsed(at: end)
    timer?.invalidate()
    timer = nil

    // Keep the session alive through saving; stop sensor activity before ending collection.
    if session.state != .stopped && session.state != .ended {
      await withCheckedContinuation { continuation in
        stopContinuation = continuation
        session.stopActivity(with: end)
      }
    }
    guard generation == token else { savingInProgress = false; return }
    do {
      if !metadataAdded {
        var metadata = WorkoutRecordingMetadata.dictionary(muscles: muscleGroups, notes: notes)
        metadata[WorkoutRecordingMetadata.activityKey] = activity.rawValue
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
          builder.addMetadata(metadata) { success, error in
            if let error { continuation.resume(throwing: error) }
            else if success { continuation.resume() }
            else { continuation.resume(throwing: RecordingError.saveFailed) }
          }
        }
        metadataAdded = true
      }
      if !collectionEnded {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
          builder.endCollection(withEnd: end) { success, error in
            if let error { continuation.resume(throwing: error) }
            else if success { continuation.resume() }
            else { continuation.resume(throwing: RecordingError.saveFailed) }
          }
        }
        collectionEnded = true
      }
      let workout: HKWorkout? = try await withCheckedThrowingContinuation { continuation in
        builder.finishWorkout { workout, error in
          if let error { continuation.resume(throwing: error) }
          // A nil workout without an error is a successful save while locked.
          else { continuation.resume(returning: workout) }
        }
      }
      refreshMetrics(from: builder)
      if let workout {
        let heart = HKQuantityType(.heartRate)
        let average = builder.statistics(for: heart)?.averageQuantity()?.doubleValue(for: .count().unitDivided(by: .minute()))
        lastWorkout = WorkoutRecord(id: workout.uuid.uuidString, start: workout.startDate, end: workout.endDate,
          title: activity.title, symbol: activity.symbol, minutes: workout.duration / 60,
          distanceKm: distanceMeters.map { $0 / 1_000 }, energyKcal: energyKcal,
          averageHeartRate: average, source: "Robur Health", activityType: activity)
      } else {
        lastWorkout = nil
        saveNotice = "Saved to Apple Health. Unlock your Watch and refresh recent workouts to review this session."
      }
      session.end()
      self.session = nil
      self.builder = nil
      error = nil
      phase = .finished
    } catch {
      // A retry resumes at the failed stage, retaining the original end time.
      collectionEnded = collectionEnded || builder.endDate != nil
      self.error = "Unable to save: \(error.localizedDescription) Your workout is retained. Retry save or discard it."
    }
    savingInProgress = false
  }

  /// Active workouts are discarded only after the view's confirmation dialog.
  func discard() {
    guard !savingInProgress else { return }
    generation = UUID()
    session?.delegate = nil
    builder?.delegate = nil
    session?.end()
    builder?.discardWorkout()
    session = nil
    builder = nil
    timer?.invalidate()
    timer = nil
    clock = nil
    stoppedAt = nil
    collectionStarted = false
    metadataAdded = false
    collectionEnded = false
    heartRateBPM = nil
    energyKcal = nil
    distanceMeters = nil
    elapsedSeconds = 0
    lastWorkout = nil
    saveNotice = nil
    muscleGroups = []
    notes = ""
    error = nil
    phase = .idle
  }

  func recoverActiveSession() async {
    guard session == nil, !phase.isActive, !recoveryInProgress else { return }
    recoveryInProgress = true
    defer { recoveryInProgress = false }
    do {
      guard let recovered = try await store.recoverActiveWorkoutSession(), session == nil else { return }
      prepare(configuration: recovered.workoutConfiguration)
      session = recovered
      builder = recovered.associatedWorkoutBuilder()
      recovered.delegate = self
      builder?.delegate = self
      builder?.dataSource = HKLiveWorkoutDataSource(healthStore: store, workoutConfiguration: recovered.workoutConfiguration)
      collectionStarted = true
      collectionEnded = builder?.endDate != nil
      if let start = builder?.startDate ?? recovered.startDate { clock = WorkoutRecordingClock(startedAt: start) }
      switch recovered.state {
      case .paused:
        phase = .paused
        clock?.pause()
      case .stopped, .ended:
        stoppedAt = builder?.endDate ?? recovered.endDate ?? Date()
        phase = .saving
        error = "A stopped workout was recovered. Retry save or discard it."
      default:
        phase = .running
      }
      if let builder { refreshMetrics(from: builder) }
      elapsedSeconds = elapsed()
      if stoppedAt == nil { startTimer() }
    } catch {
      self.error = "Unable to recover the active workout: \(error.localizedDescription)"
    }
  }

  private func prepare(configuration: HKWorkoutConfiguration) {
    generation = UUID()
    activity = WorkoutActivity.fromHealthKit(configuration.activityType)
    phase = .preparing
    error = nil
    lastWorkout = nil
    saveNotice = nil
    heartRateBPM = nil
    energyKcal = nil
    distanceMeters = nil
    elapsedSeconds = 0
    clock = nil
    stoppedAt = nil
    collectionStarted = false
    metadataAdded = false
    collectionEnded = false
    muscleGroups = []
    notes = ""
  }

  private func requestAuthorization() async throws {
    guard HKHealthStore.isHealthDataAvailable() else { throw RecordingError.unavailable }
    let quantities: Set<HKSampleType> = [HKQuantityType(.activeEnergyBurned),
      HKQuantityType(.distanceWalkingRunning), HKQuantityType(.distanceCycling), HKQuantityType(.distanceSwimming)]
    var sharing = quantities
    sharing.insert(HKObjectType.workoutType())
    var reading: Set<HKObjectType> = Set(sharing.map { $0 as HKObjectType })
    reading.insert(HKQuantityType(.heartRate))
    try await store.requestAuthorization(toShare: sharing, read: reading)
    guard store.authorizationStatus(for: HKObjectType.workoutType()) == .sharingAuthorized else {
      throw RecordingError.writeAccess
    }
  }

  private func createSession(configuration: HKWorkoutConfiguration) throws {
    guard HKHealthStore.isHealthDataAvailable() else { throw RecordingError.unavailable }
    let candidate = try HKWorkoutSession(healthStore: store, configuration: configuration)
    session = candidate
    builder = candidate.associatedWorkoutBuilder()
    candidate.delegate = self
    let start = Date()
    clock = WorkoutRecordingClock(startedAt: start)
    candidate.startActivity(with: start)
  }

  private func beginCollection(token: UUID) async throws {
    guard let session, let builder, let start = clock?.startedAt else { throw RecordingError.startFailed }
    builder.dataSource = HKLiveWorkoutDataSource(healthStore: store, workoutConfiguration: session.workoutConfiguration)
    builder.delegate = self
    try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
      builder.beginCollection(withStart: start) { success, error in
        if let error { continuation.resume(throwing: error) }
        else if success { continuation.resume() }
        else { continuation.resume(throwing: RecordingError.startFailed) }
      }
    }
    guard generation == token else { return }
    collectionStarted = true
    phase = session.state == .paused ? .paused : .running
    startTimer()
  }

  private func failStart(_ failure: Error, token: UUID) {
    guard generation == token else { return }
    discard()
    error = failure.localizedDescription
  }

  private func startTimer() {
    timer?.invalidate()
    timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
      Task { @MainActor [weak self] in
        guard let self else { return }
        self.elapsedSeconds = self.elapsed()
      }
    }
  }

  private func refreshMetrics(from builder: HKLiveWorkoutBuilder) {
    let heart = HKQuantityType(.heartRate)
    if let quantity = builder.statistics(for: heart)?.mostRecentQuantity() {
      heartRateBPM = quantity.doubleValue(for: .count().unitDivided(by: .minute()))
    }
    if let quantity = builder.statistics(for: HKQuantityType(.activeEnergyBurned))?.sumQuantity() {
      energyKcal = quantity.doubleValue(for: .kilocalorie())
    }
    let distanceType: HKQuantityTypeIdentifier
    switch activity {
    case .cycling: distanceType = .distanceCycling
    case .swimming: distanceType = .distanceSwimming
    default: distanceType = .distanceWalkingRunning
    }
    if let quantity = builder.statistics(for: HKQuantityType(distanceType))?.sumQuantity() {
      distanceMeters = quantity.doubleValue(for: .meter())
    }
  }

  private func sessionChanged(_ candidate: HKWorkoutSession, state: HKWorkoutSessionState, date: Date) {
    guard session === candidate else { return }
    switch state {
    case .paused:
      clock?.pause(at: date)
      if stoppedAt == nil, collectionStarted { phase = .paused }
    case .running:
      clock?.resume(at: date)
      if stoppedAt == nil, collectionStarted { phase = .running }
    case .stopped, .ended:
      if stoppedAt == nil {
        stoppedAt = date
        phase = .saving
        error = "The workout stopped. Retry save to keep it in Apple Health, or discard it."
      }
      elapsedSeconds = elapsed(at: date)
      timer?.invalidate()
      timer = nil
      stopContinuation?.resume()
      stopContinuation = nil
    default: break
    }
  }

  private enum RecordingError: LocalizedError {
    case alreadyActive, unavailable, writeAccess, startFailed, saveFailed
    var errorDescription: String? {
      switch self {
      case .alreadyActive: return "A Watch workout is already active. Finish or discard it before starting another."
      case .unavailable: return "Apple Health is unavailable on this Watch."
      case .writeAccess: return "Allow Robur to save workouts in Health permissions before recording."
      case .startFailed: return "The Watch could not start collecting workout data. Try again."
      case .saveFailed: return "Apple Health could not save this workout."
      }
    }
  }
}

extension WatchWorkoutRecorder: HKWorkoutSessionDelegate, HKLiveWorkoutBuilderDelegate {
  nonisolated func workoutSession(_ workoutSession: HKWorkoutSession, didChangeTo toState: HKWorkoutSessionState,
                                 from fromState: HKWorkoutSessionState, date: Date) {
    Task { @MainActor [weak self] in self?.sessionChanged(workoutSession, state: toState, date: date) }
  }

  nonisolated func workoutSession(_ workoutSession: HKWorkoutSession, didFailWithError error: Error) {
    Task { @MainActor [weak self] in
      guard let self, self.session === workoutSession else { return }
      guard self.collectionStarted else {
        self.failStart(error, token: self.generation)
        return
      }
      self.stoppedAt = self.stoppedAt ?? Date()
      self.phase = .saving
      self.error = "Workout recording stopped: \(error.localizedDescription) Save the collected workout or discard it."
      self.timer?.invalidate()
      self.timer = nil
      self.stopContinuation?.resume()
      self.stopContinuation = nil
    }
  }

  nonisolated func workoutBuilderDidCollectEvent(_ workoutBuilder: HKLiveWorkoutBuilder) {
    Task { @MainActor [weak self] in
      guard let self, self.builder === workoutBuilder else { return }
      self.elapsedSeconds = self.elapsed()
    }
  }

  nonisolated func workoutBuilder(_ workoutBuilder: HKLiveWorkoutBuilder, didCollectDataOf collectedTypes: Set<HKSampleType>) {
    Task { @MainActor [weak self] in
      guard let self, self.builder === workoutBuilder else { return }
      self.refreshMetrics(from: workoutBuilder)
      self.elapsedSeconds = self.elapsed()
    }
  }
}
