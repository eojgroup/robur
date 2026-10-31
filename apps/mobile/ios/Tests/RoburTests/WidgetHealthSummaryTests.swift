import XCTest
@testable import Robur

final class WidgetHealthSummaryTests: XCTestCase {
  private let now = Date(timeIntervalSince1970: 1_793_433_600)

  func testEmptyHealthDoesNotInventZeroScoresOrTraining() {
    let value = WidgetHealthSummary.make(days: [], workouts: [], now: now)
    XCTAssertFalse(value.hasData)
    XCTAssertNil(value.recovery)
    XCTAssertNil(value.steps)
    XCTAssertNil(value.trainingMinutes)
  }

  func testFreshnessExpiresAndRejectsFutureTimestamp() {
    let value = WidgetHealthSummary(refreshedAt: now, recovery: 70)
    XCTAssertFalse(value.isStale(at: now.addingTimeInterval(900)))
    XCTAssertTrue(value.isStale(at: now.addingTimeInterval(3601)))
    XCTAssertTrue(value.isStale(at: now.addingTimeInterval(-120)))
  }

  func testWeekUsesUniqueRecentSessionsAndDatesCardioReading() {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(secondsFromGMT: 0)!
    func workout(_ id: String, daysAgo: Int, minutes: Double) -> WorkoutRecord {
      let start = calendar.date(byAdding: .day, value: -daysAgo, to: now)!
      return WorkoutRecord(id: id, start: start, end: start.addingTimeInterval(minutes * 60), title: "Run", symbol: "figure.run",
        minutes: minutes, distanceKm: nil, energyKcal: nil, averageHeartRate: nil, source: "Fixture")
    }
    let cardioDate = calendar.date(byAdding: .day, value: -10, to: now)!
    let days = [DailyHealthMetrics(date: calendar.startOfDay(for: now), steps: 4321), DailyHealthMetrics(date: cardioDate, vo2Max: 48)]
    let recent = workout("recent", daysAgo: 1, minutes: 45)
    let value = WidgetHealthSummary.make(days: days, workouts: [recent, recent, workout("old", daysAgo: 9, minutes: 80)], now: now, calendar: calendar)
    XCTAssertEqual(value.trainingMinutes, 45)
    XCTAssertEqual(value.workoutCount, 1)
    XCTAssertEqual(value.steps, 4321)
    XCTAssertEqual(value.cardioFitness, 48)
    XCTAssertEqual(value.cardioDate, cardioDate)
  }
}
