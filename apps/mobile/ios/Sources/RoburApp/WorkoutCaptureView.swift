import SwiftUI
import UIKit

/// Review reminders follow the app rather than a dashboard card.
struct WorkoutReviewPrompts: ViewModifier {
  @EnvironmentObject private var healthKit: HealthKitClient
  @EnvironmentObject private var journal: WorkoutJournal
  @Environment(\.scenePhase) private var scenePhase
  @StateObject private var recorder = PhoneWorkoutRecorder.shared
  @StateObject private var reviews = WorkoutReviewStore.shared
  @StateObject private var motion = WorkoutMotionSuggestions.shared
  @State private var selected: WorkoutRecord?
  @State private var suggestedActivity: WorkoutActivity?
  @State private var showingMotionSuggestion = false

  private var pending: [WorkoutRecord] {
    WorkoutReviewPolicy.pending(workouts: healthKit.workouts, annotations: journal.annotations,
      reviewedIDs: Set(reviews.reviews.keys))
  }

  func body(content: Content) -> some View {
    content
      .sheet(item: $selected) { workout in
        WorkoutReviewEditor(workout: workout).onAppear { Self.markPrompted(workout.id) }
      }
      .onChange(of: healthKit.workouts, initial: true) { _, _ in remind(); promptReview() }
      .onChange(of: reviews.reviews) { _, _ in remind() }
      .onChange(of: scenePhase) { _, phase in if phase == .active { promptReview() } }
      .onChange(of: recorder.presentationRequested) { _, showing in if !showing { promptReview() } }
      .onChange(of: motion.suggestion) { _, activity in
        if let activity, !hasPresentedScreen, !recorder.isActive, !recorder.presentationRequested, selected == nil {
          suggestedActivity = activity
          showingMotionSuggestion = true
        }
      }
      .alert("Start a workout?", isPresented: $showingMotionSuggestion, presenting: suggestedActivity) { activity in
          Button("Start") {
            suggestedActivity = nil
            motion.dismissSuggestion()
            recorder.queueStart(activity: activity)
          }
          Button("Later", role: .cancel) { suggestedActivity = nil; motion.dismissSuggestion() }
        } message: { activity in
          Text("Motion suggests \(activity.title.lowercased()). Confirm to choose how to record it.")
        }
  }

  private static let promptedKey = "RoburWorkoutReviewPromptedIDs"

  static func markPrompted(_ id: String) {
    var ids = UserDefaults.standard.stringArray(forKey: promptedKey) ?? []
    ids.removeAll { $0 == id }
    ids.append(id)
    UserDefaults.standard.set(Array(ids.suffix(100)), forKey: promptedKey)
  }

  private func promptReview() {
    guard scenePhase == .active, selected == nil,
          !recorder.presentationRequested, !recorder.isActive, !showingMotionSuggestion, !hasPresentedScreen else { return }
    let prompted = Set(UserDefaults.standard.stringArray(forKey: Self.promptedKey) ?? [])
    guard let workout = pending.first(where: { $0.end >= Date().addingTimeInterval(-48 * 3600) && !prompted.contains($0.id) }) else { return }
    selected = workout
  }

  private var hasPresentedScreen: Bool {
    func isPresenting(_ controller: UIViewController?) -> Bool {
      guard let controller else { return false }
      return controller.presentedViewController != nil || controller.children.contains { isPresenting($0) }
    }
    return UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
      .flatMap(\.windows).filter(\.isKeyWindow).contains { isPresenting($0.rootViewController) }
  }

  private func remind() {
    guard let workout = pending.first, workout.end > Date().addingTimeInterval(-48 * 3600) else { return }
    Task { await HealthNotificationManager.shared.remindToReview(workout) }
  }
}

struct WorkoutReviewEditor: View {
  let workout: WorkoutRecord
  @EnvironmentObject private var journal: WorkoutJournal
  @Environment(\.dismiss) private var dismiss
  @State private var muscles: Set<MuscleGroup> = []
  @State private var quick = WorkoutQuickReview()
  @State private var notes = ""
  @State private var showNotes = false
  @State private var error: String?
  var onSaved: (() -> Void)? = nil

  var body: some View {
    NavigationStack {
      ScrollView {
        VStack(alignment: .leading, spacing: 22) {
          Label("Workout saved", systemImage: "checkmark.circle.fill").foregroundStyle(RoburStyle.orange).font(.headline)
          Text(workout.title).font(.largeTitle.bold())
          Text("\(Int(workout.minutes)) min · \(workout.start.formatted(date: .abbreviated, time: .shortened))").foregroundStyle(.secondary)
          WorkoutReviewFields(workout: workout, muscles: $muscles, quick: $quick)
          DisclosureGroup("Notes (optional)", isExpanded: $showNotes) {
            TextField("Anything to remember?", text: $notes, axis: .vertical)
              .lineLimit(3...6).padding().background(RoburStyle.surface, in: RoundedRectangle(cornerRadius: 16))
              .onChange(of: notes) { _, value in if value.count > 2000 { notes = String(value.prefix(2000)) } }
          }
          if let error { Text(error).foregroundStyle(.red) }
          Text("Your review stays in Robur and syncs privately with your paired Watch. Your Health workout and Apple Fitness rating stay unchanged.")
            .font(.caption).foregroundStyle(.secondary)
        }.frame(maxWidth: 700).padding().frame(maxWidth: .infinity)
      }.background(RoburStyle.background)
        .navigationTitle("Review session").navigationBarTitleDisplayMode(.inline)
        .toolbar {
          ToolbarItem(placement: .cancellationAction) { Button("Later") { dismiss() } }
          ToolbarItem(placement: .confirmationAction) { Button("Save review") { save() }.bold() }
        }
        .onAppear {
          let current = WorkoutReviewStore.shared.annotation(for: workout.id) ?? journal.annotations[workout.id]
          muscles = current?.muscles ?? []; notes = current?.notes ?? ""
          quick = current?.quickReview ?? WorkoutQuickReview()
          showNotes = !notes.isEmpty
        }
    }.tint(RoburStyle.orange)
  }

  private func save() {
    var annotation = journal.annotations[workout.id] ?? WorkoutAnnotation()
    annotation.muscles = muscles; annotation.notes = notes
    annotation.quickReview = quick.isEmpty ? nil : quick
    guard journal.save(annotation, for: workout) else { error = journal.storageError; return }
    guard WorkoutReviewStore.shared.save(annotation: annotation, forID: workout.id) else {
      error = "Saved on this device, but the paired-device review could not be queued. Try Save again."; return
    }
    HealthNotificationManager.shared.cancelWorkoutReview(workout.id)
    onSaved?(); dismiss()
  }
}

struct WorkoutCaptureView: View {
  @EnvironmentObject private var journal: WorkoutJournal
  @EnvironmentObject private var healthKit: HealthKitClient
  @Environment(\.dismiss) private var dismiss
  @StateObject private var recorder = PhoneWorkoutRecorder.shared
  @State private var activity: WorkoutActivity = .functionalStrength
  @State private var reviewing: WorkoutRecord?
  @State private var confirmDiscard = false

  var body: some View {
    NavigationStack {
      ScrollView {
        VStack(alignment: .leading, spacing: 22) {
          if recorder.isActive {
            Text(recorder.activity.title).font(.largeTitle.bold())
            Text(recorder.phase.title).foregroundStyle(.secondary)
            TimelineView(.periodic(from: Date(), by: 1)) { context in
              Text(Duration.seconds(recorder.elapsed(at: context.date)).formatted(.time(pattern: .hourMinuteSecond)))
                .font(.system(size: 56, weight: .bold, design: .rounded)).monospacedDigit().minimumScaleFactor(0.5)
            }
            Text("Timed recording on this device. Use the Watch for live heart rate, energy and distance; these values aren’t invented for a phone timer.")
              .font(.callout).foregroundStyle(.secondary)
            if recorder.phase == .running {
              Button("Pause") { Task { await recorder.pause() } }.buttonStyle(.bordered)
            } else if recorder.canResume {
              Button("Resume") { Task { await recorder.resume() } }.buttonStyle(.borderedProminent)
            }
            Button(recorder.hasStopped ? "Retry save" : "Finish & save to Health") {
              Task {
                await recorder.finish()
                if recorder.phase == .finished, let workout = recorder.lastWorkout {
                  if !recorder.muscleGroups.isEmpty || !recorder.notes.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    var annotation = journal.annotations[workout.id] ?? WorkoutAnnotation()
                    annotation.muscles = recorder.muscleGroups; annotation.notes = recorder.notes
                    _ = journal.save(annotation, for: workout)
                  }
                  WorkoutReviewPrompts.markPrompted(workout.id)
                  reviewing = workout
                  await healthKit.refreshTodaySnapshot()
                  await HealthNotificationManager.shared.remindToReview(workout)
                }
              }
            }.buttonStyle(.borderedProminent).disabled(!recorder.canFinish)
            Button("Discard timed recording", role: .destructive) { confirmDiscard = true }
              .disabled(recorder.phase == .saving || recorder.phase == .preparing)
          } else {
            Label("Start with intention", systemImage: "play.circle.fill").font(.title2.bold())
            Picker("Workout", selection: $activity) {
              ForEach(WorkoutActivity.allCases.filter { $0 != .racketSports && $0 != .other }) { type in
                Label(type.title, systemImage: type.symbol).tag(type)
              }
            }.pickerStyle(.menu)
            if recorder.supportsWatchLaunch {
              Button { Task { await recorder.startOnWatch(activity: activity) } } label: {
                Label("Start on Apple Watch", systemImage: "applewatch")
              }.buttonStyle(.borderedProminent).disabled(recorder.watchLaunchInProgress)
              Text("Use your paired Watch for a live sensor workout. Accept any Health permissions on the Watch, and pause or finish there.")
                .font(.callout).foregroundStyle(.secondary)
            }
            Button { Task { await recorder.start(activity: activity) } } label: {
              Label("Record a timed session here", systemImage: "timer")
            }.buttonStyle(.bordered).disabled(recorder.phase == .preparing || recorder.watchLaunchInProgress)
            Text("A timed session records the chosen activity and duration in Health/Fitness. No GPS route, distance or calories are estimated by this timer.")
              .font(.caption).foregroundStyle(.secondary)
            if let message = recorder.watchMessage { Text(message).foregroundStyle(RoburStyle.orange) }
          }
          if let notice = recorder.saveNotice { Label(notice, systemImage: "checkmark.circle").foregroundStyle(RoburStyle.orange) }
          if let error = recorder.error { Text(error).foregroundStyle(.red) }
          if recorder.phase == .saving || recorder.phase == .preparing || recorder.watchLaunchInProgress { ProgressView() }
        }.frame(maxWidth: 700).padding(24).frame(maxWidth: .infinity, alignment: .leading)
      }.background(RoburStyle.background)
        .navigationTitle("Record workout").navigationBarTitleDisplayMode(.inline)
        .toolbar { Button(recorder.isActive ? "Keep recording" : "Done") { dismiss() } }
        .onAppear { activity = recorder.pendingActivity ?? .functionalStrength; recorder.clearPendingStart() }
        .sheet(item: $reviewing) { WorkoutReviewEditor(workout: $0, onSaved: { dismiss() }) }
        .confirmationDialog("Discard this timed recording?", isPresented: $confirmDiscard) {
          Button("Discard", role: .destructive) { recorder.discard() }
        } message: { Text("An unsaved workout cannot be recovered after discarding.") }
    }.tint(RoburStyle.orange)
  }
}
