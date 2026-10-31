import Foundation
import Combine
import CoreMotion

@MainActor
final class WorkoutMotionSuggestions: ObservableObject {
  static let shared = WorkoutMotionSuggestions()
  @Published private(set) var suggestion: WorkoutActivity?
  @Published private(set) var status = "Optional motion suggestions work while Robur is open."
  private let motion = CMMotionActivityManager()
  private var gate = WorkoutSuggestionGate()
  private var timer: Timer?
  private var active = false

  func setForeground(_ foreground: Bool) {
    active = foreground
    updateMonitoring()
  }

  func updateMonitoring() {
    motion.stopActivityUpdates()
    timer?.invalidate(); timer = nil
    gate.resetObservation()
    guard active, UserDefaults.standard.bool(forKey: "RoburMotionSuggestions") else { suggestion = nil; return }
    guard CMMotionActivityManager.isActivityAvailable() else {
      status = "Motion suggestions are unavailable on this device. Start a workout manually."
      return
    }
    let authorization = CMMotionActivityManager.authorizationStatus()
    guard authorization != .denied && authorization != .restricted else {
      status = "Motion access is off. Enable Motion & Fitness for Robur in Settings, or start manually."
      return
    }
    status = "Looking for sustained running or cycling while Robur is open."
    motion.startActivityUpdates(to: .main) { [weak self] activity in
      Task { @MainActor in
        guard let self, self.active, let activity else { return }
        let confident = activity.confidence == .medium || activity.confidence == .high
        let type: WorkoutActivity? = confident && !activity.automotive && !activity.stationary
          ? (activity.running ? .running : (activity.cycling ? .cycling : nil)) : nil
        self.gate.observe(type, at: Date())
        if type == nil { self.suggestion = nil }
      }
    }
    timer = Timer.scheduledTimer(withTimeInterval: 15, repeats: true) { [weak self] _ in
      Task { @MainActor in
        guard let self, self.active, self.suggestion == nil else { return }
        if let type = self.gate.suggestion(at: Date()) { self.suggestion = type }
      }
    }
  }

  func dismissSuggestion() { suggestion = nil }
}
