import SwiftUI

// Semantic surfaces follow light/dark mode; colour never carries meaning alone.
enum RoburStyle {
  static let navy = Color(red: 0.055, green: 0.10, blue: 0.18)
  static let beige = Color(red: 0.95, green: 0.91, blue: 0.83)
  static let orange = adaptive(light: UIColor(red: 0.66, green: 0.25, blue: 0.055, alpha: 1), dark: UIColor(red: 1, green: 0.64, blue: 0.32, alpha: 1))
  // Compatibility names keep existing screens on the same shared palette.
  static let teal = orange
  static let amber = adaptive(light: UIColor(red: 0.73, green: 0.32, blue: 0.055, alpha: 1), dark: UIColor(red: 1, green: 0.72, blue: 0.43, alpha: 1))
  static let blue = adaptive(light: UIColor(red: 0.09, green: 0.17, blue: 0.28, alpha: 1), dark: UIColor(red: 0.90, green: 0.85, blue: 0.75, alpha: 1))
  static let ink = adaptive(light: UIColor(red: 0.055, green: 0.10, blue: 0.18, alpha: 1), dark: UIColor(red: 0.96, green: 0.93, blue: 0.87, alpha: 1))
  static let background = adaptive(light: UIColor(red: 0.96, green: 0.94, blue: 0.90, alpha: 1), dark: UIColor(red: 0.035, green: 0.065, blue: 0.11, alpha: 1))
  static let surface = adaptive(light: UIColor(red: 1, green: 0.99, blue: 0.965, alpha: 1), dark: UIColor(red: 0.07, green: 0.115, blue: 0.185, alpha: 1))
  static let contentWidth: CGFloat = 1240
  private static func adaptive(light: UIColor, dark: UIColor) -> Color {
    Color(uiColor: UIColor { $0.userInterfaceStyle == .dark ? dark : light })
  }
}

/// Uses the available window width, so iPad Split View also falls back to one column.
struct AdaptiveCardLayout: Layout {
  var spacing: CGFloat = 20
  static func columnCount(for width: CGFloat) -> Int { width >= 1100 ? 3 : (width >= 760 ? 2 : 1) }

  func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
    let width = max(0, proposal.width ?? 360)
    let columns = Self.columnCount(for: width)
    let columnWidth = max(0, (width - CGFloat(columns - 1) * spacing) / CGFloat(columns))
    var height: CGFloat = 0
    for first in stride(from: 0, to: subviews.count, by: columns) {
      let rowHeight = (first..<min(first + columns, subviews.count)).map {
        subviews[$0].sizeThatFits(ProposedViewSize(width: columnWidth, height: nil)).height
      }.max() ?? 0
      height += rowHeight + (first == 0 ? 0 : spacing)
    }
    return CGSize(width: width, height: height)
  }

  func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
    let columns = Self.columnCount(for: bounds.width)
    let columnWidth = max(0, (bounds.width - CGFloat(columns - 1) * spacing) / CGFloat(columns))
    var y = bounds.minY
    for first in stride(from: 0, to: subviews.count, by: columns) {
      let rowHeight = (first..<min(first + columns, subviews.count)).map {
        subviews[$0].sizeThatFits(ProposedViewSize(width: columnWidth, height: nil)).height
      }.max() ?? 0
      for index in first..<min(first + columns, subviews.count) {
        subviews[index].place(at: CGPoint(x: bounds.minX + CGFloat(index - first) * (columnWidth + spacing), y: y),
          anchor: .topLeading, proposal: ProposedViewSize(width: columnWidth, height: nil))
      }
      y += rowHeight + spacing
    }
  }
}

extension View {
  func roburCard() -> some View {
    self.padding(20).frame(maxWidth: .infinity, alignment: .leading)
      .background(RoburStyle.surface, in: RoundedRectangle(cornerRadius: 24))
      .overlay { RoundedRectangle(cornerRadius: 24).stroke(RoburStyle.ink.opacity(0.06), lineWidth: 1) }
  }
}

struct RoburRootView: View {
  @AppStorage("RoburAppearance") private var appearance = "system"
  @Environment(\.scenePhase) private var scenePhase
  @EnvironmentObject private var healthKit: HealthKitClient
  @EnvironmentObject private var journal: WorkoutJournal
  @StateObject private var recorder = PhoneWorkoutRecorder.shared
  @StateObject private var reviews = WorkoutReviewStore.shared
  @State private var selectedTab = 0
  var body: some View {
    TabView(selection: $selectedTab) {
      RoburTodayView().tabItem { Label("Today", systemImage: "sun.max") }.tag(0)
      WorkoutHistoryView().tabItem { Label("Workouts", systemImage: "figure.strengthtraining.traditional") }.tag(1)
      FitnessHistoryView().tabItem { Label("Progress", systemImage: "chart.xyaxis.line") }.tag(2)
      TrainingPlannerView().tabItem { Label("Plan", systemImage: "calendar") }.tag(3)
      GymLocationsView().tabItem { Label("Places", systemImage: "mappin.and.ellipse") }.tag(4)
    }
    .tint(RoburStyle.orange)
    .foregroundStyle(RoburStyle.ink)
    .preferredColorScheme(appearance == "dark" ? .dark : (appearance == "light" ? .light : nil))
    .sheet(isPresented: $recorder.presentationRequested) { WorkoutCaptureView() }
    .task {
      WorkoutReviewSync.shared.activate()
      journal.synchronizeReviews()
      WorkoutMotionSuggestions.shared.setForeground(scenePhase == .active)
    }
    .onChange(of: reviews.reviews) { _, _ in journal.synchronizeReviews() }
    .onOpenURL { url in
      if url.host == "today" { selectedTab = 0 }
      else if url.host == "progress" { selectedTab = 2 }
      else if TrainingPlannerStore.shared.open(url: url) { selectedTab = 3 }
    }
    .onChange(of: scenePhase) { _, phase in
      WorkoutMotionSuggestions.shared.setForeground(phase == .active)
      if phase == .active { journal.synchronizeReviews() }
      if phase == .active && (healthKit.lastUpdated.map { Date().timeIntervalSince($0) > 60 } ?? true) {
        Task { await healthKit.refreshTodaySnapshot() }
      }
    }
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
