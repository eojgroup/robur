import XCTest
import HealthKit
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

  func testOvernightSleepStaysWholeOnItsWakingDay() {
    var calendar = Calendar(identifier: .iso8601)
    calendar.timeZone = TimeZone(secondsFromGMT: 0)!
    let formatter = ISO8601DateFormatter()
    let start = formatter.date(from: "2026-10-28T22:00:00Z")!
    let end = formatter.date(from: "2026-10-29T06:00:00Z")!
    let values = HealthImportMath.sleepMinutes(intervals: [DateInterval(start: start, end: end)], calendar: calendar, wakingDay: true)
    XCTAssertEqual(values.count, 1)
    XCTAssertEqual(values[calendar.startOfDay(for: end)], 480)
  }

  func testMeasuredZeroActivityIsPreservedRatherThanTreatedAsMissing() {
    let readings = [FitnessReading(id: "zero", date: Date(), value: 0, metric: .steps)]
    XCTAssertEqual(WorkoutAnalytics.trend(readings: readings, metric: .steps).first?.value, 0)
    XCTAssertTrue(WorkoutAnalytics.trend(readings: [], metric: .steps).isEmpty)
  }
  func testReportedEffortWinsNewerEstimatesRegardlessOfRelationshipOrder() {
    let now = Date()
    let candidates = [
      WorkoutEffortCandidate(score: 4, source: .estimated, date: now, sampleID: "estimate"),
      WorkoutEffortCandidate(score: 8, source: .reported, date: now.addingTimeInterval(-600), activityID: "default-activity", durationMinutes: 30, sampleID: "rating")
    ]
    XCTAssertEqual(HealthImportMath.effort(candidates), WorkoutEffortSelection(score: 8, source: .reported))
    XCTAssertEqual(HealthImportMath.effort(Array(candidates.reversed())), HealthImportMath.effort(candidates))
  }

  func testLatestReportedActivityScoresAreWeightedAndDuplicateRelationshipsDoNotInflate() {
    let now = Date()
    let candidates = [
      WorkoutEffortCandidate(score: 4, source: .reported, date: now.addingTimeInterval(-10), activityID: "one", durationMinutes: 30, sampleID: "old"),
      WorkoutEffortCandidate(score: 8, source: .reported, date: now, activityID: "one", durationMinutes: 30, sampleID: "new"),
      WorkoutEffortCandidate(score: 2, source: .reported, date: now, activityID: "two", durationMinutes: 10, sampleID: "second")
    ]
    XCTAssertEqual(HealthImportMath.effort(candidates)?.score, 6.5)
    XCTAssertEqual(HealthImportMath.effort(candidates + candidates), HealthImportMath.effort(candidates))
  }

  func testWholeWorkoutReportedRatingWinsActivityRatingsAndInvalidValuesAreIgnored() {
    let now = Date()
    let candidates = [
      WorkoutEffortCandidate(score: .nan, source: .reported, date: now),
      WorkoutEffortCandidate(score: 0, source: .reported, date: now),
      WorkoutEffortCandidate(score: 11, source: .reported, date: now),
      WorkoutEffortCandidate(score: 5, source: .reported, date: now.addingTimeInterval(-20), sampleID: "whole"),
      WorkoutEffortCandidate(score: 9, source: .reported, date: now, activityID: "one", durationMinutes: 30, sampleID: "activity")
    ]
    XCTAssertEqual(HealthImportMath.effort(candidates), WorkoutEffortSelection(score: 5, source: .reported))
    XCTAssertNil(HealthImportMath.effort(Array(candidates.prefix(3))))
  }

  func testEstimatedEffortRemainsExplicitlyEstimatedWhenNoRatingExists() {
    let value = HealthImportMath.effort([WorkoutEffortCandidate(score: 6, source: .estimated, date: Date())])
    XCTAssertEqual(value?.source, .estimated)
    XCTAssertEqual(value?.score, 6)
    XCTAssertNil(HealthImportMath.effort([]))
  }

  @MainActor
  func testTennisAndRacketSportsHaveStableIdentityAndFriendlyNames() async {
    XCTAssertEqual(HealthKitClient.workoutActivity(.tennis), .tennis)
    XCTAssertEqual(HealthKitClient.workoutPresentation(.tennis).0, "Tennis")
    XCTAssertEqual(HealthKitClient.workoutActivity(.badminton), .racketSports)
    XCTAssertEqual(HealthKitClient.workoutPresentation(.pickleball).0, "Pickleball")
    XCTAssertEqual(HealthKitClient.workoutActivity(.traditionalStrengthTraining), .traditionalStrength)
  }

}
