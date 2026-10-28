import Foundation
import Combine
import CoreLocation
import UIKit

@MainActor
final class RoburServices {
  static let shared = RoburServices()
  let journal = WorkoutJournal()
  lazy var gymMonitor = GymMonitor(journal: journal)
}

@MainActor
final class RoburAppDelegate: NSObject, UIApplicationDelegate {
  func application(_ application: UIApplication,
                   didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
    // Reconnect the delegate immediately when iOS wakes the app for a region event.
    _ = RoburServices.shared.gymMonitor
    return true
  }
}

@MainActor
final class GymMonitor: NSObject, ObservableObject, CLLocationManagerDelegate {
  @Published private(set) var enabled: Bool
  @Published private(set) var status = "Automatic detection is off."
  @Published private(set) var monitoredGymIDs: Set<UUID> = []
  @Published private(set) var error: String?
  private let manager = CLLocationManager()
  private let journal: WorkoutJournal
  private let defaults: UserDefaults
  private let preferenceKey = "RoburAutomaticGymDetection"
  private let prefix = "robur.gym."
  private var subscriptions: Set<AnyCancellable> = []
  private var upgradeRequested = false

  init(journal: WorkoutJournal, defaults: UserDefaults = .standard) {
    self.journal = journal
    self.defaults = defaults
    enabled = defaults.bool(forKey: preferenceKey)
    super.init()
    manager.delegate = self
    journal.$gyms.receive(on: DispatchQueue.main).sink { [weak self] _ in self?.refresh() }.store(in: &subscriptions)
    NotificationCenter.default.publisher(for: UIApplication.didBecomeActiveNotification)
      .sink { [weak self] _ in self?.refresh() }.store(in: &subscriptions)
    refresh()
  }

  func setEnabled(_ value: Bool) {
    enabled = value
    defaults.set(value, forKey: preferenceKey)
    error = nil
    if value {
      switch manager.authorizationStatus {
      case .notDetermined:
        upgradeRequested = true
        manager.requestWhenInUseAuthorization()
      case .authorizedWhenInUse: manager.requestAlwaysAuthorization()
      default: break
      }
    } else {
      journal.endAutomaticVisit()
    }
    refresh()
  }

  func refresh() {
    let existing = manager.monitoredRegions.filter { $0.identifier.hasPrefix(prefix) }
    let eligible = GymMonitoringPlan.locations(journal.gyms)
    let authorized = manager.authorizationStatus == .authorizedAlways
    let precise = manager.accuracyAuthorization == .fullAccuracy
    let available = CLLocationManager.isMonitoringAvailable(for: CLCircularRegion.self)
    let background = UIApplication.shared.backgroundRefreshStatus == .available
    let canMonitor = enabled && authorized && precise && available && background
    let targetIDs = canMonitor ? Set(eligible.map(\.id)) : []
    for region in existing {
      if !targetIDs.contains(gymID(for: region) ?? UUID()) { manager.stopMonitoring(for: region) }
    }
    monitoredGymIDs = targetIDs
    guard canMonitor else {
      journal.endAutomaticVisit()
      if !enabled { status = "Automatic detection is off." }
      else if !available { status = "This device does not support gym region monitoring. Manual check-in is available." }
      else if !authorized { status = "Allow Always location access in Settings to detect arrivals and departures in the background." }
      else if !precise { status = "Enable Precise Location in Settings to detect saved gym regions." }
      else { status = "Enable Background App Refresh for Robur in Settings to receive automatic visits." }
      return
    }
    for gym in eligible {
      let identifier = prefix + gym.id.uuidString
      guard let latitude = gym.latitude, let longitude = gym.longitude else { continue }
      let radius = min(200, manager.maximumRegionMonitoringDistance)
      guard radius > 0 else { continue }
      if let current = existing.first(where: { $0.identifier == identifier }) as? CLCircularRegion {
        if current.center.latitude == latitude && current.center.longitude == longitude && current.radius == radius { continue }
        manager.stopMonitoring(for: current)
      }
      let region = CLCircularRegion(center: CLLocationCoordinate2D(latitude: latitude, longitude: longitude),
                                    radius: radius, identifier: identifier)
      region.notifyOnEntry = true
      region.notifyOnExit = true
      manager.startMonitoring(for: region)
    }
    let positionedCount = journal.gyms.filter { $0.latitude != nil && $0.longitude != nil }.count
    status = eligible.isEmpty ? "Save a gym with its current position to enable automatic visits."
      : "Detecting visits at \(eligible.count) saved places\(positionedCount > 20 ? " (first 20 with positions; iOS limit)" : "")."
  }

  func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
    if enabled && upgradeRequested && manager.authorizationStatus == .authorizedWhenInUse {
      upgradeRequested = false
      manager.requestAlwaysAuthorization()
    }
    refresh()
  }

  func locationManager(_ manager: CLLocationManager, didStartMonitoringFor region: CLRegion) {
    manager.requestState(for: region)
  }

  func locationManager(_ manager: CLLocationManager, didDetermineState state: CLRegionState, for region: CLRegion) {
    if state == .inside { arrive(region) }
    else if state == .outside { depart(region) }
  }

  func locationManager(_ manager: CLLocationManager, didEnterRegion region: CLRegion) { arrive(region) }
  func locationManager(_ manager: CLLocationManager, didExitRegion region: CLRegion) { depart(region) }

  func locationManager(_ manager: CLLocationManager, monitoringDidFailFor region: CLRegion?, withError error: Error) {
    self.error = "Automatic visit detection failed: \(error.localizedDescription). Manual check-in is still available."
    if let region, let id = gymID(for: region) { monitoredGymIDs.remove(id) }
  }

  private func gymID(for region: CLRegion) -> UUID? {
    guard region.identifier.hasPrefix(prefix) else { return nil }
    return UUID(uuidString: String(region.identifier.dropFirst(prefix.count)))
  }

  private func arrive(_ region: CLRegion) {
    guard enabled, manager.authorizationStatus == .authorizedAlways,
          let id = gymID(for: region), monitoredGymIDs.contains(id) else { return }
    journal.automaticArrival(gymID: id)
  }

  private func depart(_ region: CLRegion) {
    guard enabled, let id = gymID(for: region) else { return }
    journal.automaticDeparture(gymID: id)
  }
}
