import SwiftUI

struct WorkoutLaunchPanel: View {
  @EnvironmentObject private var healthKit: HealthKitClient
  @EnvironmentObject private var journal: WorkoutJournal
  @StateObject private var recorder = PhoneWorkoutRecorder.shared
  @StateObject private var reviews = WorkoutReviewStore.shared
  @StateObject private var motion = WorkoutMotionSuggestions.shared
  @State private var selected: WorkoutRecord?

  private var pending: [WorkoutRecord] {
    WorkoutReviewPolicy.pending(workouts: healthKit.workouts, annotations: journal.annotations,
      reviewedIDs: Set(reviews.reviews.keys))
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 16) {
      HStack {
        Label("Make this session yours", systemImage: "figure.run").font(.headline)
        Spacer()
        Button(recorder.isActive ? "Continue workout" : "Start workout") {
          recorder.queueStart(activity: .functionalStrength)
        }.buttonStyle(.borderedProminent)
      }
      if recorder.isActive {
        TimelineView(.periodic(from: Date(), by: 1)) { context in
          Text("\(recorder.activity.title) · \(recorder.phase.title) · \(Duration.seconds(recorder.elapsed(at: context.date)).formatted(.time(pattern: .hourMinuteSecond)))")
            .font(.subheadline).monospacedDigit()
        }
      } else {
        Text("Record on Apple Watch for live sensor metrics, or save a timed session from this device. Finished sessions appear in Apple Health and Fitness.")
          .font(.subheadline).foregroundStyle(.secondary)
      }
      if let type = motion.suggestion, !recorder.isActive {
        HStack {
          VStack(alignment: .leading, spacing: 5) {
            Text("Are you \(type == .running ? "running" : "cycling")?").font(.headline)
            Text("Motion is a suggestion. Confirm before recording.").font(.caption).foregroundStyle(.secondary)
          }
          Spacer()
          Button("Start") { motion.dismissSuggestion(); recorder.queueStart(activity: type) }
          Button { motion.dismissSuggestion() } label: { Image(systemName: "xmark") }.accessibilityLabel("Dismiss motion suggestion")
        }
      }
      if !pending.isEmpty {
        Divider()
        Label("\(pending.count) recent workouts to review", systemImage: "checklist").font(.subheadline.bold())
        ForEach(Array(pending.prefix(3))) { workout in
          Button { selected = workout } label: {
            HStack {
              Image(systemName: workout.symbol)
              VStack(alignment: .leading) {
                Text(workout.title)
                Text(workout.start.formatted(date: .abbreviated, time: .shortened)).font(.caption).foregroundStyle(.secondary)
              }
              Spacer()
              Text("Muscles & notes").font(.caption)
              Image(systemName: "chevron.right").font(.caption)
            }
          }.buttonStyle(.plain)
        }
      }
    }.roburCard()
      .sheet(item: $selected) { workout in WorkoutReviewEditor(workout: workout) }
      .onChange(of: healthKit.workouts, initial: true) { _, _ in remind() }
      .onChange(of: reviews.reviews) { _, _ in remind() }
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
  @State private var notes = ""
  @State private var error: String?
  var onSaved: (() -> Void)? = nil

  var body: some View {
    NavigationStack {
      ScrollView {
        VStack(alignment: .leading, spacing: 22) {
          Label("Workout saved", systemImage: "checkmark.circle.fill").foregroundStyle(RoburStyle.orange).font(.headline)
          Text(workout.title).font(.largeTitle.bold())
          Text("\(Int(workout.minutes)) min · \(workout.start.formatted(date: .abbreviated, time: .shortened))").foregroundStyle(.secondary)
          Text("What did you train?").font(.title2.bold())
          Text("Choose the muscles you worked, or leave this blank for a session that doesn’t need muscle tags.").font(.subheadline).foregroundStyle(.secondary)
          LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 10) {
            ForEach(MuscleGroup.allCases) { group in
              Button {
                if muscles.contains(group) { muscles.remove(group) } else { muscles.insert(group) }
              } label: {
                HStack {
                  Image(systemName: muscles.contains(group) ? "checkmark.circle.fill" : "circle")
                  Text(group.rawValue).font(.subheadline.bold())
                  Spacer(minLength: 0)
                }.padding(14).background(muscles.contains(group) ? RoburStyle.orange.opacity(0.14) : RoburStyle.surface,
                  in: RoundedRectangle(cornerRadius: 14))
              }.buttonStyle(.plain).accessibilityAddTraits(muscles.contains(group) ? .isSelected : [])
            }
          }
          Text("Session notes").font(.headline)
          TextField("Exercises, sets, progress or how you felt", text: $notes, axis: .vertical)
            .lineLimit(4...8).padding().background(RoburStyle.surface, in: RoundedRectangle(cornerRadius: 16))
            .onChange(of: notes) { _, value in if value.count > 2000 { notes = String(value.prefix(2000)) } }
          if let error { Text(error).foregroundStyle(.red) }
          Text("Your tags and notes stay in Robur and sync privately between your paired iPhone and Watch. The original Health workout and its Fitness effort rating are preserved.")
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
        }
    }.tint(RoburStyle.orange)
  }

  private func save() {
    var annotation = journal.annotations[workout.id] ?? WorkoutAnnotation()
    annotation.muscles = muscles; annotation.notes = notes
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
