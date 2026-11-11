import SwiftUI
import Charts

private enum ExplorerMode: String, CaseIterable, Identifiable {
  case overlay = "Overlays", components = "Components", relationship = "Relationships"
  var id: String { rawValue }
}
private struct ExplorerPoint: Identifiable {
  var id: String { "\(metric.rawValue)-\(date.timeIntervalSince1970)" }
  let metric: AnalyticsMetric
  let date: Date
  let value: Double
  let segment: Int
}
private struct ExplorerContribution: Identifiable {
  var id: String { title }
  let title: String
  let value: Double
}
private struct ExplorerScore: Identifiable {
  var id: Date { date }
  let date: Date
  let score: Double
  let parts: [ExplorerContribution]
}

struct AnalyticsExplorerView: View {
  @EnvironmentObject private var healthKit: HealthKitClient
  @EnvironmentObject private var journal: WorkoutJournal
  @AppStorage("RoburMaxHeartRate") private var maxHR = 190.0
  @AppStorage("RoburStepsGoal") private var stepsGoal = 8_000.0
  @AppStorage("RoburExerciseGoal") private var exerciseGoal = 30.0
  @State private var mode: ExplorerMode = .overlay
  @State private var chosen: [AnalyticsMetric] = [.recovery, .acuteLoad, .hrv, .sleep]
  @State private var scale: AnalyticsScale = .percent
  @State private var analysis: RecoveryAnalysis?
  @State private var analysisTask: Task<Void, Never>?
  @State private var readings: [AnalyticsMetric: [AnalyticsReading]] = [:]
  @State private var highlights: [AnalyticsHighlight] = []
  @State private var selected: Date?
  @State private var showHighlights = true
  @State private var fitness = false
  @State private var metricA: AnalyticsMetric = .acuteLoad
  @State private var metricB: AnalyticsMetric = .recovery
  @State private var lag = 1
  private let calendar = Calendar.current
  private var lowerBound: Date { healthKit.historyRange.startDate() ?? readings.values.compactMap { $0.first?.date }.min() ?? Date() }
  private var inspectionDate: Date { calendar.startOfDay(for: selected ?? Date()) }
  private var rawAllowed: Bool { Set(chosen.map(\.unit)).count <= 1 }
  private var effectiveScale: AnalyticsScale { scale == .raw && !rawAllowed ? .percent : scale }
  private var grain: Calendar.Component? {
    let count = calendar.dateComponents([.day], from: lowerBound, to: Date()).day ?? 0
    return count > 1800 ? .month : count > 400 ? .weekOfYear : nil
  }
  private var plotted: [ExplorerPoint] {
    var result: [ExplorerPoint] = []
    for metric in chosen {
      let values = MetricAnalytics.compare(readings[metric] ?? [], scale: effectiveScale).filter { $0.date >= lowerBound }
      var grouped: [AnalyticsReading] = []
      if let grain {
        let buckets = Dictionary(grouping: values) { calendar.dateInterval(of: grain, for: $0.date)?.start ?? $0.date }
        for date in buckets.keys.sorted() {
          let bucket = buckets[date]!
          grouped.append(.init(date: date, value: bucket.reduce(0) { $0 + $1.value } / Double(bucket.count)))
        }
      } else { grouped = values.map { .init(date: $0.date, value: $0.value) } }
      var segment = 0, previous: Date?
      let maxGap = grain == .month ? 40 : grain == .weekOfYear ? 9 : 2
      for point in grouped {
        if let previous, (calendar.dateComponents([.day], from: previous, to: point.date).day ?? 0) > maxGap { segment += 1 }
        result.append(.init(metric: metric, date: point.date, value: point.value, segment: segment))
        previous = point.date
      }
    }
    return result
  }
  private var scorePoints: [RecoveryHistoryPoint] { (analysis?.history ?? []).filter { $0.date >= lowerBound && (fitness ? $0.fitness : $0.recovery) != nil } }
  private var plottedScores: [ExplorerScore] {
    let buckets = Dictionary(grouping: scorePoints) { point in grain.flatMap { calendar.dateInterval(of: $0, for: point.date)?.start } ?? point.date }
    return buckets.keys.sorted().map { date in
      let bucket = buckets[date]!, count = Double(bucket.count)
      var values: [String: Double] = [:]
      var total = 0.0
      for point in bucket {
        total += Double((fitness ? point.fitness : point.recovery) ?? 0)
        for part in fitness ? point.fitnessComponents : point.recoveryComponents { values[part.title, default: 0] += part.contribution }
      }
      let parts = values.keys.sorted().map { ExplorerContribution(title: $0, value: values[$0]! / count) }
      return ExplorerScore(date: date, score: total / count, parts: parts)
    }
  }
  private var pairs: [AnalyticsPair] {
    MetricAnalytics.paired(readings[metricA] ?? [], readings[metricB] ?? [], lagDays: lag).filter { $0.date >= lowerBound }
  }
  private var visibleHighlights: [AnalyticsHighlight] { highlights.filter { $0.end >= lowerBound } }

  var body: some View {
    NavigationStack {
      ScrollView {
        VStack(alignment: .leading, spacing: 16) {
          VStack(alignment: .leading, spacing: 14) {
            HistoryRangePicker()
            Picker("Analysis", selection: $mode) { ForEach(ExplorerMode.allCases) { Text($0.rawValue).tag($0) } }.pickerStyle(.segmented)
            switch mode {
            case .overlay: overlay
            case .components: componentsChart
            case .relationship: relationship
            }
            if mode != .relationship { Toggle("Highlight notable periods", isOn: $showHighlights).font(.subheadline) }
          }.roburCard()
          inspector
          if !visibleHighlights.isEmpty { highlightsList }
          HealthOverviewView(compactOnly: true)
          NavigationLink { FitnessHistoryView(embedded: true) } label: { Label("Training timeline & individual charts", systemImage: "chart.xyaxis.line") }
          if !healthKit.authorizationRequested { HistoryPermissionView() }
        }.frame(maxWidth: RoburStyle.contentWidth).padding().frame(maxWidth: .infinity)
      }.background(RoburStyle.background)
        .navigationTitle("Overview").navigationBarTitleDisplayMode(.inline)
        .toolbar {
          NavigationLink { HealthSettingsView() } label: { Image(systemName: "slider.horizontal.3") }.accessibilityLabel("Goals, appearance and notifications")
          Button { healthKit.requestAuthorization() } label: { Image(systemName: "heart.text.square") }.accessibilityLabel("Manage Health access")
        }
        .task { if healthKit.authorizationRequested { await healthKit.refreshTodaySnapshot() }; recalculate() }
        .refreshable { await healthKit.refreshTodaySnapshot(); await healthKit.loadHistory(range: healthKit.historyRange) }
        .onChange(of: healthKit.dailyMetrics) { _, _ in recalculate() }
        .onChange(of: healthKit.analyticsWorkouts) { _, _ in recalculate() }
        .onChange(of: healthKit.fitnessReference) { _, _ in recalculate() }
        .onChange(of: journal.annotations) { _, _ in recalculate() }
        .onChange(of: maxHR) { _, _ in recalculate() }
        .onChange(of: stepsGoal) { _, _ in recalculate() }
        .onChange(of: exerciseGoal) { _, _ in recalculate() }
        .onChange(of: healthKit.historyRange) { _, _ in selected = nil; recalculate() }
        .onDisappear { analysisTask?.cancel() }
    }
  }
  private var overlay: some View {
    let chartPoints = plotted
    return VStack(alignment: .leading, spacing: 12) {
      HStack {
        Menu {
          ForEach(AnalyticsMetric.allCases) { metric in
            Toggle(metric.title, isOn: Binding(get: { chosen.contains(metric) }, set: { enabled in
              if enabled && chosen.count < 6 { chosen.append(metric) } else if !enabled { chosen.removeAll { $0 == metric } }
            })).disabled(!chosen.contains(metric) && chosen.count >= 6)
          }
        } label: { Label("Metrics · \(chosen.count)/6", systemImage: "slider.horizontal.3") }
        Spacer()
        Picker("Scale", selection: $scale) {
          Text("% baseline").tag(AnalyticsScale.percent)
          Text("Std deviations").tag(AnalyticsScale.zScore)
          if rawAllowed { Text("Raw units").tag(AnalyticsScale.raw) }
        }.labelsHidden().onChange(of: chosen) { _, _ in if !rawAllowed && scale == .raw { scale = .percent } }
      }
      if chartPoints.isEmpty { ContentUnavailableView("Choose metrics with recorded history", systemImage: "chart.xyaxis.line", description: Text("Baseline views need at least 7 prior recorded dates. Raw units can show a single measure immediately.")) }
      else {
        Chart {
          if showHighlights { bands }
          ForEach(chartPoints) { point in
            LineMark(x: .value("Date", point.date), y: .value("Value", point.value), series: .value("Segment", "\(point.metric.rawValue)-\(point.segment)"))
              .foregroundStyle(by: .value("Metric", point.metric.title))
            if chartPoints.count < 500 {
              PointMark(x: .value("Date", point.date), y: .value("Value", point.value))
                .foregroundStyle(by: .value("Metric", point.metric.title)).symbolSize(12)
            }
          }
          if let selected { RuleMark(x: .value("Selected", selected)).foregroundStyle(.secondary) }
        }.chartForegroundStyleScale(domain: chosen.map(\.title), range: chosen.map { MetricColors.color($0.rawValue) })
          .chartYScale(domain: overlayDomain(chartPoints)).chartYAxisLabel(effectiveScale == .raw ? chosen.first?.unit ?? "" : effectiveScale == .percent ? "% from baseline" : "standard deviations")
          .chartXSelection(value: $selected).frame(height: 310)
      }
      Text(effectiveScale == .raw ? "Raw readings share the same unit. Missing observations remain missing." : "Each metric uses its own preceding 30-day baseline, excluding today, with at least 7 recorded dates. Missing readings are excluded.")
        .font(.caption).foregroundStyle(.secondary)
      if let grain { Text(grain == .month ? "Monthly means for long history; inspect raw daily readings below." : "Weekly means for long history; inspect raw daily readings below.").font(.caption).foregroundStyle(.secondary) }
    }
  }
  private func overlayDomain(_ points: [ExplorerPoint]) -> ClosedRange<Double> {
    let low = min(0, points.map(\.value).min() ?? 0), high = max(1, points.map(\.value).max() ?? 1)
    let margin = (high - low) * 0.08
    return (low - margin)...(high + margin)
  }
  @ChartContentBuilder private var bands: some ChartContent {
    ForEach(visibleHighlights) { event in
      RectangleMark(xStart: .value("Start", event.start), xEnd: .value("End", calendar.date(byAdding: .day, value: 1, to: event.end) ?? event.end))
        .foregroundStyle(event.kind == .effort ? Color.orange.opacity(0.12) : Color.teal.opacity(0.09))
    }
  }
  private var componentsChart: some View {
    let titles = ["HRV", "Resting HR", "Respiratory rate", "Sleep", "Recent sleep shortfall", "Training demand", "Cardio", "Activity", "Consistency", "Strength"]
    return VStack(alignment: .leading, spacing: 12) {
      Picker("Score", selection: $fitness) { Text("Recovery").tag(false); Text("Fitness").tag(true) }.pickerStyle(.segmented)
      Chart {
        if showHighlights { bands }
        ForEach(plottedScores) { point in
          ForEach(point.parts) { part in
            BarMark(x: .value("Date", point.date, unit: grain ?? .day), y: .value("Points", part.value))
              .foregroundStyle(by: .value("Component", part.title))
          }
          LineMark(x: .value("Date", point.date), y: .value("Overall", point.score)).foregroundStyle(RoburStyle.ink).lineStyle(StrokeStyle(lineWidth: 1.5))
        }
        if let selected { RuleMark(x: .value("Selected", selected)).foregroundStyle(.secondary) }
      }.chartForegroundStyleScale(domain: titles, range: titles.map { MetricColors.color($0) })
        .chartYScale(domain: 0...100).chartYAxisLabel("score points").chartXSelection(value: $selected).frame(height: 310)
      Text("\(grain == nil ? "Daily" : grain == .month ? "Monthly mean" : "Weekly mean") component contributions sum to the score, within rounding. Missing inputs change effective weights; missing overall scores are omitted. Details show the selected day's inputs. \(analysis?.methodologyVersion ?? RecoveryAnalysis.version).")
        .font(.caption).foregroundStyle(.secondary)
      ForEach((fitness ? selectedScore?.fitnessComponents : selectedScore?.recoveryComponents) ?? []) { part in
        VStack(alignment: .leading, spacing: 3) {
          HStack { Circle().fill(MetricColors.color(part.key)).frame(width: 8, height: 8); Text(part.title).fontWeight(.medium); Spacer(); Text(String(format: "%.1f pts · %.0f%%", part.contribution, part.effectiveWeight * 100)).monospacedDigit() }
          Text("\(part.current.formatted(.number.precision(.fractionLength(0...1)))) \(part.unit) · baseline \(part.baseline.map { $0.formatted(.number.precision(.fractionLength(0...1))) } ?? "—")").foregroundStyle(.secondary)
          Text(part.explanation).foregroundStyle(.secondary)
        }.font(.caption)
      }
    }
  }
  private var selectedScore: RecoveryHistoryPoint? { analysis?.history.first { calendar.isDate($0.date, inSameDayAs: inspectionDate) } }
  private var relationship: some View {
    VStack(alignment: .leading, spacing: 12) {
      metricPicker("Metric A", selection: $metricA)
      metricPicker("Metric B", selection: $metricB)
      Picker("Compare B", selection: $lag) { Text("Same day").tag(0); Text("1 day later").tag(1); Text("3 days later").tag(3); Text("7 days later").tag(7) }
      if let r = MetricAnalytics.correlation(pairs) { Text("r = \(r.formatted(.number.precision(.fractionLength(2)))) · \(pairs.count) paired dates").font(.headline).monospacedDigit() }
      else { Text("Correlation needs 14 paired dates with variation in both measures.").font(.caption).foregroundStyle(.secondary) }
      Chart(pairs) { pair in
        PointMark(x: .value(metricA.title, pair.x), y: .value(metricB.title, pair.y)).foregroundStyle(MetricColors.color(metricB.rawValue).opacity(0.75))
      }.chartXAxisLabel("\(metricA.title) · \(metricA.unit)").chartYAxisLabel("\(metricB.title) · \(metricB.unit)").frame(height: 310)
      Text("Pearson correlation pairs A with B \(lag == 0 ? "on the same date" : "\(lag) days later"). Only observed pairs are used. This is an association, not evidence of cause.").font(.caption).foregroundStyle(.secondary)
    }
  }
  private func metricPicker(_ title: String, selection: Binding<AnalyticsMetric>) -> some View {
    Picker(title, selection: selection) { ForEach(AnalyticsMetric.allCases) { Text($0.title).tag($0) } }
  }
  private var inspector: some View {
    VStack(alignment: .leading, spacing: 12) {
      DatePicker("Inspect date", selection: Binding(get: { inspectionDate }, set: { selected = $0 }), in: ...Date(), displayedComponents: .date)
      LazyVGrid(columns: [GridItem(.adaptive(minimum: 140), alignment: .leading)], alignment: .leading, spacing: 16) {
        ForEach(chosen) { metric in
          let reading = readings[metric]?.first { calendar.isDate($0.date, inSameDayAs: inspectionDate) }
          VStack(alignment: .leading, spacing: 3) {
            Label { Text(metric.title) } icon: { Circle().fill(MetricColors.color(metric.rawValue)).frame(width: 7, height: 7) }.font(.caption).foregroundStyle(.secondary)
            Text(reading.map { "\($0.value.formatted(.number.precision(.fractionLength(0...1)))) \(metric.unit)" } ?? "—").font(.headline).monospacedDigit()
          }
        }
      }
      ForEach(visibleHighlights.filter { $0.start <= inspectionDate && $0.end >= inspectionDate }) { event in
        Text("\(event.title): \(event.detail)").font(.caption).foregroundStyle(.secondary)
      }
    }.roburCard()
  }
  private var highlightsList: some View {
    DisclosureGroup("\(visibleHighlights.count) notable periods") {
      ForEach(Array(visibleHighlights.prefix(100))) { event in
        Button { selected = event.start } label: {
          VStack(alignment: .leading, spacing: 4) {
            Label(event.title, systemImage: event.kind == .effort ? "flag" : "waveform.path.ecg").font(.subheadline)
            Text(event.start, format: .dateTime.day().month().year()).font(.caption)
            Text(event.detail).font(.caption).foregroundStyle(.secondary)
          }.frame(maxWidth: .infinity, alignment: .leading).padding(.vertical, 6)
        }.buttonStyle(.plain)
      }
      Text("Descriptive patterns, not diagnoses or injury predictions.").font(.caption).foregroundStyle(.secondary)
    }.roburCard()
  }
  private func recalculate() {
    analysisTask?.cancel()
    let request = TrainingAnalysisRequest(days: healthKit.dailyMetrics, workouts: healthKit.analyticsWorkouts,
      annotations: journal.annotations, maxHR: maxHR, stepsGoal: stepsGoal, exerciseGoal: exerciseGoal,
      historyStart: healthKit.analyticsHistoryStart, fitnessReference: healthKit.fitnessReference)
    analysisTask = Task {
      try? await Task.sleep(for: .milliseconds(120))
      guard !Task.isCancelled, let result = try? await TrainingAnalysisWorker.shared.analytics(request), !Task.isCancelled else { return }
      analysis = result.analysis; readings = result.readings; highlights = result.highlights
    }
  }
}
