import XCTest
@testable import Robur

final class TrainingSessionOverviewTests: XCTestCase {
  private var calendar: Calendar {
    var result = Calendar(identifier: .gregorian)
    result.timeZone = TimeZone(secondsFromGMT: 0)!
    return result
  }
  private let start = Date(timeIntervalSince1970: 1_800_000_000)
  private func workout(_ id: String, offset: TimeInterval = 0, activity: WorkoutActivity = .running, minutes: Double = 45) -> WorkoutRecord {
    var record = WorkoutRecord(id: id, start: start.addingTimeInterval(offset),
      end: start.addingTimeInterval(offset + minutes * 60), title: activity.title, symbol: activity.symbol,
      minutes: minutes, distanceKm: nil, energyKcal: nil, averageHeartRate: nil, source: "Test")
    record.activityType = activity
    return record
  }

  func testMatchesOnceWithoutCompletingOrMutatingPlan() {
    let plan = PlanEntry(activity: .running, startDate: start, durationMinutes: 45, state: .confirmed)
    let result = TrainingSessionOverview.compare(plans: [plan], workouts: [workout("a"), workout("a")], calendar: calendar)
    XCTAssertEqual(result.count, 1)
    XCTAssertEqual(result.first?.plan?.state, .confirmed)
    XCTAssertEqual(result.first?.workout?.id, "a")
    XCTAssertNil(result.first?.plan?.calendarEventID)
  }

  func testRejectsDifferentActivityDistantTimeDurationAndUnknownActivity() {
    let plan = PlanEntry(activity: .running, startDate: start, durationMinutes: 45)
    for candidate in [workout("cycling", activity: .cycling), workout("distant", offset: 4 * 3_600),
                      workout("short", minutes: 5), workout("tomorrow", offset: 86_400)] {
      let result = TrainingSessionOverview.compare(plans: [plan], workouts: [candidate], calendar: calendar)
      XCTAssertEqual(result.count, 2)
      XCTAssertFalse(result.contains { $0.plan != nil && $0.workout != nil })
    }
    let unknown = PlanEntry(activity: .other, startDate: start, durationMinutes: 45)
    XCTAssertEqual(TrainingSessionOverview.compare(plans: [unknown], workouts: [workout("unknown", activity: .other)], calendar: calendar).count, 2)
  }

  func testClosestCandidateWinsRegardlessOfInputOrder() {
    let first = PlanEntry(activity: .running, startDate: start, durationMinutes: 45)
    let second = PlanEntry(activity: .running, startDate: start.addingTimeInterval(3_600), durationMinutes: 45)
    let workouts = [workout("near-first", offset: 300), workout("near-second", offset: 3_900)]
    let result = TrainingSessionOverview.compare(plans: [second, first], workouts: workouts.reversed(), calendar: calendar)
    XCTAssertEqual(result.count, 2)
    XCTAssertEqual(result.first { $0.plan?.id == first.id }?.workout?.id, "near-first")
    XCTAssertEqual(result.first { $0.plan?.id == second.id }?.workout?.id, "near-second")
  }

  func testSameDayUsesLocalCalendarAcrossMidnight() {
    var local = calendar
    local.timeZone = TimeZone(secondsFromGMT: 3_600)!
    let midnight = local.startOfDay(for: start)
    let before = midnight.addingTimeInterval(-900)
    let after = midnight.addingTimeInterval(900)
    let plan = PlanEntry(activity: .running, startDate: before, durationMinutes: 45)
    var record = workout("after-midnight")
    record = WorkoutRecord(id: record.id, start: after, end: after.addingTimeInterval(2_700),
      title: record.title, symbol: record.symbol, minutes: record.minutes, distanceKm: nil,
      energyKcal: nil, averageHeartRate: nil, source: record.source, activityType: .running)
    XCTAssertEqual(TrainingSessionOverview.compare(plans: [plan], workouts: [record], calendar: local).count, 2)
  }
}
