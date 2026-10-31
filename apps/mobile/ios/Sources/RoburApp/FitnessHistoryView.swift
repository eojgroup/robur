import SwiftUI
import Charts

struct FitnessHistoryView: View {
  @EnvironmentObject private var healthKit: HealthKitClient
  @EnvironmentObject private var journal: WorkoutJournal
  @State private var metric: FitnessMetric = .cardio
  @State private var signal: RecoverySignal = .sleep
  @State private var showLoad = true
  @State private var selectedDate: Date?
  @State private var selectedWorkout: WorkoutRecord?
  @State private var showingEvents = false
  @State private var workoutMarkersOnly = false
  @State private var timeline = TrainingTimelineSummary(buckets: [], recovery: [], events: [])

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
    NavigationStack {
      ScrollView {
        VStack(alignment: .leading, spacing: 20) {
          HistoryRangePicker()
          timelineCard
          if inspectedDate != nil { dayInspector }
          AdaptiveCardLayout {
            fitnessCard
            eventCard
            muscleCard
          }
          Text("Same dates across charts · \(grain.rawValue.lowercased()) totals and recorded-day averages. Associations do not establish cause.")
            .font(.caption).foregroundStyle(.secondary)
        }.frame(maxWidth: RoburStyle.contentWidth).padding().frame(maxWidth: .infinity)
      }
      .background(RoburStyle.background)
      .navigationTitle("Progress").navigationBarTitleDisplayMode(.inline)
      .toolbar {
        Button { healthKit.requestAuthorization() } label: { Image(systemName: "heart.text.square") }
          .accessibilityLabel("Manage Health access")
      }
      .refreshable { await healthKit.loadHistory(range: healthKit.historyRange) }
      .onChange(of: healthKit.workouts, initial: true) { _, _ in recalculate() }
      .onChange(of: healthKit.dailyMetrics) { _, _ in recalculate() }
      .onChange(of: signal) { _, _ in recalculate() }
      .onChange(of: healthKit.historyRange) { _, _ in selectedDate = nil; recalculate() }
      .sheet(item: $selectedWorkout) { WorkoutDetailView(workout: $0) }
      .sheet(isPresented: $showingEvents) {
        NavigationStack {
          List {
            Toggle("Workout markers only", isOn: $workoutMarkersOnly)
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
    }
  }

  private func recalculate() {
    timeline = TrainingTimeline.make(workouts: healthKit.workouts, days: healthKit.dailyMetrics,
      signal: signal, grain: grain, start: healthKit.historyRange.startDate())
  }

  private var timelineCard: some View {
    VStack(alignment: .leading, spacing: 16) {
      HStack {
        Label("Training & recovery", systemImage: "chart.xyaxis.line").font(.headline)
        Spacer()
        Text(grain.rawValue).font(.caption).foregroundStyle(.secondary)
      }
      Picker("Training measure", selection: $showLoad) {
        Text("Apple effort load").tag(true)
        Text("Minutes").tag(false)
      }.pickerStyle(.segmented)
      trainingChart
      HStack {
        Picker("Recovery signal", selection: $signal) {
          ForEach(RecoverySignal.allCases) { Text($0.rawValue).tag($0) }
        }.pickerStyle(.menu)
        Spacer()
        Label("Prior 30d", systemImage: "line.diagonal").font(.caption).foregroundStyle(.secondary)
      }
      recoveryChart
      if !markedEvents.isEmpty {
        Chart(markedEvents) { event in
          PointMark(x: .value("Date", event.date), y: .value("Event", event.kind.isWorkout ? "Effort" : "Recovery"))
            .foregroundStyle(event.kind.isWorkout ? RoburStyle.orange : RoburStyle.blue)
            .symbol(event.kind.isWorkout ? .diamond : .circle).symbolSize(22)
            .accessibilityLabel("\(event.kind.rawValue), \(event.date.formatted(date: .abbreviated, time: .omitted))")
        }.chartXScale(domain: chartStart...chartEnd).chartXSelection(value: $selectedDate)
          .chartXAxis(.hidden).frame(height: 52)
      }
      Text("Tap a date to inspect workouts and recovery. Missing readings stay empty.")
        .font(.caption).foregroundStyle(.secondary)
      DisclosureGroup("Sources & coverage") {
        VStack(alignment: .leading, spacing: 6) {
          Text("\(healthKit.workouts.count) workouts · \(timeline.buckets.reduce(0) { $0 + $1.ratedSessions }) with Apple effort. Load is duration × imported Apple Fitness rating or Apple estimate; unrated sessions are excluded.")
          Text("Recovery uses recorded-day averages. The dashed line is each reading’s preceding 30-day average, with at least 7 recorded days. Markers: sleep/HRV at least 20% below baseline, resting HR at least 10% above; sessions ≥120 min, Apple effort ≥8, marathon-distance runs, and the longest session.")
          if let error = healthKit.effortImportError { Text(error) }
          Text("All history includes every record Apple Health permits Robur to read. A marathon-distance marker describes a running workout of at least 42.195 km; it does not identify a race.")
        }.font(.caption).foregroundStyle(.secondary).padding(.top, 6)
      }.font(.caption)
    }.roburCard()
  }

  private var trainingChart: some View {
    let visible = timeline.buckets.filter { (showLoad ? $0.appleLoad : $0.minutes) != nil }
    return Group {
      if visible.isEmpty {
        ContentUnavailableView(showLoad ? "No Apple effort load" : "No workouts", systemImage: "chart.bar",
          description: Text(showLoad ? "Choose Minutes or review Health access." : "Choose a wider history or review Health access."))
          .frame(height: 180)
      } else {
        Chart {
          ForEach(visible) { point in
            BarMark(x: .value("Period", point.date, unit: grain.component),
              y: .value(showLoad ? "Apple effort load" : "Minutes", (showLoad ? point.appleLoad : point.minutes) ?? 0))
              .foregroundStyle(RoburStyle.orange.gradient).cornerRadius(3)
              .accessibilityLabel(point.date.formatted(date: .abbreviated, time: .omitted))
              .accessibilityValue("\(Int((showLoad ? point.appleLoad : point.minutes) ?? 0)) \(showLoad ? "AU" : "minutes"), \(point.sessions) sessions")
          }
          if let selectedDate { RuleMark(x: .value("Selected date", selectedDate)).foregroundStyle(.secondary) }
        }.chartXScale(domain: chartStart...chartEnd).chartXSelection(value: $selectedDate)
          .chartYAxisLabel(showLoad ? "AU" : "min").frame(height: 190)
      }
    }
  }

  private func recoveryValue(_ value: Double) -> Double { signal == .sleep ? value / 60 : value }
  private var recoveryChart: some View {
    Group {
      if timeline.recovery.isEmpty {
        ContentUnavailableView("No \(signal.rawValue.lowercased()) readings", systemImage: signal == .sleep ? "bed.double" : "waveform.path.ecg",
          description: Text("Choose a wider history or review Health access.")).frame(height: 160)
      } else {
        Chart {
          ForEach(timeline.buckets) { point in
            if let value = point.recoveryValue {
              LineMark(x: .value("Period", point.date), y: .value(signal.rawValue, recoveryValue(value)))
                .foregroundStyle(by: .value("Series", "Recorded · \(point.segment)"))
                .lineStyle(StrokeStyle(lineWidth: 2.5))
              PointMark(x: .value("Period", point.date), y: .value(signal.rawValue, recoveryValue(value)))
                .foregroundStyle(RoburStyle.blue).symbolSize(18)
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
        }.chartForegroundStyleScale(range: [RoburStyle.blue]).chartLegend(.hidden)
          .chartXScale(domain: chartStart...chartEnd).chartYScale(domain: .automatic(includesZero: false))
          .chartXSelection(value: $selectedDate).chartYAxisLabel(signal == .sleep ? "hours" : signal.unit).frame(height: 160)
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

  private var eventCard: some View {
    VStack(alignment: .leading, spacing: 14) {
      Label("Dates to explore", systemImage: "calendar.badge.clock").font(.headline)
      if markedEvents.isEmpty { Text("Long sessions, high effort and recovery changes appear here as history becomes available.").foregroundStyle(.secondary) }
      ForEach(Array(markedEvents.sorted { $0.date > $1.date }.prefix(8))) { event in
        Button { selectedDate = event.date } label: {
          HStack(alignment: .top, spacing: 10) {
            Image(systemName: event.kind.symbol).foregroundStyle(event.kind.isWorkout ? RoburStyle.orange : RoburStyle.blue)
            VStack(alignment: .leading, spacing: 3) {
              Text(event.kind.rawValue).font(.subheadline.bold())
              Text(event.detail).font(.caption).foregroundStyle(.secondary)
              Text(event.date.formatted(date: .abbreviated, time: .omitted)).font(.caption2).foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
            Image(systemName: "chevron.right").font(.caption)
          }
        }.buttonStyle(.plain)
      }
      if !timeline.events.isEmpty {
        Button("All marked dates (\(timeline.events.count))") { showingEvents = true }.font(.subheadline)
      }
      Text("Tap a marker to inspect the same date").font(.caption).foregroundStyle(.secondary)
    }.roburCard()
  }

  private var fitnessCard: some View {
    VStack(alignment: .leading, spacing: 16) {
      Label("Fitness over time", systemImage: "waveform.path.ecg").font(.headline)
      Picker("Fitness metric", selection: $metric) {
        ForEach(FitnessMetric.allCases) { item in Text(item.rawValue).tag(item) }
      }.pickerStyle(.menu)
      if let last = points.last {
        HStack(alignment: .firstTextBaseline) {
          Text(last.value, format: .number.precision(.fractionLength(1))).font(.largeTitle.bold()).monospacedDigit()
          Text(metric.unit).font(.caption).foregroundStyle(.secondary)
          Spacer()
          if let first = points.first, points.count > 1 {
            Text(String(format: "%+.1f", last.value - first.value)).font(.headline).foregroundStyle(RoburStyle.blue)
          }
        }
        Chart(points) { point in
          PointMark(x: .value("Period", point.date), y: .value(metric.rawValue, point.value)).foregroundStyle(RoburStyle.blue)
          if let selectedDate { RuleMark(x: .value("Selected", selectedDate)).foregroundStyle(.secondary) }
        }.chartXScale(domain: chartStart...chartEnd).chartYScale(domain: .automatic(includesZero: false))
          .chartXSelection(value: $selectedDate).frame(height: 180)
        Text("Recorded period averages · change from first period").font(.caption).foregroundStyle(.secondary)
      } else { Text("No \(metric.rawValue.lowercased()) readings in this history.").foregroundStyle(.secondary).frame(minHeight: 140) }
      DisclosureGroup("About \(metric.rawValue.lowercased())") { Text(metric.explanation).font(.caption).foregroundStyle(.secondary) }.font(.caption)
    }.roburCard()
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
