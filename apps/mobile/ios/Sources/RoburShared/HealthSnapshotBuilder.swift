import Foundation

struct HealthMetrics: Hashable {
  let sleepMinutes: Int?
  let restingHeartRateBpm: Double?
  let heartRateVariabilityMs: Double?
  let runningKm: Double?
  let cyclingKm: Double?
  let strengthSessions: Int
  let trainingMinutes: Int
  let workoutCount: Int

  var hasData: Bool {
    sleepMinutes != nil ||
      restingHeartRateBpm != nil ||
      heartRateVariabilityMs != nil ||
      (runningKm ?? 0) > 0 ||
      (cyclingKm ?? 0) > 0 ||
      workoutCount > 0
  }

  var hasRecoveryData: Bool {
    sleepMinutes != nil || restingHeartRateBpm != nil || heartRateVariabilityMs != nil
  }
}

enum HealthSnapshotBuilder {
  static func makeSnapshot(from metrics: HealthMetrics) -> FitnessSnapshot {
    guard metrics.hasData else {
      return RoburData.noHealthData
    }

    let sleepMinutes = metrics.sleepMinutes ?? 0
    let restingHeartRate = Int((metrics.restingHeartRateBpm ?? 0).rounded())
    let heartRateVariability = Int((metrics.heartRateVariabilityMs ?? 0).rounded())
    let runningKm = metrics.runningKm ?? 0
    let cyclingKm = metrics.cyclingKm ?? 0

    let recoveryScore = recoveryScore(
      sleepMinutes: metrics.sleepMinutes,
      restingHeartRateBpm: metrics.restingHeartRateBpm,
      heartRateVariabilityMs: metrics.heartRateVariabilityMs
    )
    let trainingLoad = trainingLoad(
      trainingMinutes: metrics.trainingMinutes,
      runningKm: runningKm,
      cyclingKm: cyclingKm,
      strengthSessions: metrics.strengthSessions
    )

    return FitnessSnapshot(
      recoveryScore: recoveryScore,
      trainingLoad: trainingLoad,
      sleepMinutes: sleepMinutes,
      restingHeartRateBpm: restingHeartRate,
      heartRateVariabilityMs: heartRateVariability,
      recommendation: recommendation(
        hasRecoveryData: metrics.hasRecoveryData,
        recoveryScore: recoveryScore,
        trainingLoad: trainingLoad
      ),
      week: WeekTotals(
        runningKm: runningKm,
        cyclingKm: cyclingKm,
        strengthSessions: metrics.strengthSessions,
        trainingMinutes: metrics.trainingMinutes
      )
    )
  }

  private static func recoveryScore(
    sleepMinutes: Int?,
    restingHeartRateBpm: Double?,
    heartRateVariabilityMs: Double?
  ) -> Int {
    var weightedScore = 0.0
    var totalWeight = 0.0

    if let sleepMinutes {
      weightedScore += min(max(Double(sleepMinutes) / 480, 0), 1) * 45
      totalWeight += 45
    }

    if let restingHeartRateBpm {
      let normalized = min(max((70 - restingHeartRateBpm) / 25, 0), 1)
      weightedScore += normalized * 25
      totalWeight += 25
    }

    if let heartRateVariabilityMs {
      weightedScore += min(max(heartRateVariabilityMs / 70, 0), 1) * 30
      totalWeight += 30
    }

    guard totalWeight > 0 else {
      return 0
    }

    return Int((weightedScore / totalWeight * 100).rounded())
  }

  private static func trainingLoad(
    trainingMinutes: Int,
    runningKm: Double,
    cyclingKm: Double,
    strengthSessions: Int
  ) -> Int {
    let durationComponent = min(Double(trainingMinutes) / 420, 1) * 60
    let distanceComponent = min((runningKm + cyclingKm) / 150, 1) * 25
    let strengthComponent = min(Double(strengthSessions) / 3, 1) * 15

    return Int((durationComponent + distanceComponent + strengthComponent).rounded())
  }

  private static func recommendation(
    hasRecoveryData: Bool,
    recoveryScore: Int,
    trainingLoad: Int
  ) -> FitnessRecommendation {
    if !hasRecoveryData {
      return FitnessRecommendation(
        title: "More recovery data needed",
        durationMinutesMin: 0,
        durationMinutesMax: 0,
        zone: 0,
        rationale: "Robur found activity data, but needs approved sleep, resting heart rate, or HRV to estimate today's training recommendation."
      )
    }

    if recoveryScore < 45 {
      return FitnessRecommendation(
        title: "Recovery focus",
        durationMinutesMin: 20,
        durationMinutesMax: 30,
        zone: 1,
        rationale: "Your available sleep and heart metrics suggest keeping today's effort gentle."
      )
    }

    if trainingLoad > 75 {
      return FitnessRecommendation(
        title: "Easy aerobic",
        durationMinutesMin: 30,
        durationMinutesMax: 45,
        zone: 2,
        rationale: "Your weekly volume is high, so keep the next session comfortably aerobic."
      )
    }

    return FitnessRecommendation(
      title: "Easy aerobic",
      durationMinutesMin: 40,
      durationMinutesMax: 55,
      zone: 2,
      rationale: "Your available Health data supports a moderate, easy aerobic session today."
    )
  }
}
