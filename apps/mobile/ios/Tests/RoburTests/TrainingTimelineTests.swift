import XCTest
@testable import Robur

final class TrainingTimelineTests: XCTestCase {
  private var calendar: Calendar {
    var calendar = Calendar(identifier: .iso8601)
    calendar.timeZone = TimeZone(secondsFromGMT: 0)!
    return calendar
  }
  private let now = ISO8601DateFormatter().date(from: "2026-10-31T12:00:00Z")!
  private func day(_ offset: Int) -> Date { calendar.date(byAdding: .day, value: offset, to: calendar.startOfDay(for: now))! }
  private func workout(_ id: String, offset: Int = 0, activity: WorkoutActivity = .running,
                       minutes: Double = 30, km: Double? = nil, effort: Double? = nil) -> WorkoutRecord {
    WorkoutRecord(id: id, start: day(offset), end: day(offset).addingTimeInterval(minutes * 60), title: "Session",
      symbol: activity.symbol, minutes: minutes, distanceKm: km, energyKcal: nil, averageHeartRate: nil,
      source: "Fixture", appleEffort: effort, activityType: activity)
  }

  func testAggregationUsesOnlyMeasuredEffortAndRecordedRecoveryDays() {
    let sessions = [workout("rated", minutes: 40, effort: 5), workout("unrated", minutes: 20)]
    let days = [DailyHealthMetrics(date: day(0), sleepMinutes: 360), DailyHealthMetrics(date: day(-1), sleepMinutes: nil)]
    let result = TrainingTimeline.make(workouts: sessions, days: days, grain: .month, now: now, calendar: calendar)
    XCTAssertEqual(result.buckets.count, 1)
    XCTAssertEqual(result.buckets[0].minutes, 60)
    XCTAssertEqual(result.buckets[0].appleLoad, 200)
    XCTAssertEqual(result.buckets[0].ratedSessions, 1)
    XCTAssertEqual(result.buckets[0].recoveryValue, 360)
    XCTAssertEqual(result.buckets[0].recoveryDays, 1)
    XCTAssertNil(result.buckets[0].recoveryBaseline)
  }

  func testMissingMeasurementsDoNotCreateZeroBucketsOrLoad() {
    let result = TrainingTimeline.make(workouts: [workout("unrated")],
      days: [DailyHealthMetrics(date: day(-7), sleepMinutes: nil)], grain: .day, now: now, calendar: calendar)
    XCTAssertEqual(result.buckets.count, 1)
    XCTAssertNil(result.buckets[0].appleLoad)
    XCTAssertNil(result.buckets[0].recoveryValue)
    XCTAssertTrue(result.recovery.isEmpty)
  }

  func testMarathonRequiresRunningAndMeasuredDistanceAtLeast42195Km() {
    let sessions = [workout("marathon", km: 42.195), workout("short", km: 42.194),
                    workout("bike", activity: .cycling, km: 50)]
    let result = TrainingTimeline.make(workouts: sessions, days: [], now: now, calendar: calendar)
    XCTAssertEqual(result.events.filter { $0.kind == .marathon }.map(\.workoutID), ["marathon"])
  }

  func testEventsIdentifyLongAndHighEffortSessionsWithoutCallingThemRaces() {
    let result = TrainingTimeline.make(workouts: [workout("long", minutes: 120), workout("hard", effort: 8),
      workout("ordinary", effort: 7.9)], days: [], now: now, calendar: calendar)
    XCTAssertTrue(result.events.contains { $0.workoutID == "long" && $0.kind == .longSession })
    XCTAssertTrue(result.events.contains { $0.workoutID == "hard" && $0.kind == .highEffort })
    XCTAssertFalse(result.events.contains { $0.workoutID == "ordinary" })
  }

  func testRecoveryBaselineExcludesCurrentAndFutureReadingsAndKeepsEventDate() {
    let history = (-30 ... -1).map { DailyHealthMetrics(date: day($0), sleepMinutes: 480, restingHR: 50, hrv: 60) }
    let current = DailyHealthMetrics(date: day(0), sleepMinutes: 360, restingHR: 60, hrv: 40)
    let future = DailyHealthMetrics(date: day(1), sleepMinutes: 1_000)
    let result = TrainingTimeline.make(workouts: [], days: history + [current, future], grain: .day,
      start: day(0), now: now, calendar: calendar)
    XCTAssertEqual(result.recovery.count, 1)
    XCTAssertEqual(result.recovery[0].baseline, 480)
    XCTAssertEqual(result.recovery[0].baselineDays, 30)
    XCTAssertEqual(result.recovery[0].changePercent, -25)
    XCTAssertEqual(Set(result.events.map(\.kind)), [.poorSleep, .lowHRV, .highRestingHR])
    XCTAssertTrue(result.events.allSatisfy { $0.date == day(0) })
  }

  func testBaselineNeedsSevenActualPriorDaysWithinThirtyDays() {
    let sparse = [-40, -35, -6, -5, -4, -3, -2, -1].map { DailyHealthMetrics(date: day($0), sleepMinutes: 480) }
    let result = TrainingTimeline.make(workouts: [], days: sparse + [DailyHealthMetrics(date: day(0), sleepMinutes: 200)],
      start: day(0), now: now, calendar: calendar)
    XCTAssertNil(result.recovery.first?.baseline)
    XCTAssertTrue(result.events.isEmpty)
  }

  func testWeeklyGapsCreateSeparateRecoverySegmentsAndDuplicateWorkoutsAreIgnored() {
    let session = workout("one")
    let result = TrainingTimeline.make(workouts: [session, session], days: [
      DailyHealthMetrics(date: day(-21), sleepMinutes: 420), DailyHealthMetrics(date: day(0), sleepMinutes: 400)],
      grain: .week, now: now, calendar: calendar)
    XCTAssertEqual(result.buckets.reduce(0) { $0 + $1.sessions }, 1)
    XCTAssertEqual(result.buckets.compactMap { $0.recoveryValue == nil ? nil : $0.segment }, [0, 1])
  }
}
