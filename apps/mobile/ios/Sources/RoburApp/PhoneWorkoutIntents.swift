import AppIntents

/// A distinct AppEnum keeps the shared workout model independent of App Intents.
enum PhoneWorkoutActivity: String, AppEnum {
  case running, cycling, walking, swimming, tennis, racketSports
  case traditionalStrength, functionalStrength, hiit, mobility, hiking, rowing, other

  static var typeDisplayRepresentation: TypeDisplayRepresentation { "Workout type" }
  static var caseDisplayRepresentations: [PhoneWorkoutActivity: DisplayRepresentation] {
    [.running: "Running", .cycling: "Cycling", .walking: "Walking", .swimming: "Swimming",
     .tennis: "Tennis", .racketSports: "Racket sports", .traditionalStrength: "Traditional strength",
     .functionalStrength: "Functional strength", .hiit: "HIIT", .mobility: "Mobility",
     .hiking: "Hiking", .rowing: "Rowing", .other: "Other workout"]
  }
  var activity: WorkoutActivity { WorkoutActivity(rawValue: rawValue) ?? .functionalStrength }
}

struct OpenRoburWorkoutIntent: AppIntent {
  static var title: LocalizedStringResource { "Open Robur workout" }
  static var description: IntentDescription {
    IntentDescription("Open the selected workout in Robur. Review it and tap Start to begin recording. You can assign this shortcut to your iPhone Action button.")
  }
  static var openAppWhenRun: Bool { true }

  @Parameter(title: "Workout type", default: .functionalStrength)
  var activity: PhoneWorkoutActivity

  static var parameterSummary: some ParameterSummary {
    Summary("Open \(\.$activity) workout in Robur")
  }

  @MainActor
  func perform() async throws -> some IntentResult & ProvidesDialog {
    PhoneWorkoutRecorder.shared.queueStart(activity: activity.activity)
    return .result(dialog: "Review your workout in Robur, then tap Start.")
  }
}

struct RoburPhoneWorkoutShortcuts: AppShortcutsProvider {
  static var appShortcuts: [AppShortcut] {
    AppShortcut(intent: OpenRoburWorkoutIntent(),
      phrases: ["Open a workout in \(.applicationName)", "Prepare a workout in \(.applicationName)"],
      shortTitle: "Open workout", systemImageName: "figure.run")
  }
}
