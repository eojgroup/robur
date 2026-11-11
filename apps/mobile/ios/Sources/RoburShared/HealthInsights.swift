import Foundation

struct WorkoutHeartSample: Hashable, Sendable {
  let date: Date
  let bpm: Double
}

struct WorkoutSplit: Hashable, Identifiable, Sendable {
  var id: Int { index }
  let index: Int
  let minutes: Double
  let distanceKm: Double
}

struct DailyHealthMetrics: Identifiable, Hashable, Sendable {
  var id: Date { date }
  let date: Date
  var sleepMinutes: Double? = nil
  var steps: Double? = nil
  var exerciseMinutes: Double? = nil
  var standMinutes: Double? = nil
  var activeEnergyKcal: Double? = nil
  var restingHR: Double? = nil
  var hrv: Double? = nil
  var vo2Max: Double? = nil
  var weightKg: Double? = nil
  var respiratoryRate: Double? = nil
  var oxygenSaturation: Double? = nil
  var bodyFatPercent: Double? = nil
  var bmi: Double? = nil
  var heightCm: Double? = nil
}

struct HealthProfile: Equatable {
  var age: Int? = nil
  var biologicalSex: String? = nil
  var bloodType: String? = nil
  var heightCm: Double? = nil
  var weightKg: Double? = nil
  var bodyFatPercent: Double? = nil
  var bmi: Double? = nil
}
