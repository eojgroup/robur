import SwiftUI
import Charts

struct HealthOverviewView: View {
  @EnvironmentObject private var healthKit: HealthKitClient
  @EnvironmentObject private var journal: WorkoutJournal
  @AppStorage("RoburMaxHeartRate") private var maxHR = 190.0
  @AppStorage("RoburStepsGoal") private var stepsGoal = 8_000.0
  @AppStorage("RoburExerciseGoal") private var exerciseGoal = 30.0
  @State private var selectedDay: Date?
  @State private var zoneWindow = 7
  @State private var cachedSummary: InsightsSummary?

  private var summary: InsightsSummary {
    cachedSummary ?? TrainingInsights.make(days: [], workouts: [], annotations: [:], maxHR: maxHR)
  }
  private var latest: DailyHealthMetrics? { healthKit.dailyMetrics.filter { $0.date <= Date() }.max { $0.date < $1.date } }

  var body: some View {
    VStack(alignment: .leading, spacing: 20) {
      scoreCard
      activityCard
      loadCard
      heatmapCard
      trendCard
      zoneCard
      reportCard
      recordCard
      profileCard
      methodologyCard
    }
    .onChange(of: healthKit.dailyMetrics, initial: true) { _, _ in recalculate() }
    .onChange(of: healthKit.workouts) { _, _ in recalculate() }
    .onChange(of: journal.annotations) { _, _ in recalculate() }
    .onChange(of: maxHR) { _, _ in recalculate() }
    .onChange(of: stepsGoal) { _, _ in recalculate() }
    .onChange(of: exerciseGoal) { _, _ in recalculate() }
  }

  private func recalculate() {
    cachedSummary = TrainingInsights.make(days: healthKit.dailyMetrics, workouts: healthKit.workouts,
      annotations: journal.annotations, maxHR: maxHR, stepsGoal: stepsGoal, exerciseGoal: exerciseGoal)
  }

  private var scoreCard: some View {
    VStack(alignment: .leading, spacing: 18) {
      Label("Your daily outlook", systemImage: "sparkles").font(.headline)
      HStack(spacing: 22) {
        InsightRing(title: "Readiness", value: summary.readiness, tint: RoburStyle.teal)
        InsightRing(title: "Fitness", value: summary.fitness, tint: RoburStyle.blue)
      }
      Text("Personal estimates, recalculated from the Health data you share. Readiness compares recent recovery signals with your own prior 30 days.")
        .font(.caption).foregroundStyle(.secondary)
      if summary.readiness == nil || summary.fitness == nil {
        Text("More approved history may be needed to establish a baseline. Missing measurements are excluded.")
          .font(.caption).foregroundStyle(.secondary)
      }
    }.roburCard()
  }

  private var activityCard: some View {
    VStack(alignment: .leading, spacing: 16) {
      Label("Everyday movement", systemImage: "figure.walk").font(.headline)
      if let day = latest {
        Text(day.date.formatted(date: .abbreviated, time: .omitted)).font(.caption).foregroundStyle(.secondary)
        HStack(alignment: .top, spacing: 12) {
          MovementRing(title: "Steps", value: day.steps, target: stepsGoal, unit: "steps", tint: RoburStyle.teal)
          MovementRing(title: "Exercise", value: day.exerciseMinutes, target: exerciseGoal, unit: "min", tint: RoburStyle.amber)
          MovementRing(title: "Stand", value: day.standMinutes, target: nil, unit: "min", tint: RoburStyle.blue)
        }
        if let energy = day.activeEnergyKcal { LabeledContent("Active energy", value: "\(Int(energy.rounded())) kcal") }
        let recent = Array(healthKit.dailyMetrics.sorted { $0.date < $1.date }.suffix(30))
        Chart(recent) { item in
          if let steps = item.steps {
            BarMark(x: .value("Day", item.date, unit: .day), y: .value("Steps", steps))
              .foregroundStyle(RoburStyle.teal.gradient).cornerRadius(2)
          }
        }
        .chartYAxisLabel("steps").frame(height: 130)
        Text("Standing time is Apple Health stand minutes, which differs from the hourly stand-ring count.")
          .font(.caption).foregroundStyle(.secondary)
      } else {
        empty("Share steps, exercise and stand time in Apple Health to see daily movement.")
      }
    }.roburCard()
  }

  private var loadCard: some View {
    VStack(alignment: .leading, spacing: 16) {
      Label("Training load & recovery", systemImage: "bolt.heart").font(.headline)
      HStack(alignment: .firstTextBaseline) {
        metricNumber(summary.load7, title: "7-day load", unit: "AU")
        Spacer()
        metricNumber(summary.load28, title: "28-day load", unit: "AU")
      }
      Label(summary.loadStatus, systemImage: "gauge.with.dots.needle.50percent")
        .font(.headline).foregroundStyle(RoburStyle.teal)
      if let ratio = summary.loadRatio {
        Text("7-day average / 28-day average: \(ratio, specifier: "%.2f")×")
          .font(.caption).foregroundStyle(.secondary)
      }
      let beginning = Calendar.current.date(byAdding: .day, value: -27, to: Calendar.current.startOfDay(for: Date())) ?? Date()
      let recent = summary.dailyLoad.filter { $0.date >= beginning && $0.date <= Date() }
      if recent.contains(where: { $0.load > 0 }) {
        Chart(recent, id: \.date) { day in
          BarMark(x: .value("Day", day.date, unit: .day), y: .value("Session load", day.load))
            .foregroundStyle(RoburStyle.amber.gradient).cornerRadius(3)
          RuleMark(y: .value("28-day daily average", summary.load28 / 28))
            .foregroundStyle(RoburStyle.blue).lineStyle(StrokeStyle(lineWidth: 1, dash: [4, 4]))
        }.chartXScale(domain: beginning...Date()).chartYAxisLabel("AU").frame(height: 180)
      } else { empty("Workouts with Apple effort or usable heart-rate data establish your load history.") }
      Text("Load uses workout duration × Apple Fitness effort when available; heart-rate intensity is an estimate when effort is missing. A personal rating is the final fallback. Blue line: 28-day daily average. Load categories are planning heuristics, not an injury prediction.")
        .font(.caption).foregroundStyle(.secondary)
    }.roburCard()
  }

  private var heatmapDates: [Date] {
    let calendar = Calendar.current
    let week = calendar.dateInterval(of: .weekOfYear, for: Date())?.start ?? calendar.startOfDay(for: Date())
    let start = calendar.date(byAdding: .day, value: -84, to: week) ?? week
    return (0..<91).compactMap { calendar.date(byAdding: .day, value: $0, to: start) }.filter { $0 <= Date() }
  }

  private var heatmapCard: some View {
    VStack(alignment: .leading, spacing: 14) {
      Label("Show up, day after day", systemImage: "calendar").font(.headline)
      HStack {
        Label("\(summary.currentStreak)-day streak", systemImage: "flame.fill")
        Spacer()
        Text("\(summary.activeDays) active days").foregroundStyle(.secondary)
      }.font(.subheadline)
      LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 5), count: 7), spacing: 5) {
        ForEach(heatmapDates, id: \.self) { date in
          let day = healthKit.dailyMetrics.first { Calendar.current.isDate($0.date, inSameDayAs: date) }
          let progress = activityProgress(day)
          Button { selectedDay = date } label: {
            RoundedRectangle(cornerRadius: 4)
              .fill(progress.map { RoburStyle.teal.opacity(max(0.15, min(1, $0))) } ?? Color.secondary.opacity(0.08))
              .frame(height: 18)
              .overlay { if Calendar.current.isDateInToday(date) { RoundedRectangle(cornerRadius: 4).stroke(RoburStyle.blue, lineWidth: 2) } }
          }.buttonStyle(.plain)
            .accessibilityLabel("\(date.formatted(date: .abbreviated, time: .omitted)): \(progress.map { "\(Int($0 * 100)) percent of activity goal" } ?? "No activity data")")
        }
      }
      if let date = selectedDay {
        let day = healthKit.dailyMetrics.first { Calendar.current.isDate($0.date, inSameDayAs: date) }
        Text("\(date.formatted(date: .abbreviated, time: .omitted)): \(day?.steps.map { "\(Int($0)) steps" } ?? "steps unavailable") · \(day?.exerciseMinutes.map { "\(Int($0)) exercise min" } ?? "exercise unavailable")")
          .font(.caption)
      }
      Text("Last 13 weeks. Brighter squares mean more progress toward your step or exercise target; empty squares have no shared data. Tap a day for details.")
        .font(.caption).foregroundStyle(.secondary)
    }.roburCard()
  }

  private func activityProgress(_ day: DailyHealthMetrics?) -> Double? {
    guard let day else { return nil }
    let progress = [day.steps.map { $0 / max(stepsGoal, 1) }, day.exerciseMinutes.map { $0 / max(exerciseGoal, 1) }].compactMap { $0 }
    return progress.max()
  }

  private var trendCard: some View {
    VStack(alignment: .leading, spacing: 16) {
      Label("Your health, in perspective", systemImage: "chart.line.uptrend.xyaxis").font(.headline)
      if summary.trends.isEmpty { empty("Longer Health history unlocks 7-, 30- and 90-day comparisons.") }
      ForEach(Array(summary.trends.enumerated()), id: \.offset) { _, trend in
        VStack(alignment: .leading, spacing: 8) {
          HStack {
            Text(trend.title).font(.subheadline.bold())
            Spacer()
            if let change = trend.changePercent {
              Text(String(format: "%+.1f%%", change)).font(.subheadline.bold()).foregroundStyle(RoburStyle.blue)
            }
          }
          HStack(spacing: 18) {
            trendValue("7d", trend.mean7, unit: trend.unit)
            trendValue("30d", trend.mean30, unit: trend.unit)
            trendValue("90d", trend.mean90, unit: trend.unit)
          }
          Text(trend.direction).font(.caption).foregroundStyle(.secondary)
        }
        Divider()
      }
      Text("Percentage change compares the recent period with its available baseline. A sustained direction describes repeated measurements, not a diagnosis.")
        .font(.caption).foregroundStyle(.secondary)
    }.roburCard()
  }

  private var zoneTotals: [HeartZoneTotal] {
    let now = Date()
    let start = Calendar.current.date(byAdding: .day, value: -(zoneWindow - 1), to: Calendar.current.startOfDay(for: now)) ?? now
    var minutes = Array(repeating: 0.0, count: 5)
    for workout in healthKit.workouts where workout.start >= start && workout.start <= now {
      for zone in TrainingInsights.heartZones(samples: workout.heartRateSamples, end: min(workout.end, now), maxHR: maxHR) {
        minutes[zone.zone - 1] += zone.minutes
      }
    }
    return (1...5).map { HeartZoneTotal(zone: $0, minutes: minutes[$0 - 1]) }
  }

  private var zoneCard: some View {
    VStack(alignment: .leading, spacing: 16) {
      Label("Heart-rate balance", systemImage: "heart.text.square").font(.headline)
      Picker("Zone history", selection: $zoneWindow) {
        Text("7 days").tag(7)
        Text("30 days").tag(30)
      }.pickerStyle(.segmented)
      let totals = zoneTotals
      if totals.contains(where: { $0.minutes > 0 }) {
        Chart(totals, id: \.zone) { zone in
          BarMark(x: .value("Minutes", zone.minutes), y: .value("Zone", "Z\(zone.zone)"))
            .foregroundStyle(zoneColor(zone.zone)).cornerRadius(4)
            .annotation(position: .trailing) { Text("\(Int(zone.minutes))m").font(.caption) }
        }.frame(height: 170)
      } else { empty("Share workout heart-rate data in Health and refresh to see time in zones. Opening a workout loads additional detail when available.") }
      Text("Zones use your configured maximum heart rate (\(Int(maxHR)) bpm). Sample gaps are excluded; available sample coverage can be less than workout duration. Review maximum HR in Settings.")
        .font(.caption).foregroundStyle(.secondary)
    }.roburCard()
  }

  private var reportCard: some View {
    VStack(alignment: .leading, spacing: 14) {
      Label("Your weekly report", systemImage: "doc.text.image").font(.headline)
      if summary.weeklyReport.isEmpty { empty("Share activity from this week and last week to build a comparison.") }
      ForEach(Array(summary.weeklyReport.enumerated()), id: \.offset) { _, item in
        Label(item, systemImage: "arrow.up.right.circle").font(.subheadline)
      }
    }.roburCard()
  }

  private var recordCard: some View {
    VStack(alignment: .leading, spacing: 14) {
      Label("Personal records", systemImage: "trophy").font(.headline)
      if summary.records.isEmpty { empty("Your available workout and health history will reveal personal bests.") }
      ForEach(Array(summary.records.enumerated()), id: \.offset) { _, record in
        HStack(alignment: .top) {
          VStack(alignment: .leading, spacing: 4) {
            Text(record.title).font(.subheadline.bold())
            Text(record.date.formatted(date: .abbreviated, time: .omitted)).font(.caption).foregroundStyle(.secondary)
          }
          Spacer()
          Text(record.value).font(.headline).foregroundStyle(RoburStyle.amber)
        }
      }
      Text("Records cover the Health history loaded in Robur. Distance records describe complete comparable workouts, not unmeasured segments within longer sessions.")
        .font(.caption).foregroundStyle(.secondary)
    }.roburCard()
  }

  private var profileCard: some View {
    VStack(alignment: .leading, spacing: 14) {
      Label("Your Health profile", systemImage: "person.text.rectangle").font(.headline)
      let profile = healthKit.profile
      if let value = profile.weightKg { LabeledContent("Weight", value: String(format: "%.1f kg", value)) }
      if let value = profile.heightCm { LabeledContent("Height", value: String(format: "%.0f cm", value)) }
      if let value = profile.bmi { LabeledContent("Body mass index", value: String(format: "%.1f", value)) }
      if let value = profile.bodyFatPercent { LabeledContent("Body fat", value: String(format: "%.1f%%", value)) }
      if let value = profile.age { LabeledContent("Age", value: "\(value)") }
      if let value = profile.biologicalSex { LabeledContent("Biological sex", value: value) }
      if let value = profile.bloodType { LabeledContent("Blood type", value: value) }
      if profile == HealthProfile() { empty("Share body measurements and profile categories in Apple Health to view them here.") }
      let weights = healthKit.fitnessReadings.filter { $0.metric == .weight }
      if !weights.isEmpty {
        Chart(weights) { reading in
          LineMark(x: .value("Date", reading.date), y: .value("Weight", reading.value)).foregroundStyle(RoburStyle.blue)
        }.chartYScale(domain: .automatic(includesZero: false)).chartYAxisLabel("kg").frame(height: 130)
      }
      Text("Only approved HealthKit fields are shown. Apple does not expose Medical ID emergency contacts or its full card to apps. Manage your original records in Apple Health.")
        .font(.caption).foregroundStyle(.secondary)
    }.roburCard()
  }

  private var methodologyCard: some View {
    DisclosureGroup {
      VStack(alignment: .leading, spacing: 12) {
        Text("Readiness inputs").font(.subheadline.bold())
        ForEach(Array(summary.readinessComponents.enumerated()), id: \.offset) { _, score in
          VStack(alignment: .leading, spacing: 4) {
            HStack { Text(score.title).font(.subheadline); Spacer(); Text("\(score.value)/100").monospacedDigit() }
            ProgressView(value: Double(score.value), total: 100).tint(RoburStyle.blue)
            Text(score.explanation).font(.caption).foregroundStyle(.secondary)
          }
        }
        Text("Fitness components").font(.subheadline.bold())
        ForEach(Array(summary.scores.enumerated()), id: \.offset) { _, score in
          VStack(alignment: .leading, spacing: 4) {
            HStack { Text(score.title).font(.subheadline.bold()); Spacer(); Text("\(score.value)/100").monospacedDigit() }
            ProgressView(value: Double(score.value), total: 100).tint(RoburStyle.teal)
            Text(score.explanation).font(.caption).foregroundStyle(.secondary)
          }
        }
        Text("These are transparent training heuristics, not clinical assessments. Missing or denied data is never replaced with a fabricated measurement. A score can change when you share more categories or history.")
          .font(.caption).foregroundStyle(.secondary)
      }.padding(.top, 12)
    } label: { Label("How your scores are calculated", systemImage: "function").font(.headline) }
      .roburCard()
  }

  private func metricNumber(_ value: Double, title: String, unit: String) -> some View {
    VStack(alignment: .leading, spacing: 4) {
      Text(title).font(.caption).foregroundStyle(.secondary)
      Text("\(Int(value.rounded())) \(unit)").font(.title2.bold()).monospacedDigit()
    }
  }
  private func trendValue(_ label: String, _ value: Double?, unit: String) -> some View {
    VStack(alignment: .leading, spacing: 3) {
      Text(label).font(.caption2).foregroundStyle(.secondary)
      Text(value.map { String(format: "%.1f", $0) } ?? "—").font(.subheadline.bold()).monospacedDigit()
      Text(unit).font(.caption2).foregroundStyle(.secondary)
    }.frame(maxWidth: .infinity, alignment: .leading)
  }
  private func empty(_ message: String) -> some View { Text(message).font(.subheadline).foregroundStyle(.secondary) }
}

struct InsightRing: View {
  let title: String
  let value: Int?
  let tint: Color
  var body: some View {
    VStack(spacing: 10) {
      ZStack {
        Circle().stroke(tint.opacity(0.12), lineWidth: 10)
        Circle().trim(from: 0, to: Double(value ?? 0) / 100)
          .stroke(tint.gradient, style: StrokeStyle(lineWidth: 10, lineCap: .round)).rotationEffect(.degrees(-90))
        Text(value.map(String.init) ?? "—").font(.system(.largeTitle, design: .rounded, weight: .bold)).monospacedDigit()
      }.frame(width: 106, height: 106)
      Text(title).font(.subheadline.bold())
    }.frame(maxWidth: .infinity).accessibilityElement(children: .ignore)
      .accessibilityLabel("\(title): \(value.map { "\($0) out of 100" } ?? "More data needed")")
  }
}

private struct MovementRing: View {
  let title: String
  let value: Double?
  let target: Double?
  let unit: String
  let tint: Color
  var body: some View {
    VStack(spacing: 8) {
      if let target {
        ZStack {
          Circle().stroke(tint.opacity(0.12), lineWidth: 6)
          Circle().trim(from: 0, to: min(1, max(0, (value ?? 0) / max(target, 1))))
            .stroke(tint, style: StrokeStyle(lineWidth: 6, lineCap: .round)).rotationEffect(.degrees(-90))
          Image(systemName: title == "Steps" ? "figure.walk" : "figure.run").foregroundStyle(tint)
        }.frame(width: 54, height: 54)
      } else {
        Image(systemName: "figure.stand").foregroundStyle(tint).font(.title).frame(height: 54)
      }
      Text(value.map { Int($0.rounded()).formatted() } ?? "—").font(.headline).monospacedDigit()
      Text("\(title) · \(unit)").font(.caption2).foregroundStyle(.secondary)
    }.frame(maxWidth: .infinity)
  }
}

func zoneColor(_ zone: Int) -> Color {
  switch zone {
  case 1: return .gray
  case 2: return RoburStyle.blue
  case 3: return RoburStyle.teal
  case 4: return RoburStyle.amber
  default: return .red
  }
}
