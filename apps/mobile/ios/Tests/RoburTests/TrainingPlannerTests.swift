import XCTest
@testable import Robur

final class TrainingPlannerTests: XCTestCase {
  private var calendar: Calendar {
    var value = Calendar(identifier: .iso8601)
    value.timeZone = TimeZone(secondsFromGMT: 0)!
    return value
  }
  private let now = ISO8601DateFormatter().date(from: "2026-10-31T12:00:00Z")!
  private func day(_ offset: Int) -> Date {
    calendar.date(byAdding: .day, value: offset, to: calendar.startOfDay(for: now))!
  }
  private func workout(_ id: String, offset: Int, activity: WorkoutActivity) -> WorkoutRecord {
    WorkoutRecord(id: id, start: day(offset), end: day(offset).addingTimeInterval(1_800), title: activity.title,
      symbol: activity.symbol, minutes: 30, distanceKm: nil, energyKcal: nil, averageHeartRate: nil,
      source: "Fixture", activityType: activity)
  }

  func testNewPlanHasThreeDraftsAndNoExternalAssociations() {
    let result = TrainingPlanner.suggest(workouts: [], now: now, calendar: calendar)
    XCTAssertEqual(result.count, 3)
    XCTAssertTrue(result.allSatisfy { $0.state == .suggested && !$0.calendarWasExported && $0.calendarEventID == nil && $0.reminderID == nil })
    XCTAssertEqual(Set(result.map { $0.activity.category }), [.endurance, .strength, .mobility])
  }

  func testExperiencedWeekCanHaveFourSlotsButExistingPlansCountTowardLimit() {
    let recent = (-4 ... -1).map { workout("\($0)", offset: $0, activity: .walking) }
    let first = TrainingPlanner.suggest(workouts: recent, now: now, calendar: calendar)
    XCTAssertEqual(first.count, 4)
    XCTAssertTrue(TrainingPlanner.suggest(workouts: recent, existing: first, now: now, calendar: calendar).isEmpty)
  }

  func testLessTrainedSelectedCategoriesComeFirst() {
    let result = TrainingPlanner.suggest(workouts: [workout("run", offset: -1, activity: .running)],
      categories: [.endurance, .mobility], now: now, calendar: calendar)
    XCTAssertEqual(result.first?.activity, .mobility)
    XCTAssertTrue(result.allSatisfy { [.endurance, .mobility].contains($0.activity.category) })
    XCTAssertTrue(TrainingPlanner.suggest(workouts: [], categories: [], now: now, calendar: calendar).isEmpty)
  }

  func testSelectedActivityIsPreservedWithinItsCategory() {
    let result = TrainingPlanner.suggest(workouts: [], categories: [.endurance], preferredActivities: [.cycling], now: now, calendar: calendar)
    XCTAssertTrue(result.allSatisfy { $0.activity == .cycling })
  }

  func testStrengthNeverUsesNeighboringCalendarDaysIncludingRecentWorkout() {
    let recent = [workout("strength", offset: -1, activity: .traditionalStrength)]
    let result = TrainingPlanner.suggest(workouts: recent, categories: [.strength], now: now, calendar: calendar)
    XCTAssertEqual(result.count, 3)
    let dates = [day(-1)] + result.map { calendar.startOfDay(for: $0.startDate) }
    for pair in zip(dates, dates.dropFirst()) {
      XCTAssertGreaterThan(calendar.dateComponents([.day], from: pair.0, to: pair.1).day!, 1)
    }
  }

  func testCalendarCollisionsUseWholeIntervalsAndShiftWithinWindow() {
    let blockedStart = calendar.date(bySettingHour: 17, minute: 0, second: 0, of: day(0))!
    let busy = [DateInterval(start: blockedStart, end: blockedStart.addingTimeInterval(3_600))]
    let result = TrainingPlanner.suggest(workouts: [], busy: busy, now: now, startHour: 17, endHour: 20, calendar: calendar)
    XCTAssertEqual(result.first?.startDate, blockedStart.addingTimeInterval(3_600))
    XCTAssertTrue(result.allSatisfy { entry in busy.allSatisfy { !TrainingPlanner.overlaps(DateInterval(start: entry.startDate, end: entry.endDate), $0) } })
    let allWeek = DateInterval(start: day(0), end: day(8))
    XCTAssertTrue(TrainingPlanner.suggest(workouts: [], busy: [allWeek], now: now, calendar: calendar).isEmpty)
  }

  func testTouchingEventBoundaryIsNotAConflict() {
    let start = now
    XCTAssertFalse(TrainingPlanner.overlaps(DateInterval(start: start, duration: 60), DateInterval(start: start.addingTimeInterval(60), duration: 60)))
    XCTAssertTrue(TrainingPlanner.overlaps(DateInterval(start: start, duration: 61), DateInterval(start: start.addingTimeInterval(60), duration: 60)))
  }

  func testDSTKeepsLocalHoursAcrossShortAndLongDays() {
    var local = Calendar(identifier: .gregorian)
    local.timeZone = TimeZone(identifier: "America/New_York")!
    for (date, elapsedHours) in [("2026-03-07T05:00:00Z", 47.0), ("2026-10-31T04:00:00Z", 49.0)] {
      let anchor = ISO8601DateFormatter().date(from: date)!
      let entries = TrainingPlanner.suggest(workouts: [], now: anchor, startHour: 17, endHour: 20, calendar: local)
      XCTAssertEqual(entries.count, 3)
      XCTAssertTrue(entries.allSatisfy { local.component(.hour, from: $0.startDate) == 17 })
      XCTAssertEqual(entries[1].startDate.timeIntervalSince(entries[0].startDate) / 3_600, elapsedHours, accuracy: 0.01)
    }
  }

  func testNonexistentDSTHourMovesForwardInsideSelectedWindow() {
    var local = Calendar(identifier: .gregorian)
    local.timeZone = TimeZone(identifier: "America/New_York")!
    let anchor = ISO8601DateFormatter().date(from: "2026-03-08T05:00:00Z")!
    let result = TrainingPlanner.suggest(workouts: [], now: anchor, startHour: 2, endHour: 4, calendar: local)
    XCTAssertEqual(local.component(.hour, from: result[0].startDate), 3)
    XCTAssertTrue(result.allSatisfy { local.component(.hour, from: $0.endDate) < 4 })
  }

  func testCalendarMovesPendingDatesAndCustomTitleConfirms() {
    var entry = PlanEntry(activity: .running, startDate: now, durationMinutes: 25)
    let moved = now.addingTimeInterval(3_600)
    entry.reconcile(start: moved, end: moved.addingTimeInterval(1_800), title: "[Suggested] Running — Robur", isBusy: true)
    XCTAssertEqual(entry.startDate, moved)
    XCTAssertEqual(entry.durationMinutes, 30)
    XCTAssertEqual(entry.state, .suggested) // Unsupported availability cannot accidentally confirm.
    entry.reconcile(start: moved, end: moved.addingTimeInterval(1_800), title: "My riverside run", isBusy: false)
    XCTAssertEqual(entry.state, .confirmed)
  }

  func testTentativeBusyConfirmsAndCompletedNeverRegresses() {
    var entry = PlanEntry(activity: .cycling, startDate: now, durationMinutes: 25)
    entry.calendarUsesTentativeAvailability = true
    entry.reconcile(start: now, end: entry.endDate, title: entry.calendarTitle, isBusy: true)
    XCTAssertEqual(entry.state, .confirmed)
    entry.state = .completed
    entry.reconcile(start: now, end: entry.endDate, title: "[Suggested] Cycling — Robur", isBusy: false)
    XCTAssertEqual(entry.state, .completed)
  }

  func testIdentityAndDeletionTombstonesSurviveCoding() throws {
    var entry = PlanEntry(activity: .functionalStrength, startDate: now, durationMinutes: 30, muscles: [.back, .core])
    entry.calendarWasExported = true
    entry.reminderWasCreated = true
    let decoded = try JSONDecoder().decode(PlanEntry.self, from: JSONEncoder().encode(entry))
    XCTAssertEqual(decoded, entry)
    XCTAssertEqual(decoded.url.absoluteString, "robur://plan/\(entry.id.uuidString)")
    XCTAssertTrue(decoded.calendarWasExported)
    XCTAssertNil(decoded.calendarEventID)
  }

  @MainActor
  func testLocalPlanPersistsAndWriteFailureRollsBack() throws {
    let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let url = directory.appending(path: "plan.json")
    let store = TrainingPlannerStore(url: url, observeChanges: false)
    store.generateWeek(workouts: [], categories: [.endurance], now: now, calendar: calendar)
    XCTAssertEqual(store.entries.count, 3)
    XCTAssertEqual(TrainingPlannerStore(url: url, observeChanges: false).entries, store.entries)

    let blockedParent = directory.appending(path: "blocked")
    let blocked = TrainingPlannerStore(url: blockedParent.appending(path: "plan.json"), observeChanges: false)
    try Data("file, not a directory".utf8).write(to: blockedParent)
    blocked.generateWeek(workouts: [], categories: [.strength], now: now, calendar: calendar)
    XCTAssertTrue(blocked.entries.isEmpty)
    XCTAssertNotNil(blocked.lastError)
  }

  @MainActor
  func testUnreadableArchiveIsPreserved() throws {
    let url = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: url) }
    let original = Data("incomplete archive".utf8)
    try original.write(to: url)
    let store = TrainingPlannerStore(url: url, observeChanges: false)
    store.generateWeek(workouts: [], categories: [.mobility], now: now, calendar: calendar)
    XCTAssertTrue(store.entries.isEmpty)
    XCTAssertNotNil(store.lastError)
    XCTAssertEqual(try Data(contentsOf: url), original)
  }
}
