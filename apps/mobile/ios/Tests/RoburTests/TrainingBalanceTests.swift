import XCTest
@testable import Robur

final class TrainingBalanceTests: XCTestCase {
  private var calendar: Calendar {
    var calendar = Calendar(identifier: .iso8601)
    calendar.timeZone = TimeZone(secondsFromGMT: 0)!
    return calendar
  }
  private let now = ISO8601DateFormatter().date(from: "2026-10-31T12:00:00Z")!
  private func day(_ offset: Int) -> Date { calendar.date(byAdding: .day, value: offset, to: calendar.startOfDay(for: now))! }
  private func workout(_ id: String, offset: Int = 0, activity: WorkoutActivity = .running,
                       minutes: Double = 10, effort: Double? = 1, source: WorkoutEffortSource? = .reported,
                       title: String = "Recorded workout") -> WorkoutRecord {
    WorkoutRecord(id: id, start: day(offset), end: day(offset).addingTimeInterval(minutes * 60), title: title,
      symbol: activity.symbol, minutes: minutes, distanceKm: nil, energyKcal: nil,
      averageHeartRate: 140, source: "Fixture", appleEffort: effort, effortSource: source, activityType: activity)
  }
  private func load(_ workouts: [WorkoutRecord], historyStart: Int = -90, activity: WorkoutActivity? = nil) -> TrainingLoadSummary {
    TrainingLoadComparison.make(workouts: workouts, now: now, historyStart: day(historyStart),
                                displayDays: 30, activity: activity, calendar: calendar)
  }

  func testConstantDailyEffortHasSteadySevenVersusTwentyEightDayMeans() {
    let sessions = (-35...0).map { workout("day\($0)", offset: $0) }
    let result = load(sessions)
    XCTAssertEqual(result.recent7Mean ?? -1, 10, accuracy: 0.001)
    XCTAssertEqual(result.baseline28Mean ?? -1, 10, accuracy: 0.001)
    XCTAssertEqual(result.changePercent ?? -1, 0, accuracy: 0.001)
    XCTAssertEqual(result.classification, "Steady")
    XCTAssertEqual(result.ratedSessions, 28)
    XCTAssertEqual(result.reportedSessions, 28)
  }

  func testBaselineIncludesRecentSevenDaysWithoutCompressingRestDays() {
    let result = load([workout("only", minutes: 70)])
    XCTAssertEqual(result.recent7Mean ?? -1, 10, accuracy: 0.001)
    XCTAssertEqual(result.baseline28Mean ?? -1, 2.5, accuracy: 0.001)
    XCTAssertEqual(result.changePercent ?? -1, 300, accuracy: 0.001)
    XCTAssertEqual(result.classification, "Well above")
  }

  func testRecentIncreaseUsesWholeCalendarWindows() {
    let sessions = (-27...0).map { workout("day\($0)", offset: $0, effort: $0 >= -6 ? 2 : 1) }
    let result = load(sessions)
    XCTAssertEqual(result.recent7Mean ?? -1, 20, accuracy: 0.001)
    XCTAssertEqual(result.baseline28Mean ?? -1, 12.5, accuracy: 0.001)
    XCTAssertEqual(result.changePercent ?? -1, 60, accuracy: 0.001)
  }

  func testHistoricalPointsDoNotUseLaterSessions() {
    let sessions = (-35 ... -1).map { workout("day\($0)", offset: $0) } + [workout("hard", minutes: 100, effort: 10)]
    let previous = load(sessions).points.first { $0.date == day(-1) }
    XCTAssertEqual(previous?.changePercent ?? -1, 0, accuracy: 0.001)
  }

  func testIncompleteCoverageDoesNotPretendToHaveTwentyEightDays() {
    let result = load([workout("current")], historyStart: -20)
    XCTAssertNotNil(result.recent7Mean)
    XCTAssertNil(result.baseline28Mean)
    XCTAssertNil(result.changePercent)
    XCTAssertEqual(result.classification, "Insufficient effort history")
  }

  func testMissingImportedEffortDoesNotUseHeartRateOrCreateZeroMeasurements() {
    let result = load([workout("unrated", effort: nil)])
    XCTAssertEqual(result.ratedSessions, 0)
    XCTAssertEqual(result.totalSessions, 1)
    XCTAssertNil(result.recent7Mean)
    XCTAssertNil(result.baseline28Mean)
    XCTAssertTrue(result.points.allSatisfy { $0.dailyLoad == nil })
  }

  func testRestWeekCanBeZeroButUnratedWeekCannot() {
    let prior = workout("prior", offset: -12)
    XCTAssertEqual(load([prior]).changePercent, -100)
    XCTAssertNil(load([prior, workout("unrated", effort: nil)]).changePercent)
  }

  func testCoverageCountsReportedAndEstimatedAndFiltersByActivity() {
    let sessions = [workout("run"), workout("cycle", activity: .cycling, source: .estimated),
                    workout("unrated", activity: .cycling, effort: nil)]
    let result = load(sessions)
    XCTAssertEqual(result.totalSessions, 3)
    XCTAssertEqual(result.ratedSessions, 2)
    XCTAssertEqual(result.reportedSessions, 1)
    XCTAssertEqual(result.estimatedSessions, 1)
    let cycling = load(sessions, activity: .cycling)
    XCTAssertEqual(cycling.totalSessions, 2)
    XCTAssertEqual(cycling.reportedSessions, 0)
    XCTAssertEqual(cycling.estimatedSessions, 1)
  }

  func testLoadBandBoundariesAreExplicitRoburThresholds() {
    for (change, expected) in [(-50.1, "Well below"), (-50, "Below"), (-10, "Steady"),
                               (10, "Steady"), (10.1, "Above"), (50, "Above"), (50.1, "Well above")] {
      XCTAssertEqual(TrainingLoadComparison.classification(changePercent: change), expected)
    }
  }

  func testMixPreservesActualTypesRatherThanInferringFromTitles() {
    let sessions = [workout("run", activity: .running), workout("bike", activity: .cycling),
                    workout("tennis", activity: .tennis), workout("functional", activity: .functionalStrength),
                    workout("unknown", activity: .other, title: "Legs and core")]
    let result = TrainingBalance.make(workouts: sessions, now: now, calendar: calendar)
    XCTAssertEqual(Set(result.breakdown.map(\.activity)), [.running, .cycling, .tennis, .functionalStrength, .other])
    XCTAssertEqual(result.categories.first { $0.category == .strength }?.sessions, 1)
    XCTAssertEqual(result.missing, [.mobility])
    XCTAssertTrue(result.missingActivities.isEmpty)
  }

  func testOnlyExplicitTargetsAppearAsGapsAndNoSportIsRequiredByDefault() {
    let none = TrainingBalance.make(workouts: [], now: now, expected: [], calendar: calendar)
    XCTAssertTrue(none.missing.isEmpty)
    XCTAssertTrue(none.missingActivities.isEmpty)
    let chosen = TrainingBalance.make(workouts: [], now: now, expected: [.strength], expectedActivities: [.tennis], calendar: calendar)
    XCTAssertEqual(chosen.missing, [.strength])
    XCTAssertEqual(chosen.missingActivities, [.tennis])
    XCTAssertEqual(chosen.totalMinutes, 0)
  }

  func testMixWindowExcludesOldAndFutureSessionsAndDuplicateImports() {
    let current = workout("current", offset: -27, activity: .functionalStrength)
    let result = TrainingBalance.make(workouts: [current, current, workout("old", offset: -28), workout("future", offset: 1)], now: now, calendar: calendar)
    XCTAssertEqual(result.sessions, 1)
    XCTAssertEqual(result.totalMinutes, 10)
    XCTAssertEqual(result.breakdown.first?.activity, .functionalStrength)
  }
}
