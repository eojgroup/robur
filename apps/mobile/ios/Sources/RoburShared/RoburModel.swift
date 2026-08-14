import Foundation
import SwiftUI

enum TrainingFocus: String, CaseIterable, Identifiable {
  case running
  case cycling
  case strength
  case mobility
  case recovery

  var id: String { rawValue }

  var title: String {
    switch self {
    case .running: return "Running"
    case .cycling: return "Cycling"
    case .strength: return "Strength"
    case .mobility: return "Mobility"
    case .recovery: return "Recovery"
    }
  }

  var tint: Color {
    switch self {
    case .running: return Color(red: 0.18, green: 0.70, blue: 0.49)
    case .cycling: return Color(red: 0.25, green: 0.49, blue: 0.67)
    case .strength: return Color(red: 1.00, green: 0.44, blue: 0.38)
    case .mobility: return Color(red: 0.85, green: 0.63, blue: 0.23)
    case .recovery: return Color(red: 0.24, green: 0.73, blue: 0.64)
    }
  }
}

struct TrainingSession: Identifiable, Hashable {
  let id: String
  let day: String
  let title: String
  let focus: TrainingFocus
  let durationMinutes: Int
  let intensity: Int
  let heartRateZone: Int
  let movements: [String]
}

struct FitnessRecommendation: Hashable {
  let title: String
  let durationMinutesMin: Int
  let durationMinutesMax: Int
  let zone: Int
  let rationale: String

  var prescription: String {
    "\(durationMinutesMin)-\(durationMinutesMax) min / Zone \(zone)"
  }
}

struct WeekTotals: Hashable {
  let runningKm: Double
  let cyclingKm: Double
  let strengthSessions: Int
  let trainingMinutes: Int
}

struct FitnessSnapshot: Hashable {
  let recoveryScore: Int
  let trainingLoad: Int
  let sleepMinutes: Int
  let restingHeartRateBpm: Int
  let heartRateVariabilityMs: Int
  let recommendation: FitnessRecommendation
  let week: WeekTotals
}

enum RoburData {
  static let appName = "Robur"

  static let today = FitnessSnapshot(
    recoveryScore: 82,
    trainingLoad: 64,
    sleepMinutes: 468,
    restingHeartRateBpm: 48,
    heartRateVariabilityMs: 71,
    recommendation: FitnessRecommendation(
      title: "Easy aerobic",
      durationMinutesMin: 40,
      durationMinutesMax: 55,
      zone: 2,
      rationale: "Your recovery is above baseline, but 7-day running load is +18%."
    ),
    week: WeekTotals(
      runningKm: 38.4,
      cyclingKm: 112,
      strengthSessions: 2,
      trainingMinutes: 402
    )
  )

  static let starterPlan: [TrainingSession] = [
    TrainingSession(
      id: "monday-easy-aerobic",
      day: "Mon",
      title: "Easy Aerobic",
      focus: .running,
      durationMinutes: 45,
      intensity: 2,
      heartRateZone: 2,
      movements: ["Warmup walk", "Zone 2 run", "Cooldown walk", "Mobility reset"]
    ),
    TrainingSession(
      id: "tuesday-strength",
      day: "Tue",
      title: "Lower Strength",
      focus: .strength,
      durationMinutes: 46,
      intensity: 4,
      heartRateZone: 3,
      movements: ["Back squat", "Romanian deadlift", "Walking lunge", "Calf raise"]
    )
  ]

  static func duration(_ minutes: Int) -> String {
    let hours = minutes / 60
    let remainder = minutes % 60

    if hours == 0 {
      return "\(remainder)m"
    }

    return remainder == 0 ? "\(hours)h" : "\(hours)h \(remainder)m"
  }
}
