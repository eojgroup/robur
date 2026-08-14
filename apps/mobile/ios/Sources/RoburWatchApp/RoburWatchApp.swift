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
  private let snapshot = RoburData.today

  var body: some View {
    NavigationStack {
      List {
        Section("Today") {
          WatchScoreRow(title: "Recovery", value: snapshot.recoveryScore)
          WatchScoreRow(title: "Load", value: snapshot.trainingLoad)
          Label(RoburData.duration(snapshot.sleepMinutes), systemImage: "moon.fill")
          Label("\(snapshot.restingHeartRateBpm) bpm", systemImage: "heart.fill")
          Label("\(snapshot.heartRateVariabilityMs) ms HRV", systemImage: "waveform.path.ecg")
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
      }
      .navigationTitle("Robur")
    }
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
        .tint(.green)
    }
  }
}
