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

  func testLegacyEntryDecodesWithoutPendingSyncOrManualFields() throws {
    let entry = PlanEntry(activity: .running, startDate: now, durationMinutes: 25)
    let data = try JSONEncoder().encode(entry)
    let object = try JSONSerialization.jsonObject(with: data) as! [String: Any]
    XCTAssertNil(object["calendarSyncPending"])
    XCTAssertNil(object["reminderSyncPending"])
    XCTAssertNil(object["isManualSession"])
    XCTAssertNil(object["calendarLastKnownStartDate"])
    XCTAssertNil(object["calendarExternalID"])
    let restored = try JSONDecoder().decode(PlanEntry.self, from: data)
    XCTAssertEqual(restored, entry)
  }

  func testDuplicateClearsExternalIdentityAndCompletion() {
    var source = PlanEntry(activity: .functionalStrength, startDate: now, durationMinutes: 45, muscles: [.back, .core])
    source.state = .completed
    source.calendarEventID = "owned-event"
    source.reminderID = "owned-reminder"
    source.calendarWasExported = true
    source.reminderWasCreated = true
    source.calendarUsesTentativeAvailability = true
    source.calendarSyncPending = true
    source.reminderSyncPending = true
    source.calendarLastKnownStartDate = now
    source.calendarExternalID = "provider-identity"
    let copy = source.duplicated(startDate: day(2))
    XCTAssertFalse(copy.id == source.id)
    XCTAssertFalse(copy.url == source.url)
    XCTAssertEqual(copy.activity, source.activity)
    XCTAssertEqual(copy.muscles, source.muscles)
    XCTAssertEqual(copy.durationMinutes, source.durationMinutes)
    XCTAssertEqual(copy.startDate, day(2))
    XCTAssertEqual(copy.state, .suggested)
    XCTAssertEqual(copy.isManualSession, true)
    XCTAssertNil(copy.calendarEventID)
    XCTAssertNil(copy.reminderID)
    XCTAssertFalse(copy.calendarWasExported)
    XCTAssertFalse(copy.reminderWasCreated)
    XCTAssertFalse(copy.calendarUsesTentativeAvailability)
    XCTAssertNil(copy.calendarSyncPending)
    XCTAssertNil(copy.reminderSyncPending)
    XCTAssertNil(copy.calendarLastKnownStartDate)
    XCTAssertNil(copy.calendarExternalID)
  }

  @MainActor
  func testManualSessionCanBeCreatedAndEditedWithoutExternalAccess() async throws {
    let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let url = directory.appending(path: "plan.json")
    let store = TrainingPlannerStore(url: url, observeChanges: false, externalAccessDisabled: true)
    let id = store.create(activity: .cycling, startDate: now, durationMinutes: 45, muscles: [], state: .confirmed)!
    XCTAssertFalse(store.calendarAccess)
    XCTAssertFalse(store.reminderAccess)
    XCTAssertFalse(store.isWorking)
    XCTAssertEqual(store.entries.first?.isManualSession, true)
    let edited = await store.update(id: id, startDate: day(2), durationMinutes: 75,
      activity: .functionalStrength, muscles: [.back, .core], state: .suggested)
    XCTAssertTrue(edited)
    let entry = store.entries.first!
    XCTAssertEqual(entry.activity, .functionalStrength)
    XCTAssertEqual(entry.startDate, day(2))
    XCTAssertEqual(entry.durationMinutes, 75)
    XCTAssertEqual(entry.muscles, [.back, .core])
    XCTAssertEqual(entry.state, .suggested)
    XCTAssertFalse(entry.calendarWasExported)
    XCTAssertNil(entry.calendarEventID)
    XCTAssertFalse(store.isWorking)
    XCTAssertEqual(TrainingPlannerStore(url: url, observeChanges: false, externalAccessDisabled: true).entries, [entry])
  }

  @MainActor
  func testInvalidManualCreateAndEditLeaveSavedPlanUntouched() async throws {
    let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let url = directory.appending(path: "plan.json")
    let store = TrainingPlannerStore(url: url, observeChanges: false, externalAccessDisabled: true)
    XCTAssertNil(store.create(activity: .walking, startDate: now, durationMinutes: 0, muscles: [], state: .confirmed))
    XCTAssertTrue(store.entries.isEmpty)
    let id = store.create(activity: .walking, startDate: now, durationMinutes: 30, muscles: [], state: .confirmed)!
    let before = store.entries
    let beforeData = try Data(contentsOf: url)
    let changed = await store.update(id: id, startDate: day(1), durationMinutes: 1_441)
    XCTAssertFalse(changed)
    XCTAssertEqual(store.entries, before)
    XCTAssertEqual(try Data(contentsOf: url), beforeData)
    XCTAssertNotNil(store.lastError)
  }

  @MainActor
  func testLinkedEditIsSavedPendingWhenCalendarAndRemindersAreUnavailable() async throws {
    struct Fixture: Encodable {
      var version = 1
      var entries: [PlanEntry]
      var calendarID = "fixture-calendar"
      var reminderListID = "fixture-list"
      var remindersEnabled = true
      var syncReminderCompletion = true
    }
    let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let url = directory.appending(path: "plan.json")
    var original = PlanEntry(activity: .running, startDate: now, durationMinutes: 25)
    original.state = .confirmed
    original.calendarEventID = "owned-event"
    original.calendarWasExported = true
    original.reminderID = "owned-reminder"
    original.reminderWasCreated = true
    try JSONEncoder().encode(Fixture(entries: [original])).write(to: url)
    let store = TrainingPlannerStore(url: url, observeChanges: false, externalAccessDisabled: true)
    let saved = await store.update(id: original.id, startDate: day(30), durationMinutes: 40,
      activity: .cycling, muscles: [.core], state: .completed)
    XCTAssertTrue(saved)
    let edited = store.entries.first!
    XCTAssertEqual(edited.startDate, day(30))
    XCTAssertEqual(edited.durationMinutes, 40)
    XCTAssertEqual(edited.activity, .cycling)
    XCTAssertEqual(edited.state, .completed)
    XCTAssertEqual(edited.calendarEventID, original.calendarEventID)
    XCTAssertEqual(edited.reminderID, original.reminderID)
    XCTAssertEqual(edited.calendarSyncPending, true)
    XCTAssertEqual(edited.reminderSyncPending, true)
    XCTAssertEqual(edited.calendarLastKnownStartDate, original.startDate)
    XCTAssertFalse(store.isWorking)
    await store.reconcile()
    XCTAssertEqual(store.entries, [edited])
    XCTAssertEqual(TrainingPlannerStore(url: url, observeChanges: false, externalAccessDisabled: true).entries, [edited])
    // Another offline move must keep the Calendar date, rather than the first
    // unsynced local date, as the anchor for identifier recovery.
    let movedAgain = await store.update(id: original.id, startDate: day(60), durationMinutes: 45)
    XCTAssertTrue(movedAgain)
    let latest = store.entries.first!
    XCTAssertEqual(latest.startDate, day(60))
    XCTAssertEqual(latest.calendarLastKnownStartDate, original.startDate)
    XCTAssertEqual(latest.calendarEventID, original.calendarEventID)
    XCTAssertEqual(latest.calendarSyncPending, true)
    XCTAssertEqual(TrainingPlannerStore(url: url, observeChanges: false, externalAccessDisabled: true).entries, [latest])
  }

  @MainActor
  func testDuplicateRescheduleAndRegeneratePreserveManualSessionsOffline() throws {
    let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let url = directory.appending(path: "plan.json")
    let store = TrainingPlannerStore(url: url, observeChanges: false, externalAccessDisabled: true)
    let id = store.create(activity: .functionalStrength, startDate: now, durationMinutes: 50,
      muscles: [.back, .core], state: .suggested)!
    let original = store.entries.first!
    let copyID = store.duplicate(id: id, startDate: day(1))!
    XCTAssertTrue(store.reschedule(id: copyID, days: 7, calendar: calendar))
    let copy = store.entries.first { $0.id == copyID }!
    XCTAssertEqual(copy.startDate, day(8))
    XCTAssertEqual(copy.muscles, original.muscles)
    XCTAssertEqual(copy.durationMinutes, original.durationMinutes)
    XCTAssertNil(copy.calendarEventID)
    XCTAssertNil(copy.reminderID)
    XCTAssertEqual(store.entries.first { $0.id == id }, original)
    store.generateWeek(workouts: [], categories: [.endurance, .mobility], now: now, calendar: calendar)
    XCTAssertEqual(store.entries.first { $0.id == id }, original)
    XCTAssertEqual(store.entries.first { $0.id == copyID }, copy)
    XCTAssertEqual(TrainingPlannerStore(url: url, observeChanges: false, externalAccessDisabled: true).entries, store.entries)
  }

  @MainActor
  func testRescheduleKeepsLocalTimeAcrossDaylightSavingChange() {
    let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let store = TrainingPlannerStore(url: directory.appending(path: "plan.json"), observeChanges: false,
      externalAccessDisabled: true)
    var local = Calendar(identifier: .gregorian)
    local.timeZone = TimeZone(identifier: "America/New_York")!
    let start = ISO8601DateFormatter().date(from: "2026-10-31T21:00:00Z")!
    let id = store.create(activity: .walking, startDate: start, durationMinutes: 30, muscles: [], state: .confirmed)!
    XCTAssertTrue(store.reschedule(id: id, days: 1, calendar: local))
    let moved = store.entries.first!
    XCTAssertEqual(local.component(.hour, from: moved.startDate), 17)
    XCTAssertEqual(moved.startDate.timeIntervalSince(start), 25 * 3_600)
  }

  @MainActor
  func testLocalPlanPersistsAndWriteFailureRollsBack() throws {
    let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let url = directory.appending(path: "plan.json")
    let store = TrainingPlannerStore(url: url, observeChanges: false, externalAccessDisabled: true)
    store.generateWeek(workouts: [], categories: [.endurance], now: now, calendar: calendar)
    XCTAssertEqual(store.entries.count, 3)
    XCTAssertEqual(TrainingPlannerStore(url: url, observeChanges: false, externalAccessDisabled: true).entries, store.entries)

    let blockedParent = directory.appending(path: "blocked")
    let blocked = TrainingPlannerStore(url: blockedParent.appending(path: "plan.json"), observeChanges: false, externalAccessDisabled: true)
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
    let store = TrainingPlannerStore(url: url, observeChanges: false, externalAccessDisabled: true)
    store.generateWeek(workouts: [], categories: [.mobility], now: now, calendar: calendar)
    XCTAssertTrue(store.entries.isEmpty)
    XCTAssertNotNil(store.lastError)
    XCTAssertEqual(try Data(contentsOf: url), original)
  }
}
