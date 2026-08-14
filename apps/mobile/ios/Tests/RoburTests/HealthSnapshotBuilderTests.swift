import XCTest

@testable import Robur

final class HealthSnapshotBuilderTests: XCTestCase {
  func testReturnsExplicitEmptyStateWhenNoHealthDataExists() {
    let snapshot = HealthSnapshotBuilder.makeSnapshot(
      from: HealthMetrics(
        sleepMinutes: nil,
        restingHeartRateBpm: nil,
        heartRateVariabilityMs: nil,
        runningKm: nil,
        cyclingKm: nil,
        strengthSessions: 0,
        trainingMinutes: 0,
        workoutCount: 0
      )
    )

    XCTAssertEqual(snapshot, RoburData.noHealthData)
    XCTAssertEqual(snapshot.recommendation.prescription, "Awaiting Health data")
  }

  func testBuildsRecommendationFromApprovedHealthMetrics() {
    let snapshot = HealthSnapshotBuilder.makeSnapshot(
      from: HealthMetrics(
        sleepMinutes: 450,
        restingHeartRateBpm: 52,
        heartRateVariabilityMs: 60,
        runningKm: 10.2,
        cyclingKm: 31.2,
        strengthSessions: 2,
        trainingMinutes: 180,
        workoutCount: 3
      )
    )

    XCTAssertGreaterThan(snapshot.recoveryScore, 50)
    XCTAssertGreaterThan(snapshot.trainingLoad, 0)
    XCTAssertEqual(snapshot.sleepMinutes, 450)
    XCTAssertEqual(snapshot.restingHeartRateBpm, 52)
    XCTAssertEqual(snapshot.heartRateVariabilityMs, 60)
    XCTAssertEqual(snapshot.week.runningKm, 10.2, accuracy: 0.001)
    XCTAssertEqual(snapshot.week.cyclingKm, 31.2, accuracy: 0.001)
    XCTAssertEqual(snapshot.week.strengthSessions, 2)
    XCTAssertEqual(snapshot.week.trainingMinutes, 180)
    XCTAssertNotEqual(snapshot.recommendation.prescription, "Awaiting Health data")
  }

  func testCyclingDistanceWithoutAWorkoutStillCountsAsHealthData() {
    let snapshot = HealthSnapshotBuilder.makeSnapshot(
      from: HealthMetrics(
        sleepMinutes: nil,
        restingHeartRateBpm: nil,
        heartRateVariabilityMs: nil,
        runningKm: nil,
        cyclingKm: 24.5,
        strengthSessions: 0,
        trainingMinutes: 0,
        workoutCount: 0
      )
    )

    XCTAssertEqual(snapshot.week.cyclingKm, 24.5, accuracy: 0.001)
    XCTAssertEqual(snapshot.recommendation.title, "More recovery data needed")
  }
}
