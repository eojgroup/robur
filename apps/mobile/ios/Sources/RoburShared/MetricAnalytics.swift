import Foundation

enum AnalyticsMetric: String, CaseIterable, Identifiable, Sendable {
  case recovery, fitness, acuteLoad, chronicLoad, sleep, hrv, restingHR, respiratoryRate, oxygen
  case steps, exercise, stand, energy, cardio, weight, bodyFat, bmi, appleLoad
  var id: String { rawValue }
  var title: String {
    switch self {
    case .recovery: return "Recovery"
    case .fitness: return "Fitness"
    case .acuteLoad: return "Acute load · 7d"
    case .chronicLoad: return "Chronic load · 42d"
    case .sleep: return "Sleep"
    case .hrv: return "HRV · SDNN"
    case .restingHR: return "Resting heart rate"
    case .respiratoryRate: return "Respiratory rate"
    case .oxygen: return "Blood oxygen"
    case .steps: return "Steps"
    case .exercise: return "Exercise"
    case .stand: return "Stand time"
    case .energy: return "Active energy"
    case .cardio: return "VO₂ max"
    case .weight: return "Weight"
    case .bodyFat: return "Body fat"
    case .bmi: return "BMI"
    case .appleLoad: return "Apple effort load"
    }
  }
  var unit: String {
    switch self {
    case .recovery, .fitness: return "/100"
    case .acuteLoad, .chronicLoad: return "AU/day"
    case .sleep, .exercise, .stand: return "min"
    case .hrv: return "ms"
    case .restingHR: return "bpm"
    case .respiratoryRate: return "breaths/min"
    case .oxygen, .bodyFat: return "%"
    case .steps: return "steps"
    case .energy: return "kcal"
    case .cardio: return "mL/kg/min"
    case .weight: return "kg"
    case .bmi: return "kg/m²"
    case .appleLoad: return "AU"
    }
  }
  var dailyKey: KeyPath<DailyHealthMetrics, Double?>? {
    switch self {
    case .sleep: return \.sleepMinutes
    case .hrv: return \.hrv
    case .restingHR: return \.restingHR
    case .respiratoryRate: return \.respiratoryRate
    case .oxygen: return \.oxygenSaturation
    case .steps: return \.steps
    case .exercise: return \.exerciseMinutes
    case .stand: return \.standMinutes
    case .energy: return \.activeEnergyKcal
    case .cardio: return \.vo2Max
    case .weight: return \.weightKg
    case .bodyFat: return \.bodyFatPercent
    case .bmi: return \.bmi
    default: return nil
    }
  }
}

enum AnalyticsScale: String, CaseIterable, Identifiable {
  case percent = "% from baseline", zScore = "Standard deviations", raw = "Raw units"
  var id: String { rawValue }
}
struct AnalyticsReading: Identifiable, Equatable, Sendable {
  var id: Date { date }
  let date: Date
  let value: Double
}
struct AnalyticsComparedReading: Identifiable {
  var id: Date { date }
  let date: Date
  let value: Double
  let raw: Double
  let baseline: Double?
  let observations: Int
}
struct AnalyticsPair: Identifiable {
  var id: Date { date }
  let date: Date
  let x: Double
  let y: Double
}
struct AnalyticsHighlight: Identifiable, Sendable {
  enum Kind: String, Sendable { case effort, recovery, signals, coverage }
  let id: String
  let kind: Kind
  let start: Date
  var end: Date
  let title: String
  var detail: String
}

enum MetricAnalytics {
  static func series(days: [DailyHealthMetrics], workouts: [WorkoutRecord], analysis: RecoveryAnalysis,
                     now: Date = Date(), calendar: Calendar = .current) -> [AnalyticsMetric: [AnalyticsReading]] {
    var result: [AnalyticsMetric: [AnalyticsReading]] = [:]
    for metric in AnalyticsMetric.allCases {
      var values: [Date: Double] = [:]
      if let key = metric.dailyKey {
        for day in days.sorted(by: { $0.date < $1.date }) where day.date <= now {
          if let value = day[keyPath: key], value.isFinite, value >= 0 { values[calendar.startOfDay(for: day.date)] = value }
        }
      } else if metric == .appleLoad {
        var seen: Set<String> = []
        for workout in workouts where workout.end <= now && seen.insert(workout.id).inserted {
          if let effort = workout.appleEffort, effort.isFinite, effort > 0, effort <= 10, workout.minutes.isFinite, workout.minutes > 0 {
            values[calendar.startOfDay(for: workout.end), default: 0] += effort * workout.minutes
          }
        }
      } else {
        for point in analysis.history where point.date <= now {
          let value: Double?
          switch metric {
          case .recovery: value = point.recovery.map(Double.init)
          case .fitness: value = point.fitness.map(Double.init)
          case .acuteLoad: value = point.acuteLoad
          case .chronicLoad: value = point.chronicLoad
          default: value = nil
          }
          if let value, value.isFinite { values[calendar.startOfDay(for: point.date)] = value }
        }
      }
      result[metric] = values.keys.sorted().map { AnalyticsReading(date: $0, value: values[$0]!) }
    }
    return result
  }

  static func compare(_ readings: [AnalyticsReading], scale: AnalyticsScale, calendar: Calendar = .current) -> [AnalyticsComparedReading] {
    var unique: [Date: AnalyticsReading] = [:]
    for reading in readings where reading.value.isFinite { unique[calendar.startOfDay(for: reading.date)] = reading }
    let sorted = unique.values.sorted { $0.date < $1.date }
    var result: [AnalyticsComparedReading] = [], start = 0, sum = 0.0, squared = 0.0
    for (index, point) in sorted.enumerated() {
      let lower = calendar.date(byAdding: .day, value: -30, to: point.date) ?? point.date
      while start < index && sorted[start].date < lower { sum -= sorted[start].value; squared -= pow(sorted[start].value, 2); start += 1 }
      let count = index - start, baseline = count > 0 ? sum / Double(count) : 0
      let variance = count > 0 ? max(0, squared / Double(count) - baseline * baseline) : 0
      let value: Double?
      switch scale {
      case .raw: value = point.value
      case .percent: value = count >= 7 && baseline != 0 ? (point.value / baseline - 1) * 100 : nil
      case .zScore:
        if count < 7 { value = nil }
        else if variance > Double.ulpOfOne * max(1, baseline * baseline) * 32 { value = (point.value - baseline) / sqrt(variance) }
        else { value = abs(point.value - baseline) < 1e-9 ? 0 : nil }
      }
      if let value, value.isFinite { result.append(.init(date: point.date, value: value, raw: point.value,
        baseline: scale == .raw ? nil : baseline, observations: count)) }
      sum += point.value; squared += point.value * point.value
    }
    return result
  }

  static func paired(_ a: [AnalyticsReading], _ b: [AnalyticsReading], lagDays: Int, calendar: Calendar = .current) -> [AnalyticsPair] {
    guard abs(lagDays) <= 30 else { return [] }
    var first: [Date: Double] = [:], second: [Date: Double] = [:]
    for point in a where point.value.isFinite { first[calendar.startOfDay(for: point.date)] = point.value }
    for point in b where point.value.isFinite { second[calendar.startOfDay(for: point.date)] = point.value }
    return first.keys.sorted().compactMap { date in
      guard let shifted = calendar.date(byAdding: .day, value: lagDays, to: date), let y = second[shifted], let x = first[date] else { return nil }
      return AnalyticsPair(date: date, x: x, y: y)
    }
  }
  static func correlation(_ pairs: [AnalyticsPair]) -> Double? {
    guard pairs.count >= 14 else { return nil }
    let meanX = pairs.reduce(0) { $0 + $1.x } / Double(pairs.count), meanY = pairs.reduce(0) { $0 + $1.y } / Double(pairs.count)
    let x = pairs.reduce(0) { $0 + pow($1.x - meanX, 2) }, y = pairs.reduce(0) { $0 + pow($1.y - meanY, 2) }
    guard x > 0, y > 0 else { return nil }
    return max(-1, min(1, pairs.reduce(0) { $0 + ($1.x - meanX) * ($1.y - meanY) } / sqrt(x * y)))
  }

  static func highlights(series: [AnalyticsMetric: [AnalyticsReading]], workouts: [WorkoutRecord], analysis: RecoveryAnalysis,
                         now: Date = Date(), calendar: Calendar = .current) -> [AnalyticsHighlight] {
    var events: [AnalyticsHighlight] = []
    for point in compare(series[.recovery] ?? [], scale: .percent, calendar: calendar) {
      if let baseline = point.baseline, point.raw <= baseline - 15 {
        events.append(.init(id: "recovery-\(point.date)", kind: .recovery, start: point.date, end: point.date,
          title: "Recovery below recent baseline", detail: "\(Int(point.raw))/100 vs \(Int(baseline.rounded())) across \(point.observations) prior recorded dates; at least 15 points lower."))
      }
    }
    let signals = [AnalyticsMetric.sleep, .hrv, .restingHR].map { metric in
      Dictionary(uniqueKeysWithValues: compare(series[metric] ?? [], scale: .percent, calendar: calendar).map { ($0.date, $0.value) })
    }
    let dates = Set(signals.flatMap { $0.keys })
    for date in dates {
      var labels: [String] = []
      if let value = signals[0][date], value <= -20 { labels.append("sleep ≥20% lower") }
      if let value = signals[1][date], value <= -20 { labels.append("HRV ≥20% lower") }
      if let value = signals[2][date], value >= 10 { labels.append("resting HR ≥10% higher") }
      if labels.count >= 2 { events.append(.init(id: "signals-\(date)", kind: .signals, start: date, end: date,
        title: "Several recovery signals shifted", detail: labels.joined(separator: "; ") + " vs prior observed baselines. Many causes are possible.")) }
    }
    for workout in workouts where workout.end <= now && (workout.minutes >= 120 || (workout.appleEffort ?? 0) >= 8 || (workout.activityType == .running && (workout.distanceKm ?? 0) >= 42.195)) {
      let date = calendar.startOfDay(for: workout.start)
      events.append(.init(id: "effort-\(workout.id)", kind: .effort, start: date, end: calendar.startOfDay(for: workout.end),
        title: workout.title, detail: "\(Int(workout.minutes)) min" + (workout.appleEffort.map { String(format: " · Apple effort %.1f/10", $0) } ?? "") + ". Marked for long duration, high effort or a marathon-distance run."))
    }
    for point in analysis.history where point.coverage < 0.5 {
      events.append(.init(id: "coverage-\(point.date)", kind: .coverage, start: point.date, end: point.date,
        title: "Limited recovery data", detail: "\(Int((point.coverage * 100).rounded()))% of configured input weights available. Missing data does not imply poor recovery."))
    }
    var merged: [AnalyticsHighlight] = []
    for event in events.sorted(by: { $0.kind.rawValue == $1.kind.rawValue ? $0.start < $1.start : $0.kind.rawValue < $1.kind.rawValue }) {
      if event.kind != .effort, let previous = merged.last, previous.kind == event.kind,
        calendar.date(byAdding: .day, value: 1, to: previous.end) == event.start {
        merged[merged.count - 1].end = event.end; merged[merged.count - 1].detail = "Consecutive dates with this pattern. Latest: " + event.detail
      } else { merged.append(event) }
    }
    return merged.sorted { $0.end > $1.end }
  }
}
