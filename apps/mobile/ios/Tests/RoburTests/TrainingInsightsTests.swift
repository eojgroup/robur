import XCTest
@testable import Robur

final class TrainingInsightsTests: XCTestCase {
  private var calendar: Calendar {
    var calendar = Calendar(identifier: .iso8601)
    calendar.timeZone = TimeZone(secondsFromGMT: 0)!
    return calendar
  }
  private let now = ISO8601DateFormatter().date(from: "2026-10-29T12:00:00Z")!
  private func day(_ offset: Int) -> Date { calendar.date(byAdding: .day, value: offset, to: calendar.startOfDay(for: now))! }
  private func workout(_ id: String, offset: Int = 0, minutes: Double = 30, effort: Double? = nil,
                       heartRate: Double? = nil, distance: Double? = nil) -> WorkoutRecord {
    WorkoutRecord(id: id, start: day(offset), end: day(offset).addingTimeInterval(minutes * 60), title: "Run",
      symbol: "figure.run", minutes: minutes, distanceKm: distance, energyKcal: nil,
      averageHeartRate: heartRate, source: "Test", appleEffort: effort)
  }
  private func summary(days: [DailyHealthMetrics] = [], workouts: [WorkoutRecord] = [],
                       annotations: [String: WorkoutAnnotation] = [:]) -> InsightsSummary {
    TrainingInsights.make(days: days, workouts: workouts, annotations: annotations, maxHR: 200,
                          now: now, calendar: calendar)
  }

  func testMissingDataDoesNotCreateReadinessFitnessOrPersonalRecords() {
    let result = summary()
    XCTAssertNil(result.readiness)
    XCTAssertNil(result.fitness)
    XCTAssertNil(result.loadRatio)
    XCTAssertTrue(result.records.isEmpty)
    XCTAssertTrue(result.trends.isEmpty)
    XCTAssertTrue(result.dailyLoad.isEmpty)
    XCTAssertEqual(result.loadStatus, "Building baseline")
  }

  func testReadinessUsesPriorPersonalBaselineAndExcludesCurrentReading() {
    var days = (-30 ... -1).map { DailyHealthMetrics(date: day($0), sleepMinutes: 480, restingHR: 60, hrv: 50) }
    days.append(DailyHealthMetrics(date: day(0), sleepMinutes: 480, restingHR: 54, hrv: 60))
    let result = summary(days: days)
    let baselineHR = result.readinessComponents.first { $0.title == "Resting HR" }
    let hrv = result.readinessComponents.first { $0.title == "HRV" }
    XCTAssertEqual(baselineHR?.value, 90)
    XCTAssertEqual(hrv?.value, 90)
    XCTAssertEqual(result.readiness, 82)
    XCTAssertTrue(baselineHR?.explanation.contains("60.0") == true)
  }

  func testInsufficientBaselineDoesNotPublishReadiness() {
    let days = (-5...0).map { DailyHealthMetrics(date: day($0), sleepMinutes: 480, restingHR: 60, hrv: 50) }
    XCTAssertNil(summary(days: days).readiness)
  }

  func testAppleEffortOverridesHeartRateAndManualRatings() {
    let session = workout("apple", effort: 8, heartRate: 120)
    XCTAssertEqual(TrainingInsights.sessionLoad(for: session, annotation: WorkoutAnnotation(effort: 2), maxHR: 200), 240)
    XCTAssertEqual(TrainingInsights.sessionLoad(for: workout("hr", heartRate: 120), maxHR: 200), 180)
    XCTAssertNil(TrainingInsights.sessionLoad(for: workout("none"), maxHR: 200))
  }

  func testSevenAndTwentyEightDayLoadDoNotIncludeOldOrFutureWorkouts() {
    let sessions = [workout("acute", offset: -2, effort: 5), workout("chronic", offset: -20, effort: 5),
                    workout("old", offset: -40, effort: 10), workout("future", offset: 1, effort: 10)]
    let result = summary(workouts: sessions)
    XCTAssertEqual(result.load7, 150)
    XCTAssertEqual(result.load28, 300)
    XCTAssertEqual(result.loadRatio ?? 0, 2, accuracy: 0.001)
    XCTAssertEqual(result.loadStatus, "High")
  }

  func testHeartZonesWeightTimeAndCapUnobservedGapsAtSixtySeconds() {
    let start = day(0)
    let zones = TrainingInsights.heartZones(samples: [
      WorkoutHeartSample(date: start, bpm: 110),
      WorkoutHeartSample(date: start.addingTimeInterval(30), bpm: 170),
      WorkoutHeartSample(date: start.addingTimeInterval(300), bpm: 190)
    ], end: start.addingTimeInterval(360), maxHR: 200)
    XCTAssertEqual(zones[0].minutes, 0.5)
    XCTAssertEqual(zones[3].minutes, 1)
    XCTAssertEqual(zones[4].minutes, 1)
    XCTAssertEqual(zones.reduce(0) { $0 + $1.minutes }, 2.5)
  }

  func testSustainedTrendRequiresMultipleDailyReadings() {
    var days = (-36 ... -7).map { DailyHealthMetrics(date: day($0), hrv: 50) }
    days += (-6...0).map { DailyHealthMetrics(date: day($0), hrv: 60) }
    let trend = summary(days: days).trends.first { $0.title == "HRV" }
    XCTAssertEqual(trend?.direction, "Sustained increase")
    XCTAssertEqual(trend?.changePercent ?? 0, 20, accuracy: 0.001)
    XCTAssertEqual(trend?.mean7, 60)
    XCTAssertNotNil(trend?.mean90)
    let sparse = summary(days: Array(days.dropLast(6))).trends.first { $0.title == "HRV" }
    XCTAssertEqual(sparse?.direction, "More readings needed")
  }

  func testAdaptiveGoalIsOnlyASuggestionAndRequiresEnoughCompleteDays() {
    let days = (-30 ... -1).map { DailyHealthMetrics(date: day($0), steps: 11_000) }
    let suggestion = TrainingInsights.adaptiveStepGoal(days: days, current: 8_000, now: now, calendar: calendar)
    XCTAssertEqual(suggestion?.current, 8_000)
    XCTAssertEqual(suggestion?.proposed, 8_400)
    XCTAssertNil(TrainingInsights.adaptiveStepGoal(days: Array(days.prefix(10)), current: 8_000, now: now, calendar: calendar))
  }

  func testStreakCanContinueFromYesterdayButFutureDaysCannotExtendIt() {
    let days = [-3, -2, -1, 1].map { DailyHealthMetrics(date: day($0), steps: 9_000) }
    XCTAssertEqual(summary(days: days).currentStreak, 3)
  }

  func testFastFiveKilometreRecordNeverUsesWholeTimeOfTenKilometreRun() {
    let result = summary(workouts: [workout("5k", offset: -1, minutes: 25, distance: 5),
                                    workout("10k", offset: -2, minutes: 40, distance: 10)])
    let best = result.records.first { $0.title == "Fastest ~5 km complete run" }
    XCTAssertTrue(best?.value.contains("25.0 min") == true)
    XCTAssertTrue(best?.value.contains("whole workout") == true)
  }
}
