import Foundation
import UIKit
import UserNotifications

@MainActor
final class PushNotificationClient: NSObject, ObservableObject, UNUserNotificationCenterDelegate {
  static let shared = PushNotificationClient()

  @Published private(set) var authorizationStatus: UNAuthorizationStatus = .notDetermined
  @Published private(set) var deviceToken: String?
  @Published private(set) var lastError: String?

  var promptTitle: String {
    switch authorizationStatus {
    case .authorized, .provisional, .ephemeral:
      return "Notifications enabled"
    case .denied:
      return "Notifications disabled"
    case .notDetermined:
      return "Enable reminders"
    @unknown default:
      return "Notification status unknown"
    }
  }

  var promptMessage: String {
    switch authorizationStatus {
    case .authorized, .provisional, .ephemeral:
      return "Robur can send recovery, training-load, and workout recommendation updates."
    case .denied:
      return "Notifications are off. Enable them in Settings to receive recovery and training-load updates."
    case .notDetermined:
      return "Robur can remind you when recovery changes, planned sessions shift, or a training-load update needs attention."
    @unknown default:
      return "Open Settings if notification permissions need to be adjusted."
    }
  }

  var statusText: String {
    if let lastError {
      return lastError
    }

    switch authorizationStatus {
    case .authorized, .provisional, .ephemeral:
      return deviceToken == nil ? "Notifications authorized" : "Push notifications ready"
    case .denied:
      return "Notifications denied"
    case .notDetermined:
      return "Notifications available"
    @unknown default:
      return "Notification status unknown"
    }
  }

  func configure() {
    UNUserNotificationCenter.current().delegate = self
    refreshAuthorizationStatus()
  }

  func refreshAuthorizationStatus() {
    UNUserNotificationCenter.current().getNotificationSettings { [weak self] settings in
      Task { @MainActor in
        self?.authorizationStatus = settings.authorizationStatus
        if settings.authorizationStatus == .authorized || settings.authorizationStatus == .provisional {
          UIApplication.shared.registerForRemoteNotifications()
        }
      }
    }
  }

  func requestAuthorization() {
    UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .badge, .sound]) { [weak self] granted, error in
      Task { @MainActor in
        self?.lastError = error?.localizedDescription
        self?.refreshAuthorizationStatus()
        if granted {
          UIApplication.shared.registerForRemoteNotifications()
        }
      }
    }
  }

  func didRegisterForRemoteNotifications(deviceToken: Data) {
    let token = deviceToken.map { String(format: "%02x", $0) }.joined()
    self.deviceToken = token
    lastError = nil

    Task {
      do {
        try await RoburAPIClient.shared.registerPushDevice(deviceToken: token)
      } catch {
        await MainActor.run {
          self.lastError = "Push token received but API registration failed."
        }
      }
    }
  }

  func didFailToRegisterForRemoteNotifications(error: Error) {
    lastError = error.localizedDescription
  }

  nonisolated func userNotificationCenter(
    _ center: UNUserNotificationCenter,
    willPresent notification: UNNotification
  ) async -> UNNotificationPresentationOptions {
    [.banner, .sound, .badge]
  }
}

final class RoburAppDelegate: NSObject, UIApplicationDelegate {
  func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil
  ) -> Bool {
    Task { @MainActor in
      PushNotificationClient.shared.configure()
    }
    return true
  }

  func application(_ application: UIApplication, didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data) {
    Task { @MainActor in
      PushNotificationClient.shared.didRegisterForRemoteNotifications(deviceToken: deviceToken)
    }
  }

  func application(_ application: UIApplication, didFailToRegisterForRemoteNotificationsWithError error: Error) {
    Task { @MainActor in
      PushNotificationClient.shared.didFailToRegisterForRemoteNotifications(error: error)
    }
  }
}
