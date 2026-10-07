import SwiftUI

@main
struct RoburApp: App {
  @StateObject private var healthKit = HealthKitClient()

  var body: some Scene {
    WindowGroup {
      RoburTodayView()
        .environmentObject(healthKit)
    }
  }
}

struct RoburTodayView: View {
  @EnvironmentObject private var healthKit: HealthKitClient

  private var snapshot: FitnessSnapshot {
    healthKit.snapshot ?? RoburData.noHealthData
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
          Divider()
          VStack(alignment: .leading, spacing: 8) {
            Text("Your privacy")
              .font(.headline)
            Text("Your Health data stays on this device. Robur does not upload it, track you, or require an account. Manage access in Apple Health under your profile, Apps and Services, Robur.")
            Text("Recovery and training load are general fitness estimates, not medical advice. Adjust activity to how you feel.")
          }
          .font(.footnote)
          .foregroundStyle(.secondary)
        }
        .padding()
      }
      .refreshable { await healthKit.refreshTodaySnapshot() }
      .background(Color(red: 0.95, green: 0.97, blue: 0.95))
      .navigationTitle(RoburData.appName)
      .toolbar {
        Button {
          if healthKit.authorizationRequested {
            Task {
              await healthKit.refreshTodaySnapshot()
            }
          } else {
            healthKit.requestAuthorization()
          }
        } label: {
          Image(systemName: "heart.text.square")
        }
        .accessibilityLabel(healthKit.authorizationRequested ? "Refresh Apple Health" : "Connect Apple Health")
      }
      .task {
        await healthKit.refreshTodaySnapshot()
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
      DataRow(title: "Sleep", value: durationValue(snapshot.sleepMinutes))
      DataRow(title: "Resting HR", value: metricValue(snapshot.restingHeartRateBpm, unit: "bpm"))
      DataRow(title: "HRV", value: metricValue(snapshot.heartRateVariabilityMs, unit: "ms"))
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

  private func durationValue(_ minutes: Int) -> String {
    minutes > 0 ? RoburData.duration(minutes) : "—"
  }

  private func metricValue(_ value: Int, unit: String) -> String {
    value > 0 ? "\(value) \(unit)" : "—"
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
