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
  var appleEffort: Double? = nil
  var heartRateSamples: [WorkoutHeartSample] = []
  var splits: [WorkoutSplit] = []
  var cadence: Double? = nil
}

struct FitnessReading: Identifiable, Hashable {
  let id: String
  let date: Date
  let value: Double
  let metric: FitnessMetric
}

enum FitnessMetric: String, CaseIterable, Identifiable {
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
  var automatic: Bool? = nil
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

// Region monitoring supports at most 20 saved places per app. Preserve save order.
enum GymMonitoringPlan {
  static func locations(_ gyms: [GymLocation]) -> [GymLocation] {
    Array(gyms.filter { gym in
      guard let lat = gym.latitude, let lon = gym.longitude else { return false }
      return lat.isFinite && lon.isFinite && (-90...90).contains(lat) && (-180...180).contains(lon)
    }.prefix(20))
  }
}

// Shared by the Health importer and boundary tests; calendar days may be 23/25 hours.
enum HealthImportMath {
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
