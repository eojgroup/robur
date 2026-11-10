import SwiftUI

@main
struct RoburApp: App {
  @StateObject private var journal = WorkoutJournal()
  @StateObject private var healthKit = HealthKitClient()

  var body: some Scene {
    WindowGroup {
      RoburRootView()
        .environmentObject(healthKit)
        .environmentObject(journal)
    }
  }
}
