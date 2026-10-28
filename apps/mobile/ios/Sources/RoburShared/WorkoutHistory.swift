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

enum MuscleGroup: String, CaseIterable, Codable, Identifiable {
  case chest = "Chest", back = "Back", shoulders = "Shoulders", arms = "Arms"
  case core = "Core", quads = "Quads", hamstrings = "Hamstrings", glutes = "Glutes", calves = "Calves"
  var id: String { rawValue }
}

struct WorkoutRecord: Identifiable, Hashable {
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
}

struct FitnessReading: Identifiable, Hashable {
  let id: String
  let date: Date
  let value: Double
  let metric: FitnessMetric
}

enum FitnessMetric: String, CaseIterable, Identifiable {
  case cardio = "Cardio fitness", restingHR = "Resting HR", hrv = "HRV"
  var id: String { rawValue }
  var unit: String {
    switch self {
    case .cardio: return "mL/kg/min"
    case .restingHR: return "bpm"
    case .hrv: return "ms"
    }
  }
  var explanation: String {
    switch self {
    case .cardio: return "Apple Health VO₂ max estimates, when available. Only compatible activities and devices produce these estimates."
    case .restingHR: return "Your recorded resting heart rate. Compare your own longer-term trend rather than individual readings."
    case .hrv: return "Heart rate variability (SDNN). Timing, sleep and measurement conditions can affect these readings."
    }
  }
}

struct WorkoutAnnotation: Codable, Equatable {
  var muscles: Set<MuscleGroup> = []
  var effort: Int? = nil
  var gymID: UUID? = nil
  var notes = ""
}

struct GymLocation: Codable, Identifiable, Equatable {
  var id = UUID()
  var name: String
  var latitude: Double?
  var longitude: Double?
}

struct GymVisit: Codable, Identifiable, Equatable {
  var id = UUID()
  let gymID: UUID
  let start: Date
  var end: Date?
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
      if let effort = annotations[workout.id]?.effort, (1...10).contains(effort) {
        bucket.load += workout.minutes * Double(effort)
        bucket.ratedWorkouts += 1
      }
      result[date] = bucket
    }
    return result.values.sorted { $0.date < $1.date }
  }

  static func trend(readings: [FitnessReading], metric: FitnessMetric,
                    calendar: Calendar = .current, monthly: Bool = false) -> [TrendPoint] {
    let grouped = Dictionary(grouping: readings.filter { $0.metric == metric && $0.value.isFinite && $0.value > 0 }) {
      calendar.dateInterval(of: monthly ? .month : .weekOfYear, for: $0.date)?.start ?? $0.date
    }
    return grouped.map { date, samples in
      TrendPoint(date: date, value: samples.reduce(0) { $0 + $1.value } / Double(samples.count))
    }.sorted { $0.date < $1.date }
  }
}
