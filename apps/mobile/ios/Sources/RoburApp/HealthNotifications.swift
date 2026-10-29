import SwiftUI
import UserNotifications
import Combine

@MainActor
final class HealthNotificationManager: ObservableObject {
  static let shared = HealthNotificationManager()
  @Published private(set) var status = "Notifications are off until you enable them."
  @Published private(set) var error: String?
  private let center = UNUserNotificationCenter.current()
  private let defaults = UserDefaults.standard
  private var revision = 0
  private let identifiers = ["robur.readiness", "robur.weekly"] + (9...20).map { "robur.move.\($0)" }

  func applySettings() async {
    revision += 1
    let currentRevision = revision
    let daily = defaults.bool(forKey: "RoburDailyReminder")
    let weekly = defaults.bool(forKey: "RoburWeeklyReminder")
    let movement = defaults.bool(forKey: "RoburMovementReminder")
    let insights = defaults.bool(forKey: "RoburInsightAlerts")
    center.removePendingNotificationRequests(withIdentifiers: identifiers)
    guard daily || weekly || movement || insights else {
      status = "Notifications are off."
      return
    }
    do {
      let granted = try await center.requestAuthorization(options: [.alert, .sound])
      guard currentRevision == revision else { return }
      guard granted else { status = "Notifications are disabled in iOS Settings."; return }
      if daily {
        try await schedule(id: "robur.readiness", title: "A fresh start", body: "Open Robur to refresh your readiness and choose today’s training.", hour: 8)
      }
      if weekly {
        try await schedule(id: "robur.weekly", title: "Your week in perspective", body: "Review your training, activity and recovery trends in Robur.", hour: 18, weekday: 1)
      }
      if movement {
        for hour in 9...20 {
          try await schedule(id: "robur.move.\(hour)", title: "Make room for movement", body: "A short walk or standing break can be part of your day.", hour: hour, minute: 50)
        }
      }
      if currentRevision != revision { await applySettings(); return }
      status = "Your selected reminders are scheduled on this device."
      error = nil
    } catch {
      self.error = "Unable to schedule notifications: \(error.localizedDescription)"
    }
  }

  private func schedule(id: String, title: String, body: String, hour: Int, minute: Int = 0, weekday: Int? = nil) async throws {
    let content = UNMutableNotificationContent()
    content.title = title
    content.body = body
    content.sound = .default
    let components = DateComponents(hour: hour, minute: minute, weekday: weekday)
    let trigger = UNCalendarNotificationTrigger(dateMatching: components, repeats: true)
    try await center.add(UNNotificationRequest(identifier: id, content: content, trigger: trigger))
  }

  func evaluate(summary: InsightsSummary, days: [DailyHealthMetrics], stepsGoal: Double, now: Date = Date()) async {
    guard defaults.bool(forKey: "RoburInsightAlerts") else { return }
    let settings = await center.notificationSettings()
    guard settings.authorizationStatus == .authorized || settings.authorizationStatus == .provisional else { return }
    let calendar = Calendar.current
    let today = calendar.startOfDay(for: now)
    if let day = days.first(where: { calendar.isDate($0.date, inSameDayAs: now) }), let steps = day.steps, steps >= stepsGoal {
      await insight(key: "steps.\(today.timeIntervalSince1970)", title: "Daily goal reached", body: "You reached your step goal. Your activity overview has been updated.")
    }
    if summary.loadStatus.lowercased() == "high" {
      await insight(key: "load.\(today.timeIntervalSince1970)", title: "Check your training balance", body: "Your recent training load is above your usual range. Open Robur to review the trend and how you feel.")
    }
    if let trend = summary.trends.first(where: { $0.direction.lowercased().contains("sustained") }) {
      let week = calendar.dateInterval(of: .weekOfYear, for: now)?.start ?? today
      await insight(key: "trend.\(week.timeIntervalSince1970)", title: "A longer-term pattern", body: "A sustained health trend is available in your private Robur overview.")
      _ = trend
    }
  }

  private func insight(key: String, title: String, body: String) async {
    let storageKey = "RoburLastInsight." + key.components(separatedBy: ".").first!
    guard defaults.string(forKey: storageKey) != key else { return }
    let content = UNMutableNotificationContent()
    content.title = title
    content.body = body
    content.sound = .default
    do {
      try await center.add(UNNotificationRequest(identifier: "robur.insight." + key, content: content,
        trigger: UNTimeIntervalNotificationTrigger(timeInterval: 2, repeats: false)))
      defaults.set(key, forKey: storageKey)
    } catch { self.error = "Unable to deliver insight: \(error.localizedDescription)" }
  }
}

struct HealthSettingsView: View {
  @EnvironmentObject private var healthKit: HealthKitClient
  @StateObject private var notifications = HealthNotificationManager.shared
  @AppStorage("RoburDailyReminder") private var daily = false
  @AppStorage("RoburWeeklyReminder") private var weekly = false
  @AppStorage("RoburMovementReminder") private var movement = false
  @AppStorage("RoburInsightAlerts") private var alerts = false
  @AppStorage("RoburStepsGoal") private var stepsGoal: Double = 8000
  @AppStorage("RoburExerciseGoal") private var exerciseGoal: Double = 30
  @AppStorage("RoburMaxHeartRate") private var maxHR: Double = 190
  @State private var pendingStepGoal: Double = 8000
  @State private var pendingExerciseGoal: Double = 30
  @State private var confirmGoals = false

  private var calculatedMax: Double { Double(208) - 0.7 * Double(healthKit.profile.age ?? 26) }

  var body: some View {
    Form {
      Section("Your goals") {
        Stepper("Steps: \(Int(pendingStepGoal)) / day", value: $pendingStepGoal, in: 1000...40000, step: 500)
        Stepper("Exercise: \(Int(pendingExerciseGoal)) min / day", value: $pendingExerciseGoal, in: 5...180, step: 5)
        Button("Apply goals") { confirmGoals = true }
        if let suggestion = TrainingInsights.adaptiveStepGoal(days: healthKit.dailyMetrics, current: stepsGoal) {
          Text(suggestion.reason).font(.caption).foregroundStyle(.secondary)
          Button("Review suggested target: \(Int(suggestion.proposed)) steps") {
            pendingStepGoal = suggestion.proposed
            confirmGoals = true
          }
        }
        Text("Goal changes always require your confirmation. Adaptive suggestions use your recent 30-day activity.")
          .font(.caption).foregroundStyle(.secondary)
      }
      Section("Heart-rate zones") {
        Stepper("Maximum heart rate: \(Int(maxHR)) bpm", value: $maxHR, in: 100...240, step: 1)
        if healthKit.profile.age != nil {
          Button("Use age estimate (\(Int(calculatedMax)) bpm)") { maxHR = calculatedMax.rounded() }
        }
        Text("Default: 190 bpm until configured. Age estimate: 208 − 0.7 × age. Zones use 50/60/70/80/90% of max HR; these are training estimates, not a clinical test.")
          .font(.caption).foregroundStyle(.secondary)
      }
      Section("Local notifications") {
        Toggle("Daily readiness reminder · 08:00", isOn: $daily)
        Toggle("Weekly review · Sunday 18:00", isOn: $weekly)
        Toggle("Movement breaks · 09:50–20:50", isOn: $movement)
        Toggle("Goal and sustained-trend insights", isOn: $alerts)
        Text(notifications.status).font(.caption).foregroundStyle(.secondary)
        if let error = notifications.error { Text(error).font(.caption).foregroundStyle(.red) }
        Text("Times follow your device’s local time. Movement breaks follow a schedule; they do not infer that you are sitting. Goal and trend alerts are checked when Health data refreshes. Health values are not included on the lock screen.")
          .font(.caption).foregroundStyle(.secondary)
      }
      Section("Health access") {
        Button("Review requested Health categories") { healthKit.requestAuthorization() }
        Text("Weight, height, body composition and supported Health characteristics are optional. Apple’s Medical ID, emergency contacts and clinical records are not imported. Manage existing permissions in the Health app.")
          .font(.caption).foregroundStyle(.secondary)
      }
    }
    .navigationTitle("Goals & reminders")
    .onAppear { pendingStepGoal = stepsGoal; pendingExerciseGoal = exerciseGoal }
    .onChange(of: daily) { _, _ in refreshNotifications() }
    .onChange(of: weekly) { _, _ in refreshNotifications() }
    .onChange(of: movement) { _, _ in refreshNotifications() }
    .onChange(of: alerts) { _, _ in refreshNotifications() }
    .confirmationDialog("Apply these daily goals?", isPresented: $confirmGoals) {
      Button("Apply \(Int(pendingStepGoal)) steps and \(Int(pendingExerciseGoal)) exercise minutes") {
        stepsGoal = pendingStepGoal; exerciseGoal = pendingExerciseGoal
      }
    }
  }

  private func refreshNotifications() { Task { await notifications.applySettings() } }
}
