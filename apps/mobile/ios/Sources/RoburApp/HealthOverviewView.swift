import SwiftUI
import Charts

private enum HealthInsightPanel: String, CaseIterable, Identifiable {
  case load = "Training load", recovery = "Sleep & autonomic", activity = "Movement", balance = "Training mix"
  case heatmap = "Activity calendar", zones = "Heart-rate zones", trends = "Health trends"
  case report = "Weekly report", records = "Personal records", profile = "Health profile", scores = "Score details"
  var id: String { rawValue }
}

struct HealthOverviewView: View {
  var compactOnly = false
  @State private var panel: HealthInsightPanel = .scores
  @Environment(\.horizontalSizeClass) private var widthClass
  @Environment(\.dynamicTypeSize) private var typeSize
  @EnvironmentObject private var healthKit: HealthKitClient
  @EnvironmentObject private var journal: WorkoutJournal
  @AppStorage("RoburMaxHeartRate") private var maxHR = 190.0
  @AppStorage("RoburStepsGoal") private var stepsGoal = 8_000.0
  @AppStorage("RoburExerciseGoal") private var exerciseGoal = 30.0
  @State private var selectedDay: Date?
  @State private var zoneWindow = 7
  @State private var loadActivity: WorkoutActivity?
  @State private var balanceDays = 28
  @AppStorage("RoburTrainingBalanceCategories") private var balanceCategories = "endurance,strength,mobility"
  @AppStorage("RoburTrainingBalanceActivities") private var balanceActivities = ""
  @State private var editingTargets = false
  @State private var draftCategories: Set<TrainingCategory> = []
  @State private var draftActivities: Set<WorkoutActivity> = []
  @State private var cachedSummary: InsightsSummary?

  private var summary: InsightsSummary {
    cachedSummary ?? TrainingInsights.make(days: [], workouts: [], annotations: [:], maxHR: maxHR)
  }
  private var latest: DailyHealthMetrics? { healthKit.dailyMetrics.filter { $0.date <= Date() }.max { $0.date < $1.date } }
  private var latestSleep: DailyHealthMetrics? {
    healthKit.dailyMetrics.filter { $0.date <= Date() && ($0.sleepMinutes ?? 0) > 0 }.max { $0.date < $1.date }
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 16) {
      summaryStrip
      if compactOnly {
        NavigationLink {
          ScrollView {
            HealthOverviewView().frame(maxWidth: RoburStyle.contentWidth).padding().frame(maxWidth: .infinity)
          }.background(RoburStyle.background).navigationTitle("Health insights")
        } label: {
          HStack {
            Label("Explore health insights", systemImage: "chart.bar.doc.horizontal")
            Spacer()
            Image(systemName: "chevron.right").font(.caption.bold())
          }.font(.subheadline.weight(.semibold)).padding(.vertical, 8)
        }.buttonStyle(.plain)
      } else {
        Picker("Insight", selection: $panel) {
          ForEach(HealthInsightPanel.allCases) { item in Text(item.rawValue).tag(item) }
        }.pickerStyle(.menu).accessibilityIdentifier("health-insight-selector")
        selectedPanel
      }
    }
    .onChange(of: healthKit.dailyMetrics, initial: true) { _, _ in recalculate() }
    .onChange(of: healthKit.analyticsWorkouts) { _, _ in recalculate() }
    .onChange(of: journal.annotations) { _, _ in recalculate() }
    .onChange(of: maxHR) { _, _ in recalculate() }
    .onChange(of: stepsGoal) { _, _ in recalculate() }
    .onChange(of: exerciseGoal) { _, _ in recalculate() }
    .sheet(isPresented: $editingTargets) { balanceTargetEditor }
  }

  private var summaryStrip: some View {
    LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 10), count: typeSize.isAccessibilitySize ? 1 : (widthClass == .regular ? 4 : 2)), spacing: 10) {
      compactMetric("Recovery", value: summary.readiness.map(String.init) ?? "—", detail: summary.recoveryAnalysis.confidence, symbol: "sun.max", tint: RoburStyle.teal, score: summary.readiness)
      compactMetric("Fitness", value: summary.fitness.map(String.init) ?? "—", detail: "Personal progress index", symbol: "heart.circle", tint: RoburStyle.blue, score: summary.fitness)
      compactMetric("Load", value: loadComparison.changePercent.map { String(format: "%+.0f%%", $0) } ?? "—", detail: loadComparison.classification, symbol: "chart.xyaxis.line", tint: RoburStyle.orange)
      compactMetric("Sleep", value: latestSleep?.sleepMinutes.map { String(format: "%.1fh", $0 / 60) } ?? "—", detail: latestSleep.map { $0.date.formatted(date: .abbreviated, time: .omitted) } ?? "No reading", symbol: "bed.double", tint: RoburStyle.blue)
    }
  }

  @ViewBuilder private var selectedPanel: some View {
    switch panel {
    case .load: loadCard
    case .recovery: recoveryCard
    case .activity: activityCard
    case .balance: balanceCard
    case .heatmap: heatmapCard
    case .zones: zoneCard
    case .trends: trendCard
    case .report: reportCard
    case .records: recordCard
    case .profile: profileCard
    case .scores: methodologyCard
    }
  }

  private func compactMetric(_ title: String, value: String, detail: String, symbol: String,
                             tint: Color, score: Int? = nil) -> some View {
    VStack(alignment: .leading, spacing: 5) {
      HStack(alignment: .firstTextBaseline, spacing: 6) {
        Label(title, systemImage: symbol).font(.caption.weight(.semibold)).foregroundStyle(tint)
        Spacer(minLength: 0)
      }
      HStack(alignment: .firstTextBaseline) {
        Text(value).font(.system(.title2, design: .rounded, weight: .bold)).monospacedDigit().minimumScaleFactor(0.7).lineLimit(1)
        Spacer(minLength: 2)
        if let score {
          ProgressView(value: Double(score), total: 100).tint(tint).frame(maxWidth: 45)
        }
      }
      Text(detail).font(.caption2).foregroundStyle(.secondary).lineLimit(2)
    }.frame(maxWidth: .infinity, minHeight: 66, alignment: .topLeading).padding(12)
      .background(RoburStyle.surface, in: RoundedRectangle(cornerRadius: 16))
      .accessibilityElement(children: .combine)
  }

  private var recoveryCard: some View {
    let start = Calendar.current.date(byAdding: .day, value: -29, to: Date()) ?? Date()
    let timeline = TrainingTimeline.make(workouts: [], days: healthKit.dailyMetrics, signal: .sleep, grain: .day, start: start)
    return VStack(alignment: .leading, spacing: 16) {
      Label("Recovery · sleep", systemImage: "bed.double").font(.headline)
      if timeline.buckets.contains(where: { $0.recoveryValue != nil }) {
        Chart(timeline.buckets) { point in
          if let minutes = point.recoveryValue {
            BarMark(x: .value("Date", point.date, unit: .day), y: .value("Sleep", minutes / 60))
              .foregroundStyle(RoburStyle.blue.gradient).cornerRadius(3)
              .accessibilityLabel(point.date.formatted(date: .abbreviated, time: .omitted))
              .accessibilityValue(String(format: "%.1f hours asleep", minutes / 60))
          }
        }.chartYAxisLabel("hours").frame(height: 190)
        HStack {
          ForEach(Array(summary.trends.filter { ["HRV", "Resting HR"].contains($0.title) })) { trend in
            VStack(alignment: .leading, spacing: 4) {
              Text(trend.title).font(.caption).foregroundStyle(.secondary)
              Text("\(Int(trend.current.rounded())) \(trend.unit)").font(.headline)
              Text(trend.changePercent.map { String(format: "%+.0f%% vs baseline", $0) } ?? "Building baseline")
                .font(.caption2).foregroundStyle(.secondary)
            }.frame(maxWidth: .infinity, alignment: .leading)
          }
        }
      } else { empty("Share sleep in Apple Health to see recovery history.") }
      Text("30 days · recorded sleep only").font(.caption).foregroundStyle(.secondary)
    }.roburCard()
  }

  private func recalculate() {
    cachedSummary = TrainingInsights.make(days: healthKit.dailyMetrics, workouts: healthKit.analyticsWorkouts,
      annotations: journal.annotations, maxHR: maxHR, stepsGoal: stepsGoal, exerciseGoal: exerciseGoal,
      historyStart: healthKit.analyticsHistoryStart, fitnessReference: healthKit.fitnessReference)
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
      } else {
        empty("Share steps, exercise and stand time in Apple Health to see daily movement.")
      }
    }.roburCard()
  }

  private var loadComparison: TrainingLoadSummary {
    TrainingLoadComparison.make(workouts: healthKit.analyticsWorkouts, historyStart: healthKit.analyticsHistoryStart,
      activity: loadActivity)
  }

  private var loadCard: some View {
    let load = loadComparison
    let graph = loadGraphSamples(load.points)
    return VStack(alignment: .leading, spacing: 16) {
      Label("Training load", systemImage: "chart.xyaxis.line").font(.headline)
      Picker("Workout type", selection: $loadActivity) {
        Text("All workouts").tag(WorkoutActivity?.none)
        ForEach(WorkoutActivity.allCases) { activity in Text(activity.title).tag(Optional(activity)) }
      }.pickerStyle(.menu)
      HStack(alignment: .firstTextBaseline) {
        Text(load.changePercent.map { String(format: "%+.0f%%", $0) } ?? "—")
          .font(.system(.largeTitle, design: .rounded, weight: .bold)).foregroundStyle(RoburStyle.orange)
        Text(load.classification).font(.headline)
      }
      Text("7 days vs 28-day baseline").font(.subheadline).foregroundStyle(.secondary)
      if load.points.contains(where: { $0.changePercent != nil }) {
        Chart {
          ForEach(load.points, id: \.date) { point in
            AreaMark(x: .value("Date", point.date), yStart: .value("Near baseline", -10), yEnd: .value("Near baseline", 10))
              .foregroundStyle(RoburStyle.blue.opacity(0.07))
          }
          ForEach(graph) { sample in
            LineMark(x: .value("Date", sample.date), y: .value("Change from baseline", sample.change))
              .foregroundStyle(by: .value("Coverage segment", String(sample.segment)))
              .lineStyle(StrokeStyle(lineWidth: 3))
          }
          RuleMark(y: .value("Baseline", 0)).foregroundStyle(RoburStyle.blue.opacity(0.6))
            .lineStyle(StrokeStyle(lineWidth: 1, dash: [4, 4]))
        }.chartForegroundStyleScale(range: [RoburStyle.orange]).chartLegend(.hidden)
          .chartYAxisLabel("%").frame(height: 190)
      } else {
        empty("Share Apple effort history to establish a comparison. Earlier history and usable ratings are needed for a 28-day baseline.")
      }
      HStack {
        averageLoad(load.recent7Mean, title: "7-day average")
        Spacer()
        averageLoad(load.baseline28Mean, title: "28-day baseline")
      }
      HStack {
        Text("\(load.ratedSessions)/\(load.totalSessions) sessions with Apple effort")
      }.font(.caption).foregroundStyle(.secondary)
      if let error = healthKit.effortImportError {
        Text(error).font(.caption).foregroundStyle(.secondary)
        Button("Review Health access") { healthKit.requestAuthorization() }
      }
      if load.totalSessions > 0 && load.ratedSessions == 0 && healthKit.effortImportError == nil {
        Button("Review Health access") { healthKit.requestAuthorization() }
      }
      DisclosureGroup("What this comparison includes") {
        VStack(alignment: .leading, spacing: 8) {
          Text("\(load.reportedSessions) reported · \(load.estimatedSessions) estimated sessions")
          if let status = healthKit.effortImportStatus { Text(status) }
          Text("Uses duration × imported Apple effort. Reported Fitness ratings take priority over Apple estimates. Unrated sessions and Robur heart-rate/manual fallbacks are excluded from this comparison.")
          Text("The shaded band is ±10% of baseline. This is Robur’s transparent 7/28-day comparison; it does not reproduce Apple’s proprietary training-load algorithm or predict injury.")
          Text("Separate Robur session load: \(Int(summary.load7)) AU over 7 days, \(Int(summary.load28)) AU over 28 days. That total can include heart-rate estimates and personal ratings.")
        }.font(.caption).foregroundStyle(.secondary).padding(.top, 6)
      }.font(.caption)
    }.roburCard()
  }

  private struct LoadGraphSample: Identifiable {
    var id: Date { date }
    let date: Date
    let change: Double
    let segment: Int
  }

  private func loadGraphSamples(_ points: [TrainingLoadPoint]) -> [LoadGraphSample] {
    var segment = 0
    return points.compactMap { point in
      guard let change = point.changePercent else { segment += 1; return nil }
      return LoadGraphSample(date: point.date, change: change, segment: segment)
    }
  }

  private func averageLoad(_ value: Double?, title: String) -> some View {
    VStack(alignment: .leading, spacing: 4) {
      Text(title).font(.caption).foregroundStyle(.secondary)
      Text(value.map { String(format: "%.0f AU/day", $0) } ?? "More history needed").font(.subheadline.bold())
    }
  }

  private var selectedCategories: Set<TrainingCategory> {
    Set(balanceCategories.split(separator: ",").compactMap { TrainingCategory(rawValue: String($0)) })
  }
  private var selectedActivities: Set<WorkoutActivity> {
    Set(balanceActivities.split(separator: ",").compactMap { WorkoutActivity(rawValue: String($0)) })
  }

  private var balanceCard: some View {
    let balance = TrainingBalance.make(workouts: healthKit.analyticsWorkouts, days: balanceDays,
      expected: selectedCategories, expectedActivities: selectedActivities)
    return VStack(alignment: .leading, spacing: 16) {
      Label("Your training mix", systemImage: "chart.pie").font(.headline)
      Picker("Training mix period", selection: $balanceDays) {
        Text("7 days").tag(7)
        Text("28 days").tag(28)
        Text("90 days").tag(90)
      }.pickerStyle(.segmented)
      if balance.sessions > 0 {
        HStack {
          Text("\(balance.sessions) sessions").font(.title2.bold())
          Spacer()
          Text("\(Int(balance.totalMinutes)) min").foregroundStyle(.secondary)
        }
        Chart(balance.categories, id: \.category) { item in
          SectorMark(angle: .value("Minutes", item.minutes), innerRadius: .ratio(0.64), angularInset: 2)
            .foregroundStyle(balanceColor(item.category)).cornerRadius(4)
        }.frame(height: 150)
        ForEach(balance.categories, id: \.category) { item in
          HStack {
            Circle().fill(balanceColor(item.category)).frame(width: 9, height: 9)
            Text(item.category.title)
            Spacer()
            Text("\(item.sessions) · \(Int(item.minutes)) min").monospacedDigit()
          }.font(.caption)
        }
        Divider()
        let missing = balance.missing.map(\.title) + balance.missingActivities.map(\.title)
        if !missing.isEmpty {
          Label("Not recorded: " + missing.joined(separator: ", "), systemImage: "circle.dashed")
            .font(.subheadline).foregroundStyle(RoburStyle.orange)
        }
      } else { empty("Import workouts to see your activity mix and compare it with your own targets.") }
      Button("Choose balance targets") {
        draftCategories = selectedCategories
        draftActivities = selectedActivities
        editingTargets = true
      }
      DisclosureGroup("Training mix details") {
        ForEach(balance.breakdown, id: \.activity) { item in
          LabeledContent { Text("\(item.sessions) · \(Int(item.minutes)) min") }
            label: { Label(item.activity.title, systemImage: item.activity.symbol) }
            .font(.caption)
        }
        Text("Recorded workout types compared with your chosen targets. Missing or unshared sessions can leave gaps; no particular sport is required.")
          .font(.caption).foregroundStyle(.secondary)
      }.font(.caption)
    }.roburCard()
  }

  private func balanceColor(_ category: TrainingCategory) -> Color {
    switch category {
    case .endurance: return RoburStyle.orange
    case .strength: return RoburStyle.blue
    case .mobility: return RoburStyle.amber.opacity(0.55)
    case .sport: return RoburStyle.blue.opacity(0.5)
    case .other: return .gray
    }
  }

  private var balanceTargetEditor: some View {
    NavigationStack {
      Form {
        Section("Categories you want to include") {
          ForEach(TrainingCategory.allCases) { category in
            Toggle(category.title, isOn: Binding(get: { draftCategories.contains(category) }, set: { value in
              if value { draftCategories.insert(category) } else { draftCategories.remove(category) }
            }))
          }
        }
        Section("Optional specific activities") {
          ForEach(WorkoutActivity.allCases) { activity in
            Toggle(activity.title, isOn: Binding(get: { draftActivities.contains(activity) }, set: { value in
              if value { draftActivities.insert(activity) } else { draftActivities.remove(activity) }
            }))
          }
        }
        Text("Save to confirm your own balance targets. No target changes automatically and no particular sport is required.")
          .font(.caption).foregroundStyle(.secondary)
      }
      .scrollContentBackground(.hidden).background(RoburStyle.background)
      .navigationTitle("Training balance")
      .toolbar {
        ToolbarItem(placement: .cancellationAction) { Button("Cancel") { editingTargets = false } }
        ToolbarItem(placement: .confirmationAction) {
          Button("Save targets") {
            balanceCategories = draftCategories.map(\.rawValue).sorted().joined(separator: ",")
            balanceActivities = draftActivities.map(\.rawValue).sorted().joined(separator: ",")
            editingTargets = false
          }
        }
      }
    }
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
    for workout in healthKit.analyticsWorkouts where workout.start >= start && workout.start <= now {
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
    let analysis = summary.recoveryAnalysis
    return VStack(alignment: .leading, spacing: 16) {
      Label("What builds your scores", systemImage: "function").font(.headline)
      HStack {
        VStack(alignment: .leading, spacing: 3) {
          Text("Recovery & readiness").font(.caption).foregroundStyle(.secondary)
          Text(analysis.score.map { "\($0)/100" } ?? "More data needed").font(.title2.bold())
        }
        Spacer()
        Text("\(Int((analysis.coverage * 100).rounded()))% input coverage\n\(analysis.baselineDays) baseline days")
          .font(.caption).foregroundStyle(.secondary).multilineTextAlignment(.trailing)
      }
      Text("One overall recovery score combines current autonomic signals, sleep and recent training demand. At least two independent direct signals need a personal baseline; sleep alone cannot produce it.")
        .font(.caption).foregroundStyle(.secondary)
      componentBreakdown(analysis.recoveryComponents)
      if let debt = analysis.sleepDebtMinutes {
        LabeledContent("Observed recent sleep shortfall", value: String(format: "%.0f min/night", debt)).font(.caption)
      }
      Divider()
      Text("Fitness · \(analysis.fitnessScore.map { "\($0)/100" } ?? "building history")").font(.headline)
      componentBreakdown(analysis.fitnessComponents)
      Text("Fitness reflects sustained cardio change, activity, consistency and strength participation. Today's sleep or autonomic readings do not directly change fitness. It is a personal progress index, not measured VO₂ max, strength or an age-adjusted percentile.")
        .font(.caption).foregroundStyle(.secondary)
      DisclosureGroup("Method, limits & references") {
        VStack(alignment: .leading, spacing: 10) {
          Text("\(analysis.methodologyVersion). All historical points use this same method and only observations dated by that point. Additional Health history, edited ratings and changed activity goals can revise recalculated scores.")
          Text("Recorded Apple effort × duration follows the session-RPE approach, but Apple estimates and heart-rate fallbacks are different sources and cannot be treated as validated RPE. 7/42-day load smoothing describes recent and longer-term observed demand. It does not predict injury or establish a universal safe training zone.")
          Text("Apple HRV uses SDNN; research using RMSSD cannot be transferred directly to these values. Timing, illness, mental stress, alcohol, travel and missing measurements can all affect the inputs. The 0–100 formula and weights are Robur's transparent heuristic, not an industry-certified readiness algorithm.")
          Link("Session-RPE research · Foster et al.", destination: URL(string: "https://pubmed.ncbi.nlm.nih.gov/11708692/")!)
          Link("Training impulse-response model · Morton et al.", destination: URL(string: "https://pubmed.ncbi.nlm.nih.gov/2246166/")!)
          Link("Apple HealthKit HRV SDNN", destination: URL(string: "https://developer.apple.com/documentation/healthkit/hkquantitytypeidentifier/heartratevariabilitysdnn")!)
        }.font(.caption).foregroundStyle(.secondary).padding(.top, 6)
      }.font(.caption)
    }.roburCard()
  }

  @ViewBuilder private func componentBreakdown(_ components: [RecoveryScoreComponent]) -> some View {
    if components.isEmpty { Text("More readings and baseline history are needed.").font(.caption).foregroundStyle(.secondary) }
    ForEach(components) { item in
      VStack(alignment: .leading, spacing: 6) {
        HStack {
          Text(item.title).font(.subheadline.weight(.semibold))
          Spacer()
          Text(String(format: "%.1f points", item.contribution)).font(.subheadline.bold()).monospacedDigit()
        }
        HStack {
          Text("\(item.score)/100 × \(Int((item.effectiveWeight * 100).rounded()))% effective weight")
          Spacer()
          Text(String(format: "%.1f %@", item.current, item.unit))
        }.font(.caption).foregroundStyle(.secondary)
        ProgressView(value: Double(item.score), total: 100).tint(RoburStyle.orange)
        DisclosureGroup("Input & baseline") { Text(item.explanation).font(.caption).foregroundStyle(.secondary) }.font(.caption)
      }
    }
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
