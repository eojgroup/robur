import Foundation

enum HistoryRange: String, CaseIterable, Identifiable {
  case month = "30 days", quarter = "90 days", year = "1 year", all = "All history"
  var id: String { rawValue }
  func startDate(now: Date = Date(), calendar: Calendar = .current) -> Date? {
    switch self {
    case .month: return calendar.date(byAdding: .day, value: -30, to: now)
    case .quarter: return calendar.date(byAdding: .day, value: -90, to: now)
    case .year: return calendar.date(byAdding: .year, value: -1, to: now)
    case .all: return nil
    }
  }
}

enum MuscleGroup: String, CaseIterable, Codable, Identifiable, Sendable {
  case chest = "Chest", back = "Back", shoulders = "Shoulders", arms = "Arms"
  case core = "Core", quads = "Quads", hamstrings = "Hamstrings", glutes = "Glutes", calves = "Calves"
  var id: String { rawValue }
}

enum WorkoutEffortSource: String, Hashable, Codable, Sendable {
  case reported, estimated
  var title: String {
    switch self {
    case .reported: return "Apple Fitness rating"
    case .estimated: return "Apple estimated effort"
    }
  }
}

struct WorkoutEffortCandidate: Hashable {
  let score: Double
  let source: WorkoutEffortSource
  let date: Date
  var activityID: String? = nil
  var durationMinutes: Double? = nil
  var sampleID: String = ""
}

struct WorkoutEffortSelection: Hashable {
  let score: Double
  let source: WorkoutEffortSource
}

struct WorkoutRecord: Identifiable, Hashable, Sendable {
  let id: String
  let start: Date
  let end: Date
  let title: String
  let symbol: String
  let minutes: Double
  let distanceKm: Double?
  let energyKcal: Double?
  let averageHeartRate: Double?
  let source: String
  var appleEffort: Double? = nil
  var heartRateSamples: [WorkoutHeartSample] = []
  var splits: [WorkoutSplit] = []
  var cadence: Double? = nil
  var effortSource: WorkoutEffortSource? = nil
  var activityType: WorkoutActivity = .other
}

struct FitnessReading: Identifiable, Hashable {
  let id: String
  let date: Date
  let value: Double
  let metric: FitnessMetric
}

enum FitnessMetric: String, CaseIterable, Identifiable, Sendable {
  case cardio = "Cardio fitness", restingHR = "Resting HR", hrv = "HRV"
  case weight = "Weight", bodyFat = "Body fat", bmi = "BMI", height = "Height"
  case steps = "Steps", exercise = "Exercise", stand = "Stand time", energy = "Active energy", sleep = "Sleep"
  case respiratoryRate = "Respiratory rate", oxygenSaturation = "Blood oxygen"
  var id: String { rawValue }
  var unit: String {
    switch self {
    case .cardio: return "mL/kg/min"
    case .restingHR: return "bpm"
    case .hrv: return "ms"
    case .weight: return "kg"
    case .bodyFat, .oxygenSaturation: return "%"
    case .bmi: return "kg/m²"
    case .height: return "cm"
    case .steps: return "steps"
    case .exercise, .stand, .sleep: return "min"
    case .energy: return "kcal"
    case .respiratoryRate: return "breaths/min"
    }
  }
  var explanation: String {
    switch self {
    case .cardio: return "Apple Health VO₂ max estimates, when available. Only compatible activities and devices produce these estimates."
    case .restingHR: return "Your recorded resting heart rate. Compare your own longer-term trend rather than individual readings."
    case .hrv: return "Heart rate variability (SDNN). Timing, sleep and measurement conditions can affect these readings."
    case .weight: return "Recorded body mass from Apple Health. Missing days are not filled with guessed values."
    case .bodyFat: return "Recorded body-fat percentage. Compare measurements from the same source and conditions."
    case .bmi: return "Recorded body mass index, when shared. BMI does not measure body composition."
    case .height: return "Your recorded height from Apple Health."
    case .steps: return "Daily steps, aggregated by HealthKit across approved sources."
    case .exercise: return "Daily Apple Exercise Time, when recorded by a compatible device."
    case .stand: return "Apple Stand Time in minutes, not the number of stand hours."
    case .energy: return "Daily active energy recorded in Apple Health."
    case .sleep: return "Daily recorded asleep minutes, with overlapping intervals merged."
    case .respiratoryRate: return "Recorded respiratory rate. This view is for personal trends, not diagnosis."
    case .oxygenSaturation: return "Recorded blood oxygen saturation, when available and shared."
    }
  }
}

struct WorkoutAnnotation: Codable, Equatable, Sendable {
  var muscles: Set<MuscleGroup> = []
  var effort: Int? = nil
  var notes = ""
  var quickReview: WorkoutQuickReview? = nil
}

struct HistoryBucket: Identifiable, Equatable {
  var id: Date { date }
  let date: Date
  var minutes: Double = 0
  var workouts: Int = 0
  var load: Double = 0
  var ratedWorkouts: Int = 0
}

struct TrendPoint: Identifiable {
  var id: Date { date }
  let date: Date
  let value: Double
}

enum WorkoutAnalytics {
  static func buckets(workouts: [WorkoutRecord], annotations: [String: WorkoutAnnotation],
                      calendar: Calendar = .current, monthly: Bool = false) -> [HistoryBucket] {
    var result: [Date: HistoryBucket] = [:]
    for workout in workouts {
      let component: Calendar.Component = monthly ? .month : .weekOfYear
      let date = calendar.dateInterval(of: component, for: workout.start)?.start ?? workout.start
      var bucket = result[date] ?? HistoryBucket(date: date)
      bucket.minutes += workout.minutes
      bucket.workouts += 1
      let effort = workout.appleEffort ?? annotations[workout.id]?.effort.map(Double.init)
      if let effort, effort.isFinite, (1...10).contains(effort) {
        bucket.load += workout.minutes * effort
        bucket.ratedWorkouts += 1
      }
      result[date] = bucket
    }
    return result.values.sorted { $0.date < $1.date }
  }

  static func trend(readings: [FitnessReading], metric: FitnessMetric,
                    calendar: Calendar = .current, monthly: Bool = false) -> [TrendPoint] {
    let grouped = Dictionary(grouping: readings.filter { $0.metric == metric && $0.value.isFinite && $0.value >= 0 }) {
      calendar.dateInterval(of: monthly ? .month : .weekOfYear, for: $0.date)?.start ?? $0.date
    }
    return grouped.map { date, samples in
      TrendPoint(date: date, value: samples.reduce(0) { $0 + $1.value } / Double(samples.count))
    }.sorted { $0.date < $1.date }
  }
}

// HealthKit relationship queries can deliver later updates; their async snapshot
// adapter must complete exactly once, even if callbacks race with cancellation.
final class HealthQueryCompletionGate: @unchecked Sendable {
  private let lock = NSLock()
  private var completed = false
  func claim() -> Bool {
    lock.lock()
    defer { lock.unlock() }
    guard !completed else { return false }
    completed = true
    return true
  }
}

// Shared by the Health importer and boundary tests; calendar days may be 23/25 hours.
enum HealthImportMath {
  /// A user rating wins over any estimate, even a newer estimate. A whole-workout
  /// rating wins within that source; otherwise average latest ratings per activity.
  static func effort(_ candidates: [WorkoutEffortCandidate]) -> WorkoutEffortSelection? {
    let valid = candidates.filter { $0.score.isFinite && (1...10).contains($0.score) }
    guard !valid.isEmpty, !hasAmbiguousEffort(valid) else { return nil }
    let source: WorkoutEffortSource = valid.contains { $0.source == .reported } ? .reported : .estimated
    let preferred = valid.filter { $0.source == source }.sorted {
      if $0.date != $1.date { return $0.date > $1.date }
      if $0.sampleID != $1.sampleID { return $0.sampleID < $1.sampleID }
      return $0.score < $1.score
    }
    if let whole = preferred.first(where: { $0.activityID == nil }) {
      return WorkoutEffortSelection(score: whole.score, source: source)
    }
    var latest: [String: WorkoutEffortCandidate] = [:]
    for sample in preferred {
      if let activity = sample.activityID, latest[activity] == nil { latest[activity] = sample }
    }
    let samples = latest.keys.sorted().compactMap { latest[$0] }
    let weighted = samples.allSatisfy { ($0.durationMinutes ?? 0).isFinite && ($0.durationMinutes ?? 0) > 0 }
    let weights = samples.map { weighted ? ($0.durationMinutes ?? 1) : 1 }
    let total = weights.reduce(0, +)
    guard total > 0 else { return nil }
    let value = zip(samples, weights).reduce(0.0) { $0 + $1.0.score * $1.1 } / total
    return WorkoutEffortSelection(score: value, source: source)
  }

  /// endDate is measurement time, not edit time. Conflicting values from the
  /// same scope/time cannot be ordered by UUID as a proxy for a current rating.
  static func hasAmbiguousEffort(_ candidates: [WorkoutEffortCandidate]) -> Bool {
    let valid = candidates.filter { $0.score.isFinite && (1...10).contains($0.score) }
    let source: WorkoutEffortSource = valid.contains { $0.source == .reported } ? .reported : .estimated
    let preferred = valid.filter { $0.source == source }
    let whole = preferred.filter { $0.activityID == nil }
    let groups = whole.isEmpty ? Array(Dictionary(grouping: preferred, by: { $0.activityID }).values) : [whole]
    return groups.contains { samples in
      guard let latestDate = samples.map(\.date).max() else { return false }
      return Set(samples.filter { $0.date == latestDate }.map(\.score)).count > 1
    }
  }

  static func fallbackEffort(cached: WorkoutEffortSelection?, candidates: [WorkoutEffortCandidate]) -> WorkoutEffortSelection? {
    if cached?.source == .reported { return cached }
    return effort(candidates)
  }

  static func sleepMinutes(intervals: [DateInterval], calendar: Calendar, wakingDay: Bool = false) -> [Date: Double] {
    let sorted = intervals.filter { $0.duration > 0 }.sorted { $0.start < $1.start }
    var merged: [DateInterval] = []
    for interval in sorted {
      if let previous = merged.last, interval.start <= previous.end {
        merged[merged.count - 1] = DateInterval(start: previous.start, end: max(previous.end, interval.end))
      } else { merged.append(interval) }
    }
    var result: [Date: Double] = [:]
    for interval in merged {
      var cursor = interval.start
      while cursor < interval.end {
        var day = calendar.startOfDay(for: cursor)
        let nextDay: Date
        if wakingDay {
          // Noon-to-noon windows retain a whole overnight sleep on its waking date.
          // A midnight split would compare only part of today's night with a full baseline day.
          if calendar.component(.hour, from: cursor) >= 12 {
            guard let following = calendar.date(byAdding: .day, value: 1, to: day) else { break }
            day = following
          }
          guard let noon = calendar.date(bySettingHour: 12, minute: 0, second: 0, of: day) else { break }
          nextDay = noon
        } else {
          guard let following = calendar.date(byAdding: .day, value: 1, to: day) else { break }
          nextDay = following
        }
        let boundary = min(nextDay, interval.end)
        result[day, default: 0] += boundary.timeIntervalSince(cursor) / 60
        cursor = boundary
      }
    }
    return result
  }
}
