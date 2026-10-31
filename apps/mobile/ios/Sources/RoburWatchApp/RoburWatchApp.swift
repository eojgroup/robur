import SwiftUI

@main
struct RoburWatchApp: App {
  var body: some Scene {
    WindowGroup {
      RoburWatchRootView()
    }
  }
}

struct RoburWatchRootView: View {
  @StateObject private var healthKit = HealthKitClient()

  private var snapshot: FitnessSnapshot {
    healthKit.snapshot ?? RoburData.noHealthData
  }

  var body: some View {
    NavigationStack {
      List {
        Section("Today") {
          WatchScoreRow(title: "Recovery", value: snapshot.recoveryScore)
          WatchScoreRow(title: "Load", value: snapshot.trainingLoad)
          Label(durationValue(snapshot.sleepMinutes), systemImage: "moon.fill")
          Label(metricValue(snapshot.restingHeartRateBpm, unit: "bpm"), systemImage: "heart.fill")
          Label(metricValue(snapshot.heartRateVariabilityMs, unit: "ms HRV"), systemImage: "waveform.path.ecg")
        }

        Section("Recommendation") {
          VStack(alignment: .leading, spacing: 4) {
            Text(snapshot.recommendation.title)
              .font(.headline)
            Text(snapshot.recommendation.prescription)
              .font(.caption)
              .foregroundStyle(.secondary)
          }
        }

        Section {
          Text(healthKit.statusText)
            .font(.caption)
            .foregroundStyle(.secondary)
          Button(healthKit.authorizationRequested ? "Refresh Apple Health" : "Connect Apple Health") {
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
      .navigationTitle("Robur")
      .task {
        await healthKit.refreshTodaySnapshot()
      }
    }
  }

  private func durationValue(_ minutes: Int) -> String {
    minutes > 0 ? RoburData.duration(minutes) : "—"
  }

  private func metricValue(_ value: Int, unit: String) -> String {
    value > 0 ? "\(value) \(unit)" : "—"
  }
}

struct WatchScoreRow: View {
  let title: String
  let value: Int

  var body: some View {
    VStack(alignment: .leading, spacing: 4) {
      HStack {
        Text(title)
        Spacer()
        Text("\(value)")
          .font(.headline)
      }
      ProgressView(value: Double(value), total: 100)
        .tint(Color(red: 0.95, green: 0.53, blue: 0.22))
    }
  }
}
