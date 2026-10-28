import SwiftUI
import Charts

struct FitnessHistoryView: View {
  @EnvironmentObject private var healthKit: HealthKitClient
  @EnvironmentObject private var journal: WorkoutJournal
  @State private var metric: FitnessMetric = .cardio
  @State private var showLoad = false
  @State private var selectedDate: Date?
  @State private var showingPeriod = false
  @State private var selectedWorkout: WorkoutRecord?

  private var monthly: Bool { healthKit.historyRange == .all || healthKit.historyRange == .year }
  private var buckets: [HistoryBucket] {
    WorkoutAnalytics.buckets(workouts: healthKit.workouts, annotations: journal.annotations, monthly: monthly)
  }
  private var points: [TrendPoint] {
    WorkoutAnalytics.trend(readings: healthKit.fitnessReadings, metric: metric, monthly: monthly)
  }
  private var chartStart: Date {
    let earliest = ([buckets.first?.date, points.first?.date].compactMap { $0 }).min() ?? Date()
    return Calendar.current.dateInterval(of: monthly ? .month : .weekOfYear,
      for: healthKit.historyRange.startDate() ?? earliest)?.start ?? earliest
  }
  private var selectedPeriod: DateInterval? {
    selectedDate.flatMap { Calendar.current.dateInterval(of: monthly ? .month : .weekOfYear, for: $0) }
  }
  private var periodWorkouts: [WorkoutRecord] {
    guard let period = selectedPeriod else { return [] }
    return healthKit.workouts.filter { $0.start >= period.start && $0.start < period.end }
  }
  private var periodReading: TrendPoint? {
    guard let start = selectedPeriod?.start else { return nil }
    return points.first { $0.date == start }
  }

  var body: some View {
    NavigationStack {
      ScrollView {
        VStack(alignment: .leading, spacing: 20) {
          VStack(alignment: .leading, spacing: 6) {
            Text("THE LONG VIEW").font(.caption.bold()).foregroundStyle(RoburStyle.teal)
            Text("See your progress").font(.largeTitle.bold())
            Text("Connect the work you put in with the way your fitness changes.").foregroundStyle(.secondary)
          }
          HistoryRangePicker()
          if let earliest = ([healthKit.workouts.last?.start, healthKit.fitnessReadings.first?.date].compactMap { $0 }).min() {
            Text("Available records from \(earliest.formatted(date: .abbreviated, time: .omitted))")
              .font(.caption).foregroundStyle(.secondary)
          }
          trainingCard
          fitnessCard
          if let period = selectedPeriod {
            VStack(alignment: .leading, spacing: 12) {
              Text("\(monthly ? "Month" : "Week") of \(period.start.formatted(date: .abbreviated, time: .omitted))").font(.headline)
              Text("\(periodWorkouts.count) workouts · \(Int(periodWorkouts.reduce(0) { $0 + $1.minutes })) min")
              if let reading = periodReading {
                Text("\(metric.rawValue): \(reading.value, specifier: "%.1f") \(metric.unit) average")
              } else { Text("No \(metric.rawValue.lowercased()) readings for this period.").foregroundStyle(.secondary) }
              Button("Explore these workouts") { showingPeriod = true }.disabled(periodWorkouts.isEmpty)
            }.roburCard()
          }
          muscleCard
          Text("Select a date on either chart to explore the same period. Charts use \(monthly ? "monthly" : "weekly") averages and totals. Trends show associations, not proof that a particular workout caused a change. All history means every record Apple Health permits Robur to read.")
            .font(.footnote).foregroundStyle(.secondary)
          HistoryPermissionView()
        }.padding()
      }
      .background(RoburStyle.background)
      .navigationTitle("Progress").navigationBarTitleDisplayMode(.inline)
      .refreshable { await healthKit.loadHistory(range: healthKit.historyRange) }
      .onChange(of: healthKit.historyRange) { _, _ in selectedDate = nil }
      .sheet(isPresented: $showingPeriod) {
        NavigationStack {
          List(periodWorkouts) { workout in
            Button { selectedWorkout = workout } label: {
              Label {
                VStack(alignment: .leading) {
                  Text(workout.title)
                  Text(workout.start.formatted(date: .abbreviated, time: .shortened)).font(.caption)
                }
              } icon: { Image(systemName: workout.symbol) }
            }
          }.navigationTitle("Period workouts")
            .toolbar { Button("Done") { showingPeriod = false } }
            .sheet(item: $selectedWorkout) { WorkoutDetailView(workout: $0) }
        }
      }
    }
  }

  private var trainingCard: some View {
    VStack(alignment: .leading, spacing: 16) {
      Label("Training rhythm", systemImage: "chart.bar.fill").font(.headline)
      Picker("Measure", selection: $showLoad) {
        Text("Minutes").tag(false)
        Text("Effort load").tag(true)
      }.pickerStyle(.segmented)
      let visible = showLoad ? buckets.filter { $0.ratedWorkouts > 0 } : buckets
      if visible.isEmpty {
        Text(showLoad ? "Rate workout effort in your journal to see session load over time." : "Share workouts or choose a wider history to see your training volume.")
          .foregroundStyle(.secondary).frame(minHeight: 140)
      } else {
        Chart(visible) { bucket in
          BarMark(x: .value("Period", bucket.date, unit: monthly ? .month : .weekOfYear),
                  y: .value(showLoad ? "Effort load (AU)" : "Minutes", showLoad ? bucket.load : bucket.minutes))
            .foregroundStyle(showLoad ? RoburStyle.amber.gradient : RoburStyle.teal.gradient)
            .cornerRadius(4)
            .accessibilityLabel(bucket.date.formatted(date: .abbreviated, time: .omitted))
            .accessibilityValue("\(Int(showLoad ? bucket.load : bucket.minutes)) \(showLoad ? "AU" : "minutes"), \(bucket.workouts) workouts")
          if let selectedDate { RuleMark(x: .value("Selected", selectedDate)).foregroundStyle(.secondary.opacity(0.5)) }
        }
        .chartXScale(domain: chartStart...Date())
        .chartXSelection(value: $selectedDate)
        .chartYAxisLabel(showLoad ? "AU" : "min")
        .frame(height: 200)
      }
      Text(showLoad
        ? "\(buckets.reduce(0) { $0 + $1.ratedWorkouts }) of \(healthKit.workouts.count) workouts rated. Load = duration × your 1–10 effort rating. Unrated workouts are excluded."
        : "\(healthKit.workouts.count) workouts · \(Int(healthKit.workouts.reduce(0) { $0 + $1.minutes })) total minutes")
        .font(.caption).foregroundStyle(.secondary)
    }.roburCard()
  }

  private var fitnessCard: some View {
    VStack(alignment: .leading, spacing: 16) {
      Label("Fitness over time", systemImage: "waveform.path.ecg").font(.headline)
      Picker("Fitness metric", selection: $metric) {
        ForEach(FitnessMetric.allCases) { item in Text(item.rawValue).tag(item) }
      }.pickerStyle(.segmented)
      if let last = points.last {
        HStack(alignment: .firstTextBaseline) {
          Text(last.value, format: .number.precision(.fractionLength(1))).font(.largeTitle.bold()).monospacedDigit()
          Text(metric.unit).foregroundStyle(.secondary)
          Spacer()
          if let first = points.first, points.count > 1 {
            Text(String(format: "%+.1f", last.value - first.value)).font(.headline).foregroundStyle(RoburStyle.blue)
          }
        }
        Text("Latest period average\(points.count > 1 ? " · change from first period" : "")").font(.caption).foregroundStyle(.secondary)
        Chart(points) { point in
          LineMark(x: .value("Period", point.date), y: .value(metric.rawValue, point.value))
            .foregroundStyle(RoburStyle.blue).lineStyle(StrokeStyle(lineWidth: 3))
          PointMark(x: .value("Period", point.date), y: .value(metric.rawValue, point.value))
            .foregroundStyle(RoburStyle.blue)
            .accessibilityLabel(point.date.formatted(date: .abbreviated, time: .omitted))
            .accessibilityValue("\(point.value.formatted()) \(metric.unit)")
          if let selectedDate { RuleMark(x: .value("Selected", selectedDate)).foregroundStyle(.secondary.opacity(0.5)) }
        }
        .chartXScale(domain: chartStart...Date())
        .chartYScale(domain: .automatic(includesZero: false))
        .chartXSelection(value: $selectedDate)
        .frame(height: 200)
      } else {
        Text("No \(metric.rawValue.lowercased()) readings in this period. Try a wider history or manage Health access.")
          .foregroundStyle(.secondary).frame(minHeight: 140)
      }
      Text(metric.explanation).font(.caption).foregroundStyle(.secondary)
    }.roburCard()
  }

  private var muscleCard: some View {
    let totals = MuscleGroup.allCases.map { group in
      (group, healthKit.workouts.filter { journal.annotations[$0.id]?.muscles.contains(group) == true }.count)
    }.filter { $0.1 > 0 }
    return VStack(alignment: .leading, spacing: 16) {
      Label("Where you put the work", systemImage: "figure.strengthtraining.traditional").font(.headline)
      if totals.isEmpty {
        Text("Tag muscles on individual workouts to see your training balance here.").foregroundStyle(.secondary)
      } else {
        Chart(totals, id: \.0) { group, count in
          BarMark(x: .value("Sessions", count), y: .value("Muscle", group.rawValue))
            .foregroundStyle(RoburStyle.teal).cornerRadius(4)
            .annotation(position: .trailing) { Text("\(count)").font(.caption) }
        }.frame(height: CGFloat(max(120, totals.count * 32)))
        Text("Sessions tagged per muscle, within the selected history. A workout can train several groups.")
          .font(.caption).foregroundStyle(.secondary)
      }
    }.roburCard()
  }
}
