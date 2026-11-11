import SwiftUI
import Charts

private enum OverviewGraph: String, CaseIterable, Identifiable {
  case recoveryScore = "Recovery", fitnessScore = "Fitness", training = "Load", recovery = "Signals", fitness = "Health"
  var id: String { rawValue }
}

struct FitnessHistoryView: View {
  var embedded = false
  @EnvironmentObject private var healthKit: HealthKitClient
  @EnvironmentObject private var journal: WorkoutJournal
  @Environment(\.dynamicTypeSize) private var typeSize
  @AppStorage("RoburMaxHeartRate") private var maxHR = 190.0
  @AppStorage("RoburStepsGoal") private var stepsGoal = 8_000.0
  @AppStorage("RoburExerciseGoal") private var exerciseGoal = 30.0
  @State private var graph: OverviewGraph = .recoveryScore
  @State private var scoreVariation: RecoveryChartVariation = .history
  @State private var scoreAnalysis: RecoveryAnalysis?
  @State private var analysisTask: Task<Void, Never>?
  @State private var contentWidth: CGFloat = 360
  @State private var showingDay = false
  @State private var showingMuscles = false
  @State private var metric: FitnessMetric = .cardio
  @State private var signal: RecoverySignal = .sleep
  @State private var showLoad = true
  @State private var selectedDate: Date?
  @State private var selectedWorkout: WorkoutRecord?
  @State private var showingEvents = false
  @State private var workoutMarkersOnly = false
  @State private var timeline = TrainingTimelineSummary(buckets: [], recovery: [], events: [])

  private var wideLayout: Bool { contentWidth >= 760 && !typeSize.isAccessibilitySize }
  private var graphHeight: CGFloat { wideLayout ? 300 : 250 }
  private var grain: TimelineGrain {
    switch healthKit.historyRange {
    case .month: return .day
    case .quarter: return .week
    case .year, .all: return .month
    }
  }
  private var points: [TrendPoint] {
    let readings = healthKit.fitnessReadings.filter { $0.metric == metric && $0.value.isFinite && $0.value > 0 }
    let grouped = Dictionary(grouping: readings) { Calendar.current.dateInterval(of: grain.component, for: $0.date)?.start ?? $0.date }
    return grouped.map { TrendPoint(date: $0.key, value: $0.value.reduce(0) { $0 + $1.value } / Double($0.value.count)) }
      .sorted { $0.date < $1.date }
  }
  private var chartStart: Date {
    let earliest = ([timeline.buckets.first?.date, points.first?.date].compactMap { $0 }).min() ?? Date()
    return Calendar.current.dateInterval(of: grain.component, for: healthKit.historyRange.startDate() ?? earliest)?.start ?? earliest
  }
  private var chartEnd: Date { max(Date(), chartStart.addingTimeInterval(86_400)) }
  private var inspectedDate: Date? { selectedDate.map { Calendar.current.startOfDay(for: $0) } }
  private var selectedSessions: [WorkoutRecord] {
    guard let date = inspectedDate else { return [] }
    return healthKit.workouts.filter { Calendar.current.isDate($0.start, inSameDayAs: date) }
  }
  private var selectedHealth: DailyHealthMetrics? {
    guard let date = inspectedDate else { return nil }
    return healthKit.dailyMetrics.first { Calendar.current.isDate($0.date, inSameDayAs: date) }
  }
  private var markedEvents: [TrainingTimelineEvent] {
    timeline.events.filter { $0.kind.isWorkout ||
      (signal == .sleep && $0.kind == .poorSleep) ||
      (signal == .hrv && $0.kind == .lowHRV) ||
      (signal == .restingHR && $0.kind == .highRestingHR) }
  }

  var body: some View {
    Group {
      if embedded { content }
      else { NavigationStack { content } }
    }
  }
  private var content: some View {
    observedContent
      .sheet(isPresented: $showingDay) { daySheet }
      .sheet(isPresented: $showingMuscles) { muscleSheet }
      .sheet(isPresented: $showingEvents) { eventsSheet }
  }
  private var observedContent: some View {
    configuredContent
      .onChange(of: healthKit.workouts, initial: true) { _, _ in recalculate() }
      .onChange(of: healthKit.analyticsWorkouts) { _, _ in recalculate() }
      .onChange(of: journal.annotations) { _, _ in recalculate() }
      .onChange(of: maxHR) { _, _ in recalculate() }
      .onChange(of: stepsGoal) { _, _ in recalculate() }
      .onChange(of: exerciseGoal) { _, _ in recalculate() }
      .onChange(of: healthKit.dailyMetrics) { _, _ in recalculate() }
      .onChange(of: signal) { _, _ in recalculate() }
      .onChange(of: healthKit.historyRange) { _, _ in selectedDate = nil; recalculate() }
      .onDisappear { analysisTask?.cancel() }
  }
  private var configuredContent: some View {
    historyScrollContent
      .background(RoburStyle.background)
      .navigationTitle("Overview").navigationBarTitleDisplayMode(.inline)
      .toolbar {
        NavigationLink { HealthSettingsView() } label: { Image(systemName: "slider.horizontal.3") }
          .accessibilityLabel("Goals, appearance and notifications")
        Button { healthKit.requestAuthorization() } label: { Image(systemName: "heart.text.square") }
          .accessibilityLabel("Manage Health access")
      }
      .task {
        if healthKit.authorizationRequested { await healthKit.refreshTodaySnapshot() }
      }
      .refreshable { await healthKit.refreshTodaySnapshot(); await healthKit.loadHistory(range: healthKit.historyRange) }
  }
  private var historyScrollContent: some View {
      ScrollView {
        VStack(alignment: .leading, spacing: 16) {
          timelineCard
          if inspectedDate != nil { selectedDateSummary }
          HealthOverviewView(compactOnly: true)
          HStack {
            Button { showingEvents = true } label: { Label("Marked dates", systemImage: "flag") }
            Spacer()
            Button { showingMuscles = true } label: { Label("Muscle balance", systemImage: "figure.strengthtraining.traditional") }
          }.font(.subheadline)
          if !healthKit.authorizationRequested { HistoryPermissionView() }
        }.frame(maxWidth: RoburStyle.contentWidth)
          .background { GeometryReader { proxy in
            Color.clear.onAppear { contentWidth = proxy.size.width }
              .onChange(of: proxy.size.width) { _, value in contentWidth = value }
          } }
          .padding().frame(maxWidth: .infinity)
      }
  }
  private var daySheet: some View {
        NavigationStack {
          ScrollView { dayInspector.padding() }.background(RoburStyle.background)
            .navigationTitle("Day details").navigationBarTitleDisplayMode(.inline)
            .toolbar { Button("Done") { showingDay = false } }
            .sheet(item: $selectedWorkout) { WorkoutDetailView(workout: $0) }
        }
  }
  private var muscleSheet: some View {
        NavigationStack {
          ScrollView { muscleCard.padding() }.background(RoburStyle.background)
            .navigationTitle("Muscle balance").navigationBarTitleDisplayMode(.inline)
            .toolbar { Button("Done") { showingMuscles = false } }
        }
  }
  private var eventsSheet: some View {
        NavigationStack {
          List {
            Toggle("Workout markers only", isOn: $workoutMarkersOnly)
            if timeline.events.isEmpty {
              ContentUnavailableView("No marked dates", systemImage: "flag",
                description: Text("Long sessions, high effort and recovery changes appear when available."))
            }
            ForEach(timeline.events.filter { !workoutMarkersOnly || $0.kind.isWorkout }.sorted { $0.date > $1.date }) { event in
              Button {
                selectedDate = event.date
                showingEvents = false
              } label: {
                Label {
                  VStack(alignment: .leading, spacing: 4) {
                    Text(event.kind.rawValue).font(.headline)
                    Text(event.detail).font(.caption).foregroundStyle(.secondary)
                    Text(event.date.formatted(date: .abbreviated, time: .omitted)).font(.caption)
                  }
                } icon: { Image(systemName: event.kind.symbol) }
              }.buttonStyle(.plain)
            }
          }.navigationTitle("Marked dates")
            .toolbar { Button("Done") { showingEvents = false } }
        }
  }

  private func recalculate() {
    analysisTask?.cancel()
    let request = TrainingAnalysisRequest(days: healthKit.dailyMetrics, workouts: healthKit.analyticsWorkouts,
      annotations: journal.annotations, maxHR: maxHR,
      stepsGoal: stepsGoal, exerciseGoal: exerciseGoal,
      historyStart: healthKit.analyticsHistoryStart, fitnessReference: healthKit.fitnessReference)
    analysisTask = Task {
      try? await Task.sleep(for: .milliseconds(120))
      guard !Task.isCancelled, let result = try? await TrainingAnalysisWorker.shared.make(request), !Task.isCancelled else { return }
      scoreAnalysis = result.recoveryAnalysis
    }
    timeline = TrainingTimeline.make(workouts: healthKit.workouts, days: healthKit.dailyMetrics,
      signal: signal, grain: grain, start: healthKit.historyRange.startDate())
  }

  private var graphTitle: String {
    switch graph {
    case .recoveryScore: return "Recovery & readiness"
    case .fitnessScore: return "Your fitness over time"
    case .training: return showLoad ? "Training load" : "Training minutes"
    case .recovery: return signal.rawValue
    case .fitness: return metric.rawValue
    }
  }

  private var timelineCard: some View {
    VStack(alignment: .leading, spacing: 14) {
      HStack(alignment: .firstTextBaseline) {
        VStack(alignment: .leading, spacing: 3) {
          Text(graphTitle).font(.title2.bold())
          Text("\(grain.rawValue) · tap a date to explore").font(.caption).foregroundStyle(.secondary)
        }
        Spacer(minLength: 8)
        graphOptions
      }
      HistoryRangePicker()
      Picker("Overview chart", selection: $graph) {
        ForEach(OverviewGraph.allCases) { item in Text(item.rawValue).tag(item) }
      }.pickerStyle(.segmented).accessibilityIdentifier("overview-graph-selector")
      if graph == .training && wideLayout {
        HStack(alignment: .top, spacing: 24) {
          VStack(alignment: .leading, spacing: 10) {
            Text(showLoad ? "Apple effort load" : "Training minutes").font(.subheadline.weight(.semibold))
            trainingChart
          }.frame(maxWidth: .infinity)
          VStack(alignment: .leading, spacing: 10) {
            HStack {
              Text("Recovery").font(.subheadline.weight(.semibold))
              Spacer()
              recoveryOptions
            }
            recoveryChart
          }.frame(maxWidth: .infinity)
        }
      } else {
        selectedGraph
      }
      if !markedEvents.isEmpty {
        eventTimeline
      }
      DisclosureGroup("Sources & coverage") {
        VStack(alignment: .leading, spacing: 6) {
          Text("\(healthKit.workouts.count) workouts · \(timeline.buckets.reduce(0) { $0 + $1.ratedSessions }) with Apple effort. Load is duration × imported Apple Fitness rating or Apple estimate; unrated sessions are excluded.")
          Text("Scores use \(RecoveryAnalysis.version), consistently recomputed from currently available history. Recovery combines eligible autonomic, sleep and training-demand components. Fitness excludes acute recovery; it describes personal cardio change and sustained participation, not a clinical fitness measurement.")
          Text("Recovery averages include recorded days only. The dashed line uses each reading’s prior 30 days, with at least 7 recorded days. Missing measurements stay empty.")
          Text("Markers highlight long or high-effort sessions, marathon-distance runs and changes in sleep, HRV or resting heart rate. Associations do not establish cause.")
          Text("All history includes every record Apple Health permits Robur to read. A marathon-distance marker describes at least 42.195 km; it does not identify a race.")
          if let error = healthKit.effortImportError { Text(error) }
          if graph == .fitness { Text(metric.explanation) }
        }.font(.caption).foregroundStyle(.secondary).padding(.top, 6)
      }.font(.caption)
    }.roburCard()
  }

  @ViewBuilder private var selectedGraph: some View {
    switch graph {
    case .recoveryScore, .fitnessScore:
      if let scoreAnalysis {
        RecoveryScoreCharts(analysis: scoreAnalysis, isFitness: graph == .fitnessScore, range: healthKit.historyRange,
          variation: scoreVariation, height: graphHeight, selectedDate: $selectedDate)
      } else { ProgressView("Calculating your history…").frame(height: graphHeight) }
    case .training: trainingChart
    case .recovery: recoveryChart
    case .fitness: fitnessCard
    }
  }

  @ViewBuilder private var graphOptions: some View {
    switch graph {
    case .recoveryScore, .fitnessScore:
      Picker("Score visualization", selection: $scoreVariation) {
        ForEach(RecoveryChartVariation.allCases) { item in Text(item.rawValue).tag(item) }
      }.pickerStyle(.menu).font(.caption.weight(.semibold))
    case .training:
      Menu {
        Picker("Training measure", selection: $showLoad) {
          Text("Apple effort load").tag(true)
          Text("Minutes").tag(false)
        }
      } label: { Label(showLoad ? "Load" : "Minutes", systemImage: "slider.horizontal.3") }
        .font(.caption.weight(.semibold))
    case .recovery: recoveryOptions
    case .fitness:
      Picker("Health metric", selection: $metric) {
        ForEach(FitnessMetric.allCases) { item in Text(item.rawValue).tag(item) }
      }.pickerStyle(.menu).font(.caption.weight(.semibold))
    }
  }

  private var recoveryOptions: some View {
    Picker("Recovery signal", selection: $signal) {
      ForEach(RecoverySignal.allCases) { Text($0.rawValue).tag($0) }
    }.pickerStyle(.menu).font(.caption.weight(.semibold))
  }

  private var eventTimeline: some View {
    Chart(markedEvents) { event in
      PointMark(x: .value("Date", event.date), y: .value("Event", event.kind.isWorkout ? "Effort" : "Recovery"))
        .foregroundStyle(event.kind.isWorkout ? RoburStyle.orange : RoburStyle.blue)
        .symbol(event.kind.isWorkout ? .diamond : .circle).symbolSize(22)
        .accessibilityLabel("\(event.kind.rawValue), \(event.date.formatted(date: .abbreviated, time: .omitted))")
    }.chartXScale(domain: chartStart...chartEnd).chartXSelection(value: $selectedDate)
      .chartXAxis(.hidden).frame(height: 38)
  }

  private var selectedDateSummary: some View {
    Button { showingDay = true } label: {
      HStack {
        VStack(alignment: .leading, spacing: 4) {
          Text((inspectedDate ?? Date()).formatted(date: .abbreviated, time: .omitted)).font(.subheadline.bold())
          Text("\(selectedSessions.count) sessions · \(Int(selectedSessions.reduce(0) { $0 + $1.minutes })) min")
            .font(.caption).foregroundStyle(.secondary)
        }
        Spacer()
        Label("Details", systemImage: "chevron.right").font(.subheadline)
      }.padding(.horizontal, 12).padding(.vertical, 8)
        .background(RoburStyle.surface, in: RoundedRectangle(cornerRadius: 12))
    }.buttonStyle(.plain)
  }

  private var trainingChart: some View {
    let visible = timeline.buckets.filter { (showLoad ? $0.appleLoad : $0.minutes) != nil }
    return Group {
      if visible.isEmpty {
        ContentUnavailableView(showLoad ? "No Apple effort load" : "No workouts", systemImage: "chart.bar",
          description: Text(showLoad ? "Choose Minutes or review Health access." : "Choose a wider history or review Health access."))
          .frame(height: graphHeight)
      } else {
        Chart {
          ForEach(visible) { point in
            BarMark(x: .value("Period", point.date, unit: grain.component),
              y: .value(showLoad ? "Apple effort load" : "Minutes", (showLoad ? point.appleLoad : point.minutes) ?? 0))
              .foregroundStyle(MetricColors.color("acuteLoad").gradient).cornerRadius(3)
              .accessibilityLabel(point.date.formatted(date: .abbreviated, time: .omitted))
              .accessibilityValue("\(Int((showLoad ? point.appleLoad : point.minutes) ?? 0)) \(showLoad ? "AU" : "minutes"), \(point.sessions) sessions")
          }
          if let selectedDate { RuleMark(x: .value("Selected date", selectedDate)).foregroundStyle(.secondary) }
        }.chartXScale(domain: chartStart...chartEnd).chartXSelection(value: $selectedDate)
          .chartYAxisLabel(showLoad ? "AU" : "min").frame(height: graphHeight)
      }
    }
  }

  private func recoveryValue(_ value: Double) -> Double { signal == .sleep ? value / 60 : value }
  private var recoveryChart: some View {
    Group {
      if timeline.recovery.isEmpty {
        ContentUnavailableView("No \(signal.rawValue.lowercased()) readings", systemImage: signal == .sleep ? "bed.double" : "waveform.path.ecg",
          description: Text("Choose a wider history or review Health access.")).frame(height: graphHeight)
      } else {
        Chart {
          ForEach(timeline.buckets) { point in
            if let value = point.recoveryValue {
              LineMark(x: .value("Period", point.date), y: .value(signal.rawValue, recoveryValue(value)))
                .foregroundStyle(by: .value("Series", "Recorded · \(point.segment)"))
                .lineStyle(StrokeStyle(lineWidth: 2.5))
              PointMark(x: .value("Period", point.date), y: .value(signal.rawValue, recoveryValue(value)))
                .foregroundStyle(MetricColors.color(signal.rawValue)).symbolSize(18)
                .accessibilityLabel(point.date.formatted(date: .abbreviated, time: .omitted))
                .accessibilityValue("\(recoveryValue(value).formatted()) \(signal == .sleep ? "hours" : signal.unit), \(point.recoveryDays) recorded days")
            }
            if let baseline = point.recoveryBaseline {
              LineMark(x: .value("Period", point.date), y: .value("30-day baseline", recoveryValue(baseline)))
                .foregroundStyle(by: .value("Series", "Baseline · \(point.segment)"))
                .lineStyle(StrokeStyle(lineWidth: 1, dash: [4, 4]))
            }
          }
          if let selectedDate { RuleMark(x: .value("Selected date", selectedDate)).foregroundStyle(.secondary) }
        }.chartForegroundStyleScale(range: [MetricColors.color(signal.rawValue)]).chartLegend(.hidden)
          .chartXScale(domain: chartStart...chartEnd).chartYScale(domain: .automatic(includesZero: false))
          .chartXSelection(value: $selectedDate).chartYAxisLabel(signal == .sleep ? "hours" : signal.unit).frame(height: graphHeight)
      }
    }
  }

  private var dayInspector: some View {
    VStack(alignment: .leading, spacing: 14) {
      DatePicker("Inspect date", selection: Binding(get: { inspectedDate ?? Date() }, set: { selectedDate = $0 }),
        in: chartStart...chartEnd, displayedComponents: .date).font(.headline)
      LazyVGrid(columns: [GridItem(.adaptive(minimum: 135))], alignment: .leading, spacing: 12) {
        ForEach(RecoverySignal.allCases) { metric in
          VStack(alignment: .leading, spacing: 4) {
            Text(metric.rawValue).font(.caption).foregroundStyle(.secondary)
            Text(selectedHealth?[keyPath: metric.key].map { "\(Int($0.rounded())) \(metric.unit)" } ?? "No reading").font(.headline)
          }
        }
      }
      if let point = scoreAnalysis?.history.first(where: { Calendar.current.isDate($0.date, inSameDayAs: inspectedDate ?? Date()) }) {
        HStack {
          Text("Recovery \(point.recovery.map(String.init) ?? "—")/100")
          Spacer()
          Text("Fitness \(point.fitness.map(String.init) ?? "—")/100")
        }.font(.headline).monospacedDigit()
        ForEach(point.recoveryComponents) { component in
          LabeledContent(component.title, value: String(format: "%.1f pts · %d/100", component.contribution, component.score)).font(.caption)
        }
        Text("Historical point · \(Int((point.coverage * 100).rounded()))% eligible recovery input weight").font(.caption2).foregroundStyle(.secondary)
      }
      if let date = inspectedDate {
        ForEach(timeline.events.filter { Calendar.current.isDate($0.date, inSameDayAs: date) }) { event in
          Label("\(event.kind.rawValue) · \(event.detail)", systemImage: event.kind.symbol).font(.caption).foregroundStyle(.secondary)
        }
      }
      if selectedSessions.isEmpty { Text("No workouts recorded on this date.").font(.subheadline).foregroundStyle(.secondary) }
      ForEach(selectedSessions) { workout in
        Button { selectedWorkout = workout } label: {
          HStack {
            Label(workout.title, systemImage: workout.symbol)
            Spacer()
            Text("\(Int(workout.minutes)) min").monospacedDigit()
            Image(systemName: "chevron.right").font(.caption)
          }.font(.subheadline)
        }.buttonStyle(.plain)
      }
    }.roburCard()
  }

  private var fitnessCard: some View {
    VStack(alignment: .leading, spacing: 12) {
      if let last = points.last {
        HStack(alignment: .firstTextBaseline) {
          Text(last.value, format: .number.precision(.fractionLength(1))).font(.title.bold()).monospacedDigit()
          Text(metric.unit).font(.caption).foregroundStyle(.secondary)
          Spacer()
          if let first = points.first, points.count > 1 {
            Text(String(format: "%+.1f", last.value - first.value)).font(.headline).foregroundStyle(MetricColors.color(metric.rawValue))
          }
        }
        Chart(points) { point in
          PointMark(x: .value("Period", point.date), y: .value(metric.rawValue, point.value))
            .foregroundStyle(MetricColors.color(metric.rawValue)).symbolSize(35)
            .accessibilityLabel(point.date.formatted(date: .abbreviated, time: .omitted))
            .accessibilityValue("\(point.value.formatted()) \(metric.unit)")
          if let selectedDate { RuleMark(x: .value("Selected", selectedDate)).foregroundStyle(.secondary) }
        }.chartXScale(domain: chartStart...chartEnd).chartYScale(domain: .automatic(includesZero: false))
          .chartXSelection(value: $selectedDate).frame(height: graphHeight)
        Text("Recorded period averages · change from first period").font(.caption).foregroundStyle(.secondary)
      } else {
        ContentUnavailableView("No \(metric.rawValue.lowercased()) readings", systemImage: "chart.xyaxis.line",
          description: Text("Choose a wider history or review Health access.")).frame(height: graphHeight)
      }
    }
  }

  private var muscleCard: some View {
    let totals = MuscleGroup.allCases.map { group in
      (group, healthKit.workouts.filter { journal.annotations[$0.id]?.muscles.contains(group) == true }.count)
    }.filter { $0.1 > 0 }
    return VStack(alignment: .leading, spacing: 16) {
      Label("Muscle balance", systemImage: "figure.strengthtraining.traditional").font(.headline)
      if totals.isEmpty { Text("Tag muscles on a workout to see your training balance.").foregroundStyle(.secondary) }
      else {
        Chart(totals, id: \.0) { group, count in
          BarMark(x: .value("Sessions", count), y: .value("Muscle", group.rawValue)).foregroundStyle(RoburStyle.teal).cornerRadius(4)
            .annotation(position: .trailing) { Text("\(count)").font(.caption) }
        }.frame(height: CGFloat(max(120, totals.count * 32)))
        Text("Sessions tagged per muscle · selected history").font(.caption).foregroundStyle(.secondary)
      }
    }.roburCard()
  }
}
