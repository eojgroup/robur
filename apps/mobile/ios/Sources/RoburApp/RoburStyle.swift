import SwiftUI

// Semantic surfaces follow light/dark mode; colour never carries meaning alone.
enum RoburStyle {
  static let teal = adaptive(light: UIColor(red: 0.02, green: 0.42, blue: 0.41, alpha: 1), dark: UIColor(red: 0.33, green: 0.84, blue: 0.76, alpha: 1))
  static let amber = adaptive(light: UIColor(red: 0.65, green: 0.31, blue: 0.02, alpha: 1), dark: UIColor(red: 1, green: 0.72, blue: 0.33, alpha: 1))
  static let blue = adaptive(light: UIColor(red: 0.23, green: 0.40, blue: 0.80, alpha: 1), dark: UIColor(red: 0.53, green: 0.69, blue: 1, alpha: 1))
  private static func adaptive(light: UIColor, dark: UIColor) -> Color {
    Color(uiColor: UIColor { $0.userInterfaceStyle == .dark ? dark : light })
  }
  static let background = Color(uiColor: .systemGroupedBackground)
  static let surface = Color(uiColor: .secondarySystemGroupedBackground)
}

extension View {
  func roburCard() -> some View {
    self.padding(20).frame(maxWidth: .infinity, alignment: .leading)
      .background(RoburStyle.surface, in: RoundedRectangle(cornerRadius: 24))
  }
}

struct RoburRootView: View {
  @StateObject private var journal = WorkoutJournal()
  var body: some View {
    TabView {
      RoburTodayView().tabItem { Label("Today", systemImage: "sun.max") }
      WorkoutHistoryView().tabItem { Label("Workouts", systemImage: "figure.strengthtraining.traditional") }
      FitnessHistoryView().tabItem { Label("Progress", systemImage: "chart.xyaxis.line") }
      GymLocationsView().tabItem { Label("Places", systemImage: "mappin.and.ellipse") }
    }
    .tint(RoburStyle.teal)
    .environmentObject(journal)
    .alert("Workout journal", isPresented: Binding(get: { journal.storageError != nil }, set: { if !$0 { journal.storageError = nil } })) {
      Button("OK") { journal.storageError = nil }
    } message: { Text(journal.storageError ?? "") }
  }
}

struct HistoryRangePicker: View {
  @EnvironmentObject private var healthKit: HealthKitClient
  var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      Picker("History", selection: Binding(get: { healthKit.historyRange }, set: { range in
        Task { await healthKit.loadHistory(range: range) }
      })) {
        ForEach(HistoryRange.allCases) { range in Text(range.rawValue).tag(range) }
      }.pickerStyle(.segmented)
      if healthKit.isLoadingHistory {
        HStack { ProgressView(); Text("Reading Apple Health history…").font(.caption) }
      }
      if let error = healthKit.historyError { Text(error).font(.callout).foregroundStyle(.red) }
    }
  }
}

struct HistoryPermissionView: View {
  @EnvironmentObject private var healthKit: HealthKitClient
  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      Label("Your history, on your device", systemImage: "heart.text.square")
        .font(.headline)
      Text("Share workouts and cardio fitness from Apple Health. Available history depends on the data and access you choose to share.")
        .font(.subheadline).foregroundStyle(.secondary)
      Button("Manage Health access") { healthKit.requestAuthorization() }
        .buttonStyle(.borderedProminent)
    }.roburCard()
  }
}
