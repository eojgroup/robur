import Foundation

enum TimelineGrain: String, CaseIterable, Identifiable {
  case day = "Daily", week = "Weekly", month = "Monthly"
  var id: String { rawValue }
  var component: Calendar.Component {
    switch self { case .day: return .day; case .week: return .weekOfYear; case .month: return .month }
  }
}

enum RecoverySignal: String, CaseIterable, Identifiable {
  case sleep = "Sleep", hrv = "HRV", restingHR = "Resting HR"
  var id: String { rawValue }
  var unit: String { self == .sleep ? "min" : self == .hrv ? "ms" : "bpm" }
  var key: KeyPath<DailyHealthMetrics, Double?> {
    switch self { case .sleep: return \.sleepMinutes; case .hrv: return \.hrv; case .restingHR: return \.restingHR }
  }
}

struct TimelineRecovery: Identifiable {
  var id: Date { date }
  let date: Date
  let signal: RecoverySignal
  let value: Double
  let baseline: Double?
  let baselineDays: Int
  var changePercent: Double? { baseline.map { (value / $0 - 1) * 100 } }
}

struct TrainingTimelineBucket: Identifiable {
  var id: Date { date }
  let date: Date
  let minutes: Double?
  let appleLoad: Double?
  let sessions: Int
  let ratedSessions: Int
  let recoveryValue: Double?
  let recoveryChange: Double?
  let recoveryBaseline: Double?
  let recoveryDays: Int
  let segment: Int
}

struct TrainingTimelineEvent: Identifiable {
  enum Kind: String {
    case marathon = "Marathon distance", longSession = "Long session", highEffort = "High effort"
    case longest = "Longest session", poorSleep = "Low sleep", lowHRV = "Low HRV", highRestingHR = "Elevated resting HR"
    var isWorkout: Bool {
      switch self { case .marathon, .longSession, .highEffort, .longest: return true; default: return false }
    }
    var symbol: String {
      switch self {
      case .marathon: return "figure.run"
      case .longSession, .longest: return "clock"
      case .highEffort: return "bolt.heart"
      case .poorSleep: return "bed.double"
      case .lowHRV, .highRestingHR: return "waveform.path.ecg"
      }
    }
  }
  let id: String
  let date: Date
  let kind: Kind
  let detail: String
  let workoutID: String?
}

struct TrainingTimelineSummary {
  let buckets: [TrainingTimelineBucket]
  let recovery: [TimelineRecovery]
  let events: [TrainingTimelineEvent]
}

enum TrainingTimeline {
  /// Measurements stay on their recorded date. Each baseline uses only prior days;
  /// missing recovery or imported effort remains absent rather than becoming zero.
  static func make(workouts: [WorkoutRecord], days: [DailyHealthMetrics], signal: RecoverySignal = .sleep,
                   grain: TimelineGrain = .week, start: Date? = nil, now: Date = Date(),
                   calendar: Calendar = .current) -> TrainingTimelineSummary {
    var seen: Set<String> = []
    let sessions = workouts.filter {
      $0.start <= now && $0.minutes.isFinite && $0.minutes > 0 && seen.insert($0.id).inserted
    }.sorted { $0.start < $1.start }
    // Daily Health import already supplies one record per day; normalize dates for callers.
    var daily: [Date: DailyHealthMetrics] = [:]
    for day in days.sorted(by: { $0.date < $1.date }) where day.date <= now {
      daily[calendar.startOfDay(for: day.date)] = day
    }
    let dates = daily.keys.sorted()
    var observations: [RecoverySignal: [TimelineRecovery]] = [:]
    var events: [TrainingTimelineEvent] = []
    for metric in RecoverySignal.allCases {
      var history: [(Date, Double)] = []
      var first = 0
      for date in dates {
        guard let day = daily[date], let value = positive(day[keyPath: metric.key]) else { continue }
        let lower = calendar.date(byAdding: .day, value: -30, to: date) ?? date
        while first < history.count && history[first].0 < lower { first += 1 }
        let prior = history[first...].map(\.1)
        let baseline = prior.count >= 7 ? mean(prior) : nil
        let reading = TimelineRecovery(date: date, signal: metric, value: value, baseline: baseline, baselineDays: prior.count)
        observations[metric, default: []].append(reading)
        if let change = reading.changePercent {
          let kind: TrainingTimelineEvent.Kind?
          switch metric {
          case .sleep: kind = change <= -20 ? .poorSleep : nil
          case .hrv: kind = change <= -20 ? .lowHRV : nil
          case .restingHR: kind = change >= 10 ? .highRestingHR : nil
          }
          if let kind, start.map({ date >= calendar.startOfDay(for: $0) }) ?? true {
            events.append(TrainingTimelineEvent(id: "\(metric.rawValue)-\(date.timeIntervalSince1970)", date: date,
              kind: kind, detail: "\(Int(value.rounded())) \(metric.unit) · \(String(format: "%+.0f%%", change)) vs prior 30d", workoutID: nil))
          }
        }
        history.append((date, value))
      }
    }
    let displayed = sessions.filter { workout in start.map { workout.start >= $0 } ?? true }
    let longest = displayed.max { $0.minutes < $1.minutes }
    for workout in displayed {
      var kinds: [TrainingTimelineEvent.Kind] = []
      if workout.activityType == .running, let km = positive(workout.distanceKm), km >= 42.195 { kinds.append(.marathon) }
      if workout.minutes >= 120 { kinds.append(.longSession) }
      if let effort = appleEffort(workout), effort >= 8 { kinds.append(.highEffort) }
      if workout.id == longest?.id { kinds.append(.longest) }
      // One marker per session, with the most informative classification first.
      if let kind = kinds.first {
        let distance = positive(workout.distanceKm).map { String(format: " · %.1f km", $0) } ?? ""
        let effort = appleEffort(workout).map { String(format: " · effort %.1f", $0) } ?? ""
        let longestLabel = kinds.contains(.longest) && kind != .longest ? " · longest session" : ""
        events.append(TrainingTimelineEvent(id: workout.id, date: workout.start, kind: kind,
          detail: "\(workout.title) · \(Int(workout.minutes)) min\(distance)\(effort)\(longestLabel)", workoutID: workout.id))
      }
    }
    let recovery = (observations[signal] ?? []).filter { reading in start.map { reading.date >= calendar.startOfDay(for: $0) } ?? true }
    func period(_ date: Date) -> Date { calendar.dateInterval(of: grain.component, for: date)?.start ?? date }
    let workoutsByPeriod = Dictionary(grouping: displayed) { period($0.start) }
    let recoveryByPeriod = Dictionary(grouping: recovery) { period($0.date) }
    let periodDates = Set(workoutsByPeriod.keys).union(recoveryByPeriod.keys).sorted()
    var segment = 0
    var previousRecovery: Date?
    let buckets = periodDates.map { date -> TrainingTimelineBucket in
      let workouts = workoutsByPeriod[date] ?? []
      let readings = recoveryByPeriod[date] ?? []
      let loads = workouts.compactMap { workout in appleEffort(workout).map { $0 * workout.minutes } }
      if !readings.isEmpty {
        if let previousRecovery,
           calendar.dateInterval(of: grain.component, for: previousRecovery)?.end != date { segment += 1 }
        previousRecovery = date
      }
      return TrainingTimelineBucket(date: date, minutes: workouts.isEmpty ? nil : workouts.reduce(0) { $0 + $1.minutes },
        appleLoad: loads.isEmpty ? nil : loads.reduce(0, +), sessions: workouts.count, ratedSessions: loads.count,
        recoveryValue: mean(readings.map(\.value)), recoveryChange: mean(readings.compactMap(\.changePercent)),
        recoveryBaseline: mean(readings.compactMap(\.baseline)),
        recoveryDays: readings.count, segment: segment)
    }
    return TrainingTimelineSummary(buckets: buckets, recovery: recovery,
      events: events.sorted { $0.date == $1.date ? $0.id < $1.id : $0.date < $1.date })
  }

  static func appleEffort(_ workout: WorkoutRecord) -> Double? {
    workout.appleEffort.flatMap { $0.isFinite && (1...10).contains($0) ? $0 : nil }
  }
  private static func positive(_ value: Double?) -> Double? { value.flatMap { $0.isFinite && $0 > 0 ? $0 : nil } }
  private static func mean(_ values: [Double]) -> Double? { values.isEmpty ? nil : values.reduce(0, +) / Double(values.count) }
}
