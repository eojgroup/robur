import SwiftUI
import UIKit

@main
struct RoburApp: App {
  @UIApplicationDelegateAdaptor(RoburAppDelegate.self) private var appDelegate
  @StateObject private var healthKit = HealthKitClient()
  @StateObject private var pushNotifications = PushNotificationClient.shared

  var body: some Scene {
    WindowGroup {
      RoburTodayView()
        .environmentObject(healthKit)
        .environmentObject(pushNotifications)
    }
  }
}

struct RoburTodayView: View {
  @EnvironmentObject private var healthKit: HealthKitClient
  @EnvironmentObject private var pushNotifications: PushNotificationClient

  private var snapshot: FitnessSnapshot {
    healthKit.snapshot ?? RoburData.today
  }

  var body: some View {
    NavigationStack {
      ScrollView {
        VStack(alignment: .leading, spacing: 22) {
          header
          permissionPrompts
          Divider()
          scores
          vitals
          Divider()
          recommendation
          Divider()
          week
        }
        .padding()
      }
      .background(Color(red: 0.95, green: 0.97, blue: 0.95))
      .navigationTitle(RoburData.appName)
      .toolbar {
        Button {
          healthKit.requestAuthorization()
        } label: {
          Image(systemName: "heart.text.square")
        }
        .accessibilityLabel("Connect Apple Health")
      }
      .task {
        await healthKit.refreshTodaySnapshot()
        pushNotifications.refreshAuthorizationStatus()
      }
    }
  }

  private var header: some View {
    VStack(alignment: .leading, spacing: 5) {
      Text("TODAY")
        .font(.system(size: 38, weight: .black, design: .rounded))
      Text(healthKit.statusText)
        .font(.subheadline.weight(.semibold))
        .foregroundStyle(.secondary)
    }
  }

  private var permissionPrompts: some View {
    VStack(spacing: 12) {
      PermissionCard(
        systemImage: "heart.text.square.fill",
        title: healthKit.promptTitle,
        message: healthKit.promptMessage,
        buttonTitle: healthKit.authorizationRequested ? "Refresh Health Data" : "Connect",
        tint: .green
      ) {
        if healthKit.authorizationRequested {
          Task {
            await healthKit.refreshTodaySnapshot()
          }
        } else {
          healthKit.requestAuthorization()
        }
      }

      PermissionCard(
        systemImage: "bell.badge.fill",
        title: pushNotifications.promptTitle,
        message: pushNotifications.promptMessage,
        buttonTitle: pushNotifications.authorizationStatus == .denied ? "Open Settings" : "Enable",
        tint: .blue
      ) {
        if pushNotifications.authorizationStatus == .denied,
           let url = URL(string: UIApplication.openSettingsURLString) {
          UIApplication.shared.open(url)
        } else {
          pushNotifications.requestAuthorization()
        }
      }
    }
  }

  private var scores: some View {
    VStack(spacing: 18) {
      ScoreRow(title: "Recovery", value: snapshot.recoveryScore)
      ScoreRow(title: "Training load", value: snapshot.trainingLoad)
    }
  }

  private var vitals: some View {
    VStack(spacing: 12) {
      DataRow(title: "Sleep", value: RoburData.duration(snapshot.sleepMinutes))
      DataRow(title: "Resting HR", value: "\(snapshot.restingHeartRateBpm) bpm")
      DataRow(title: "HRV", value: "\(snapshot.heartRateVariabilityMs) ms")
    }
  }

  private var recommendation: some View {
    VStack(alignment: .leading, spacing: 8) {
      Text("TODAY'S RECOMMENDATION")
        .font(.caption.bold())
        .foregroundStyle(.green)
      Text(snapshot.recommendation.title)
        .font(.title2.bold())
      Text(snapshot.recommendation.prescription)
        .font(.headline)
      Text(snapshot.recommendation.rationale)
        .font(.body)
        .foregroundStyle(.secondary)
        .fixedSize(horizontal: false, vertical: true)
    }
    .frame(maxWidth: .infinity, alignment: .leading)
  }

  private var week: some View {
    VStack(alignment: .leading, spacing: 12) {
      Text("THIS WEEK")
        .font(.caption.bold())
        .foregroundStyle(.green)
      DataRow(title: "Running", value: String(format: "%.1f km", snapshot.week.runningKm))
      DataRow(title: "Cycling", value: String(format: "%.0f km", snapshot.week.cyclingKm))
      DataRow(title: "Strength", value: "\(snapshot.week.strengthSessions) sessions")
      DataRow(title: "Training", value: RoburData.duration(snapshot.week.trainingMinutes))
    }
  }
}

struct ScoreRow: View {
  let title: String
  let value: Int

  var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      HStack {
        Text(title)
          .foregroundStyle(.secondary)
        Spacer()
        Text("\(value)")
          .font(.headline)
      }
      ProgressView(value: Double(value), total: 100)
        .tint(.green)
    }
  }
}

struct DataRow: View {
  let title: String
  let value: String

  var body: some View {
    HStack {
      Text(title)
        .foregroundStyle(.secondary)
      Spacer()
      Text(value)
        .font(.headline)
    }
  }
}

struct PermissionCard: View {
  let systemImage: String
  let title: String
  let message: String
  let buttonTitle: String
  let tint: Color
  let action: () -> Void

  var body: some View {
    HStack(alignment: .top, spacing: 12) {
      Image(systemName: systemImage)
        .font(.title2)
        .foregroundStyle(tint)
        .frame(width: 34, height: 34)

      VStack(alignment: .leading, spacing: 6) {
        Text(title)
          .font(.headline)
        Text(message)
          .font(.subheadline)
          .foregroundStyle(.secondary)
          .fixedSize(horizontal: false, vertical: true)
      }

      Spacer(minLength: 8)

      Button(buttonTitle, action: action)
        .buttonStyle(.borderedProminent)
        .tint(tint)
    }
    .padding()
    .background(Color.white)
    .clipShape(RoundedRectangle(cornerRadius: 8))
  }
}
