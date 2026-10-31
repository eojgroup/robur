import SwiftUI
import HealthKit
import WatchKit

private enum WatchTheme {
  static let orange = Color(red: 1, green: 0.63, blue: 0.31)
  static let beige = Color(red: 0.96, green: 0.92, blue: 0.84)
  static let navy = Color(red: 0.055, green: 0.10, blue: 0.18)
}

@MainActor
final class RoburWatchDelegate: NSObject, WKApplicationDelegate {
  func applicationDidFinishLaunching() { WorkoutReviewSync.shared.activate() }
  func handle(_ workoutConfiguration: HKWorkoutConfiguration) {
    Task { await WatchWorkoutRecorder.shared.start(configuration: workoutConfiguration) }
  }
  func handleActiveWorkoutRecovery() {
    Task { await WatchWorkoutRecorder.shared.recoverActiveSession() }
  }
}

@main
struct RoburWatchApp: App {
  @WKApplicationDelegateAdaptor(RoburWatchDelegate.self) private var appDelegate
  var body: some Scene {
    WindowGroup { RoburWatchRootView().tint(WatchTheme.orange) }
  }
}

struct RoburWatchRootView: View {
  @Environment(\.scenePhase) private var scenePhase
  @StateObject private var healthKit = HealthKitClient()
  @StateObject private var recorder = WatchWorkoutRecorder.shared
  @StateObject private var reviews = WorkoutReviewStore.shared
  @StateObject private var history = WatchWorkoutHistory()
  @StateObject private var sync = WorkoutReviewSync.shared
  @State private var reviewWorkout: WorkoutRecord?
  @State private var confirmDiscard = false
  @State private var confirmFinish = false

  private var isActive: Bool {
    recorder.phase == .preparing || recorder.phase == .running || recorder.phase == .paused || recorder.phase == .saving
  }
  private var pending: [WorkoutRecord] { history.workouts.filter { reviews.annotation(for: $0.id) == nil } }
  private var snapshot: FitnessSnapshot { healthKit.snapshot ?? RoburData.noHealthData }

  var body: some View {
    NavigationStack {
      List {
        if isActive { liveWorkout }
        else {
          if let notice = recorder.saveNotice {
            Section("Workout saved") { Label(notice, systemImage: "checkmark.circle").font(.caption) }
          }
          startSection
          if recorder.phase == .finished, let workout = recorder.lastWorkout {
            Section("Workout saved") {
              Label(workout.title, systemImage: workout.symbol).foregroundStyle(WatchTheme.beige)
              Text("\(Int(workout.minutes)) min · saved to Health").font(.caption)
              Button("Review muscles") { reviewWorkout = workout }
              Button("Done") { recorder.discard() }
            }
          }
          reviewSection
          todaySection
        }
        if let error = recorder.error { Section { Text(error).font(.caption).foregroundStyle(.red) } }
      }
      .navigationTitle("Robur")
      .listStyle(.carousel)
      .containerBackground(WatchTheme.navy.gradient, for: .navigation)
      .sheet(item: $reviewWorkout) { workout in
        WatchMuscleReviewView(workout: workout).environmentObject(reviews).environmentObject(sync)
      }
      .confirmationDialog("Discard this workout?", isPresented: $confirmDiscard) {
        Button("Discard workout", role: .destructive) { recorder.discard() }
      } message: { Text("An unsaved workout will not be added to Health.") }
      .confirmationDialog("Finish and save this workout?", isPresented: $confirmFinish) {
        Button("Finish & save") { Task { await recorder.finish() } }
      }
      .onChange(of: recorder.phase) { _, phase in
        if phase == .finished, let workout = recorder.lastWorkout { reviewWorkout = workout; Task { await history.refresh() } }
      }
      .onChange(of: scenePhase) { _, phase in
        if phase == .active { sync.activate(); Task { await history.refresh() } }
      }
      .task {
        sync.activate()
        await recorder.recoverActiveSession()
        await healthKit.refreshTodaySnapshot()
        if healthKit.authorizationRequested { await history.refresh() }
      }
    }
  }

  private var startSection: some View {
    Section("Start a workout") {
      ForEach([WorkoutActivity.running, .cycling, .tennis, .functionalStrength]) { activity in
        Button { Task { await recorder.start(activity: activity) } } label: {
          Label(activity.title, systemImage: activity.symbol).foregroundStyle(WatchTheme.beige)
        }
      }
    }
  }

  private var liveWorkout: some View {
    Section {
      Label(recorder.activity.title, systemImage: recorder.activity.symbol).font(.headline).foregroundStyle(WatchTheme.orange)
      Text(duration(recorder.elapsedSeconds)).font(.system(.largeTitle, design: .rounded, weight: .bold)).monospacedDigit()
      if recorder.phase == .preparing { ProgressView("Starting…") }
      if recorder.phase == .saving { ProgressView("Saving to Health…") }
      if recorder.phase == .paused { Label("Paused", systemImage: "pause.fill").foregroundStyle(WatchTheme.orange) }
      HStack(alignment: .top) {
        liveMetric("Heart rate", value: recorder.heartRateBPM, unit: "bpm", symbol: "heart.fill")
        Spacer()
        liveMetric("Energy", value: recorder.energyKcal, unit: "kcal", symbol: "flame.fill")
      }
      if let distance = recorder.distanceMeters, distance > 0 {
        Label(String(format: "%.2f km", distance / 1000), systemImage: "point.bottomleft.forward.to.point.topright.scurvepath")
      }
      if recorder.phase == .running {
        Button("Pause", systemImage: "pause.fill") { recorder.pause() }
      } else if recorder.phase == .paused {
        Button("Resume", systemImage: "play.fill") { recorder.resume() }
      }
      if recorder.phase == .running || recorder.phase == .paused {
        Button("Finish & save", systemImage: "checkmark") { confirmFinish = true }
      }
      if recorder.canRetrySave {
        Button("Retry save") { Task { await recorder.finish() } }
      }
      if recorder.phase != .saving || recorder.error != nil {
        Button("Discard", role: .destructive) { confirmDiscard = true }
      }
      Text("Live readings depend on Watch sensors and permissions. Missing measurements stay blank.")
        .font(.caption2).foregroundStyle(.secondary)
    } header: { Text("Live workout") }
  }

  private var reviewSection: some View {
    Section("Muscles to review") {
      if pending.isEmpty {
        Text(history.workouts.isEmpty ? "Record with Robur or Apple Workout, then review the muscles trained here." : "All recent workouts reviewed.")
          .font(.caption).foregroundStyle(.secondary)
      }
      ForEach(Array(pending.prefix(8))) { workout in
        Button { reviewWorkout = workout } label: {
          VStack(alignment: .leading, spacing: 4) {
            Label(workout.title, systemImage: workout.symbol)
            Text(workout.start.formatted(date: .abbreviated, time: .omitted) + " · \(Int(workout.minutes)) min")
              .font(.caption2).foregroundStyle(.secondary)
          }
        }
      }
      if !history.workouts.isEmpty {
        NavigationLink("Last 7 days") {
          List(history.workouts) { workout in
            Button { reviewWorkout = workout } label: {
              VStack(alignment: .leading, spacing: 3) {
                Label(workout.title, systemImage: workout.symbol)
                Text(reviews.annotation(for: workout.id) == nil ? "Needs review" : "Reviewed").font(.caption2).foregroundStyle(.secondary)
              }
            }
          }.navigationTitle("Last 7 days")
        }
      }
      if history.loading { ProgressView() }
      if let error = history.error { Text(error).font(.caption).foregroundStyle(.secondary) }
      Text(sync.status).font(.caption2).foregroundStyle(.secondary)
      Button("Refresh workouts") { Task { await history.refresh() } }
    }
  }

  private var todaySection: some View {
    Section("Health today") {
      Label(snapshot.sleepMinutes > 0 ? RoburData.duration(snapshot.sleepMinutes) : "Sleep unavailable", systemImage: "moon.fill")
      Label(snapshot.restingHeartRateBpm > 0 ? "\(snapshot.restingHeartRateBpm) bpm resting" : "Resting HR unavailable", systemImage: "heart.fill")
      Text(healthKit.statusText).font(.caption2).foregroundStyle(.secondary)
      Button(healthKit.authorizationRequested ? "Refresh Health" : "Connect Health") {
        if healthKit.authorizationRequested { Task { await healthKit.refreshTodaySnapshot(); await history.refresh() } }
        else { healthKit.requestAuthorization() }
      }
    }
  }

  private func duration(_ seconds: Double) -> String {
    let value = max(0, Int(seconds))
    return value >= 3600 ? String(format: "%d:%02d:%02d", value / 3600, (value / 60) % 60, value % 60)
      : String(format: "%02d:%02d", value / 60, value % 60)
  }
  private func liveMetric(_ title: String, value: Double?, unit: String, symbol: String) -> some View {
    VStack(alignment: .leading, spacing: 3) {
      Image(systemName: symbol).foregroundStyle(WatchTheme.orange)
      Text(value.map { String(format: "%.0f", $0) } ?? "—").font(.title3.bold()).monospacedDigit()
      Text(unit).font(.caption2).foregroundStyle(.secondary)
    }.accessibilityElement(children: .ignore).accessibilityLabel("\(title): \(value.map { String(format: "%.0f %@", $0, unit) } ?? "Unavailable")")
  }
}

struct WatchMuscleReviewView: View {
  let workout: WorkoutRecord
  @EnvironmentObject private var reviews: WorkoutReviewStore
  @EnvironmentObject private var sync: WorkoutReviewSync
  @Environment(\.dismiss) private var dismiss
  @State private var muscles: Set<MuscleGroup> = []
  @State private var notes = ""
  @State private var loaded = false

  var body: some View {
    NavigationStack {
      ScrollView {
        VStack(alignment: .leading, spacing: 14) {
          Image(systemName: workout.symbol).font(.largeTitle).foregroundStyle(WatchTheme.orange)
          Text("What did you train?").font(.title3.bold()).foregroundStyle(WatchTheme.beige)
          Text(workout.title + " · \(Int(workout.minutes)) min").font(.caption).foregroundStyle(.secondary)
          LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 8) {
            ForEach(MuscleGroup.allCases) { group in
              Button {
                if muscles.contains(group) { muscles.remove(group) } else { muscles.insert(group) }
              } label: {
                Text(group.rawValue).font(.caption2.bold()).lineLimit(1).minimumScaleFactor(0.7)
                  .frame(maxWidth: .infinity).padding(.vertical, 8)
                  .background(muscles.contains(group) ? WatchTheme.orange.opacity(0.28) : Color.white.opacity(0.06), in: Capsule())
                  .overlay { Capsule().stroke(muscles.contains(group) ? WatchTheme.orange : Color.clear, lineWidth: 1) }
              }.buttonStyle(.plain).accessibilityLabel("\(group.rawValue), \(muscles.contains(group) ? "selected" : "not selected")")
            }
          }
          TextField("Add a note", text: $notes)
            .onChange(of: notes) { _, value in if value.count > WorkoutReviewRules.maximumNotes { notes = String(value.prefix(WorkoutReviewRules.maximumNotes)) } }
          Text("Use dictation or the keyboard. \(notes.count)/\(WorkoutReviewRules.maximumNotes)").font(.caption2).foregroundStyle(.secondary)
          if let error = reviews.lastError { Text(error).font(.caption).foregroundStyle(.red) }
          Button { save() } label: {
            Label("Save review", systemImage: "checkmark.circle.fill")
          }.buttonStyle(.borderedProminent).tint(WatchTheme.orange)
          Text("Saved on this Watch and queued to your paired iPhone. Notes and muscle tags sync; raw Health readings do not.")
            .font(.caption2).foregroundStyle(.secondary)
        }.padding()
      }
      .navigationTitle("Muscle review")
      .onAppear {
        guard !loaded else { return }
        if let annotation = reviews.annotation(for: workout.id) { muscles = annotation.muscles; notes = annotation.notes }
        else if WatchWorkoutRecorder.shared.lastWorkout?.id == workout.id {
          muscles = WatchWorkoutRecorder.shared.muscleGroups
          notes = WatchWorkoutRecorder.shared.notes
        }
        loaded = true
      }
    }
  }

  private func save() {
    guard reviews.save(annotation: WorkoutAnnotation(muscles: muscles, notes: notes), forID: workout.id) else { return }
    sync.activate()
    dismiss()
  }
}
