import CoreLocation
import Foundation

/// Upgrade cleanup only: unregister regions saved by older versions.
/// This never requests permission, starts monitoring or reads a position.
@MainActor
enum LegacyLocationCleanup {
  private static var hasRun = false

  static func run() {
    guard !hasRun else { return }
    hasRun = true
    let manager = CLLocationManager()
    for region in manager.monitoredRegions where region.identifier.hasPrefix("robur.gym.") {
      manager.stopMonitoring(for: region)
    }
    UserDefaults.standard.removeObject(forKey: "RoburAutomaticGymDetection")
  }
}
