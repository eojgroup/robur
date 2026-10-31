import AppIntents

enum RoburWatchWorkoutStyle: String, AppEnum {
  case running, cycling, walking, swimming, tennis, racketSports
  case traditionalStrength, functionalStrength, hiit, mobility, hiking, rowing, other

  static var typeDisplayRepresentation: TypeDisplayRepresentation { "Workout type" }
  static var caseDisplayRepresentations: [Self: DisplayRepresentation] {
    [.running: "Running", .cycling: "Cycling", .walking: "Walking", .swimming: "Swimming",
     .tennis: "Tennis", .racketSports: "Racket sports", .traditionalStrength: "Traditional strength",
     .functionalStrength: "Functional strength", .hiit: "HIIT", .mobility: "Mobility",
     .hiking: "Hiking", .rowing: "Rowing", .other: "Other workout"]
  }
  var activity: WorkoutActivity { WorkoutActivity(rawValue: rawValue) ?? .functionalStrength }
}

/// Must be compiled directly into the Watch app for Ultra Action button discovery.
struct StartRoburWorkoutIntent: StartWorkoutIntent {
  static var title: LocalizedStringResource { "Start Robur workout" }
  static var description: IntentDescription { "Record the selected workout." }

  @Parameter(title: "Workout type", default: .functionalStrength)
  var workoutStyle: RoburWatchWorkoutStyle

  init() {}
  init(workoutStyle: RoburWatchWorkoutStyle) { self.workoutStyle = workoutStyle }

  static var suggestedWorkouts: [Self] {
    [.init(workoutStyle: .running), .init(workoutStyle: .cycling),
     .init(workoutStyle: .tennis), .init(workoutStyle: .functionalStrength)]
  }
  var displayRepresentation: DisplayRepresentation {
    RoburWatchWorkoutStyle.caseDisplayRepresentations[workoutStyle] ?? "Workout"
  }
  static var parameterSummary: some ParameterSummary { Summary("Start \(\.$workoutStyle) with Robur") }

  @MainActor
  func perform() async throws -> some IntentResult {
    try WatchWorkoutRecorder.shared.startFromIntent(activity: workoutStyle.activity)
    return .result()
  }
}

struct PauseRoburWorkoutIntent: PauseWorkoutIntent {
  static var title: LocalizedStringResource { "Pause Robur workout" }
  @MainActor
  func perform() async throws -> some IntentResult {
    WatchWorkoutRecorder.shared.pause()
    return .result()
  }
}

struct ResumeRoburWorkoutIntent: ResumeWorkoutIntent {
  static var title: LocalizedStringResource { "Resume Robur workout" }
  @MainActor
  func perform() async throws -> some IntentResult {
    WatchWorkoutRecorder.shared.resume()
    return .result()
  }
}

struct RoburWatchWorkoutShortcuts: AppShortcutsProvider {
  static var appShortcuts: [AppShortcut] {
    AppShortcut(intent: StartRoburWorkoutIntent(),
      phrases: ["Start a workout with \(.applicationName)", "Start \(\.$workoutStyle) with \(.applicationName)"],
      shortTitle: "Start workout", systemImageName: "figure.run")
    AppShortcut(intent: PauseRoburWorkoutIntent(), phrases: ["Pause my \(.applicationName) workout"],
      shortTitle: "Pause workout", systemImageName: "pause.fill")
    AppShortcut(intent: ResumeRoburWorkoutIntent(), phrases: ["Resume my \(.applicationName) workout"],
      shortTitle: "Resume workout", systemImageName: "play.fill")
  }
}
