import XCTest
@testable import Robur

final class HealthImportTests: XCTestCase {
  func testAppleFitnessEffortTakesPrecedenceOverLegacyManualRating() {
    let start = Date()
    let workout = WorkoutRecord(id: "apple", start: start, end: start.addingTimeInterval(1800), title: "Run",
      symbol: "figure.run", minutes: 30, distanceKm: 5, energyKcal: nil, averageHeartRate: nil,
      source: "Apple Watch", appleEffort: 8)
    let result = WorkoutAnalytics.buckets(workouts: [workout], annotations: ["apple": WorkoutAnnotation(effort: 3)])
    XCTAssertEqual(result.first?.load, 240)
    XCTAssertEqual(result.first?.ratedWorkouts, 1)
  }

  func testOverlappingSleepSourcesAreMergedAndSplitAtMidnight() {
    var calendar = Calendar(identifier: .iso8601)
    calendar.timeZone = TimeZone(secondsFromGMT: 0)!
    let formatter = ISO8601DateFormatter()
    let start = formatter.date(from: "2026-10-28T22:00:00Z")!
    let midnight = formatter.date(from: "2026-10-29T00:00:00Z")!
    let end = formatter.date(from: "2026-10-29T06:00:00Z")!
    let values = HealthImportMath.sleepMinutes(intervals: [DateInterval(start: start, end: end),
      DateInterval(start: midnight, end: end)], calendar: calendar)
    XCTAssertEqual(values[calendar.startOfDay(for: start)], 120)
    XCTAssertEqual(values[midnight], 360)
    XCTAssertEqual(values.values.reduce(0, +), 480)
  }

  func testSleepCalendarBucketsRespectDaylightSavingTransition() {
    var calendar = Calendar(identifier: .iso8601)
    calendar.timeZone = TimeZone(identifier: "Europe/Berlin")!
    let start = calendar.date(from: DateComponents(year: 2026, month: 10, day: 25))!
    let end = calendar.date(byAdding: .day, value: 1, to: start)!
    let values = HealthImportMath.sleepMinutes(intervals: [DateInterval(start: start, end: end)], calendar: calendar)
    XCTAssertEqual(values[start], 25 * 60)
    XCTAssertEqual(values.count, 1)
  }

  func testMeasuredZeroActivityIsPreservedRatherThanTreatedAsMissing() {
    let readings = [FitnessReading(id: "zero", date: Date(), value: 0, metric: .steps)]
    XCTAssertEqual(WorkoutAnalytics.trend(readings: readings, metric: .steps).first?.value, 0)
    XCTAssertTrue(WorkoutAnalytics.trend(readings: [], metric: .steps).isEmpty)
  }
}
