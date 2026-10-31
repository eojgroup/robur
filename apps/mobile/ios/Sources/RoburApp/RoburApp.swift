import SwiftUI

@main
struct RoburApp: App {
  @UIApplicationDelegateAdaptor(RoburAppDelegate.self) private var appDelegate
  @StateObject private var journal = RoburServices.shared.journal
  @StateObject private var gymMonitor = RoburServices.shared.gymMonitor
  @StateObject private var healthKit = HealthKitClient()

  var body: some Scene {
    WindowGroup {
      RoburRootView()
        .environmentObject(healthKit)
        .environmentObject(journal)
        .environmentObject(gymMonitor)
    }
  }
}

struct RoburTodayView: View {
  @EnvironmentObject private var healthKit: HealthKitClient
  @EnvironmentObject private var journal: WorkoutJournal
  @State private var selected: WorkoutRecord?

  var body: some View {
    NavigationStack {
      ScrollView {
        VStack(alignment: .leading, spacing: 22) {
          header
          HealthOverviewView()
          WorkoutLaunchPanel()
          if let visit = journal.activeVisit {
            Label("Checked in at \(journal.gymName(visit.gymID) ?? "your gym")", systemImage: "mappin.and.ellipse")
              .font(.headline).foregroundStyle(RoburStyle.teal).roburCard()
          }
          if !healthKit.workouts.isEmpty {
            Text("RECENT SESSIONS").font(.caption.bold()).foregroundStyle(.secondary)
            ForEach(Array(healthKit.workouts.prefix(3))) { workout in
              Button { selected = workout } label: {
                WorkoutRow(workout: workout, annotation: journal.annotations[workout.id] ?? WorkoutAnnotation(),
                           gymName: journal.gymName(journal.annotations[workout.id]?.gymID))
              }.buttonStyle(.plain)
            }
          }
          if !healthKit.authorizationRequested { permissionPrompts }
          DisclosureGroup("Privacy & health estimates") {
            VStack(alignment: .leading, spacing: 8) {
              Text("Health calculations and saved places stay on this device. Workout tags and notes sync between your paired iPhone and Watch. Plans are shared with Calendar and Reminders only when you choose. Manage Health access in the Health app under your profile, Apps and Services, Robur.")
              Text("Recovery and training load are general fitness estimates, not medical advice. Scores use your personal baseline and available Health measurements. Effort prefers Apple Fitness records, with clearly labeled fallbacks. Adjust activity to how you feel.")
            }.padding(.top, 8)
          }.font(.footnote).foregroundStyle(.secondary)
        }
        .frame(maxWidth: RoburStyle.contentWidth)
        .padding()
        .frame(maxWidth: .infinity)
      }
      .refreshable { await healthKit.refreshTodaySnapshot() }
      .background(RoburStyle.background)
      .navigationTitle(RoburData.appName).navigationBarTitleDisplayMode(.inline)
      .toolbar {
        NavigationLink { HealthSettingsView() } label: { Image(systemName: "slider.horizontal.3") }
          .accessibilityLabel("Goals and notifications")
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
        if healthKit.lastUpdated == nil { await healthKit.refreshTodaySnapshot() }
      }
      .sheet(item: $selected) { WorkoutDetailView(workout: $0) }
      .onChange(of: healthKit.dailyMetrics) { _, days in
        let defaults = UserDefaults.standard
        let summary = TrainingInsights.make(days: days, workouts: healthKit.workouts,
          annotations: journal.annotations, maxHR: defaults.object(forKey: "RoburMaxHeartRate") as? Double ?? 190)
        Task { await HealthNotificationManager.shared.evaluate(summary: summary, days: days,
          stepsGoal: defaults.object(forKey: "RoburStepsGoal") as? Double ?? 8000) }
      }
    }
  }

  private var header: some View {
    HStack(alignment: .firstTextBaseline) {
      Text("Today").font(.largeTitle.bold())
      Spacer()
      Text(Date().formatted(.dateTime.weekday(.abbreviated).month(.abbreviated).day()))
        .font(.subheadline).foregroundStyle(.secondary)
    }
  }

  private var permissionPrompts: some View {
    VStack(spacing: 12) {
      PermissionCard(
        systemImage: "heart.text.square.fill",
        title: "Apple Health",
        message: healthKit.promptMessage,
        buttonTitle: healthKit.authorizationRequested ? "Access" : "Connect",
        tint: RoburStyle.teal
      ) {
        healthKit.requestAuthorization()
      }
    }
  }
}

struct ScoreTile: View {
  let title: String
  let value: Int?
  let tint: Color
  var body: some View {
    VStack(alignment: .leading, spacing: 14) {
      Text(title).font(.subheadline.bold())
      ZStack {
        Circle().stroke(tint.opacity(0.12), lineWidth: 9)
        Circle().trim(from: 0, to: Double(value ?? 0) / 100)
          .stroke(tint, style: StrokeStyle(lineWidth: 9, lineCap: .round)).rotationEffect(.degrees(-90))
        VStack(spacing: 0) {
          Text(value.map(String.init) ?? "—").font(.system(.title, design: .rounded, weight: .bold)).monospacedDigit()
          Text(value == nil ? "No data" : "of 100").font(.caption2).foregroundStyle(.secondary)
        }
      }.frame(width: 90, height: 90).padding(.vertical, 4).frame(maxWidth: .infinity)
    }.roburCard()
      .accessibilityElement(children: .ignore)
      .accessibilityLabel("\(title): \(value.map { "\($0) out of 100" } ?? "No data")")
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
    .background(RoburStyle.surface)
    .clipShape(RoundedRectangle(cornerRadius: 24))
  }
}
