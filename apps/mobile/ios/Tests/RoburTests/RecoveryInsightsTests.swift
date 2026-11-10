import XCTest
@testable import Robur

final class RecoveryInsightsTests: XCTestCase {
  private var calendar: Calendar { var c = Calendar(identifier: .gregorian); c.timeZone = TimeZone(secondsFromGMT: 0)!; return c }
  private let now = ISO8601DateFormatter().date(from: "2026-11-10T12:00:00Z")!
  private func day(_ ago: Int) -> Date { calendar.date(byAdding: .day, value: -ago, to: calendar.startOfDay(for: now))! }
  private func days() -> [DailyHealthMetrics] {
    (0..<70).map { DailyHealthMetrics(date: day($0), sleepMinutes: 480, steps: 9000, exerciseMinutes: 35,
      restingHR: 55, hrv: 60, vo2Max: 45) }
  }
  private func workout(_ id: String, daysAgo: Int, effort: Double = 5, minutes: Double = 40) -> WorkoutRecord {
    WorkoutRecord(id: id, start: day(daysAgo), end: day(daysAgo).addingTimeInterval(minutes * 60), title: "Strength",
      symbol: "figure.strengthtraining.traditional", minutes: minutes, distanceKm: nil, energyKcal: nil,
      averageHeartRate: nil, source: "Test", appleEffort: effort, activityType: .functionalStrength)
  }
  private func make(_ values: [DailyHealthMetrics], _ workouts: [WorkoutRecord] = [], at: Date? = nil) -> RecoveryAnalysis {
    RecoveryInsights.make(days: values, workouts: workouts, annotations: [:], maxHR: 190, now: at ?? now,
      historyStart: day(70), calendar: calendar)
  }

  func testSingleSleepSignalCannotProduceOverallRecovery() {
    let values = days().map { DailyHealthMetrics(date: $0.date, sleepMinutes: 480) }
    let result = make(values)
    XCTAssertNil(result.score)
    XCTAssertNotNil(result.recoveryComponents.first { $0.key == "sleepDebt" })
    XCTAssertNil(make([]).fitnessScore)
  }

  func testEffectiveWeightsAndContributionsExplainExactlyOneScore() throws {
    let result = make(days(), (0..<10).map { workout("s\($0)", daysAgo: $0 * 3) })
    XCTAssertEqual(result.recoveryComponents.reduce(0) { $0 + $1.effectiveWeight }, 1, accuracy: 0.000001)
    XCTAssertEqual(result.score, Int(result.recoveryComponents.reduce(0) { $0 + $1.contribution }.rounded()))
    XCTAssertEqual(result.methodologyVersion, RecoveryAnalysis.version)
    XCTAssertEqual(result.history.last?.recoveryComponents, result.recoveryComponents)
    let encoded = try JSONEncoder().encode(result)
    XCTAssertEqual(try JSONDecoder().decode(RecoveryAnalysis.self, from: encoded), result)
  }

  func testHistoryHasNoFutureMeasurementOrCrossMidnightWorkoutLeakage() {
    let cutoff = day(2).addingTimeInterval(12 * 3600)
    let snapshot = make(days(), at: cutoff)
    let full = make(days())
    let historical = full.history.first { calendar.isDate($0.date, inSameDayAs: cutoff) }
    XCTAssertEqual(historical?.recovery, snapshot.score)
    XCTAssertEqual(historical?.fitness, snapshot.fitnessScore)
    var future = days()
    future.append(DailyHealthMetrics(date: day(-1), sleepMinutes: 1, steps: 1, restingHR: 150, hrv: 1, vo2Max: 1))
    XCTAssertEqual(make(future).score, full.score)
    let crossing = WorkoutRecord(id: "overnight", start: day(2).addingTimeInterval(23 * 3600),
      end: day(1).addingTimeInterval(3600), title: "Run", symbol: "figure.run", minutes: 120,
      distanceKm: nil, energyKcal: nil, averageHeartRate: nil, source: "Test", appleEffort: 10)
    let history = make(days(), [crossing]).history
    XCTAssertNil(history.first { calendar.isDate($0.date, inSameDayAs: day(2)) }?.load)
    XCTAssertEqual(history.first { calendar.isDate($0.date, inSameDayAs: day(1)) }?.load, 1200)
  }

  func testPoorSleepLowersRecoveryButDoesNotDirectlyChangeFitness() {
    let workouts = (0..<10).map { workout("s\($0)", daysAgo: $0 * 3 + 1) }
    let normal = make(days(), workouts)
    var poor = days()
    poor[0].sleepMinutes = 240
    let reduced = make(poor, workouts)
    XCTAssertLessThan(reduced.score ?? 100, normal.score ?? 0)
    XCTAssertEqual(reduced.fitnessScore, normal.fitnessScore)
    XCTAssertTrue(reduced.fitnessComponents.allSatisfy { $0.key != "recovery" })
  }

  func testInvalidAndDuplicateDataDoNotInflateCoverageOrLoad() {
    let base = days(), session = workout("one", daysAgo: 1)
    let result = make(base, [session])
    let duplicated = make(base + base, [session, session])
    XCTAssertEqual(result, duplicated)
    let stale = (10..<45).map { DailyHealthMetrics(date: day($0), sleepMinutes: 480, restingHR: 55, hrv: 60) }
    XCTAssertNil(make(stale).score)
    XCTAssertTrue(make([DailyHealthMetrics(date: day(0), sleepMinutes: .nan, restingHR: .infinity, hrv: -1)]).recoveryComponents.isEmpty)
  }

  func testTrainingDemandUsesExplicitCoverageAndReducesAfterLargeEffort() {
    let routine = (1...20).map { workout("s\($0)", daysAgo: $0 * 3) }
    let baseline = make(days(), routine)
    let marathon = workout("marathon", daysAgo: 0, effort: 10, minutes: 240)
    let overloaded = make(days(), routine + [marathon])
    let before = baseline.recoveryComponents.first { $0.key == "load" }
    let after = overloaded.recoveryComponents.first { $0.key == "load" }
    XCTAssertNotNil(after)
    XCTAssertLessThan(after?.score ?? 100, before?.score ?? 0)
    XCTAssertLessThan(overloaded.score ?? 100, baseline.score ?? 0)
    XCTAssertEqual(overloaded.loadCoverage, 1)
  }

  func testFixedFitnessReferenceSurvivesDisplayRangeChangesAndNeverLeaksIntoEarlierDates() {
    let reference = FitnessReference(value: 40, establishedAt: day(40))
    let workouts = (1...10).map { workout("s\($0)", daysAgo: $0 * 2) }
    let full = RecoveryInsights.make(days: days(), workouts: workouts, annotations: [:], maxHR: 190,
      now: now, fitnessReference: reference, calendar: calendar)
    let short = RecoveryInsights.make(days: days().filter { $0.date >= day(35) }, workouts: workouts,
      annotations: [:], maxHR: 190, now: now, fitnessReference: reference, calendar: calendar)
    XCTAssertEqual(full.fitnessScore, short.fitnessScore)
    XCTAssertEqual(full.fitnessComponents.first { $0.key == "cardio" }?.baseline, 40)
    let early = full.history.filter { $0.date < reference.establishedAt }
    XCTAssertTrue(early.allSatisfy { $0.fitnessComponents.allSatisfy { $0.key != "cardio" } })
  }
}
