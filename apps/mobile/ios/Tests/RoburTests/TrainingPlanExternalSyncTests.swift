import XCTest
@testable import Robur

final class TrainingPlanExternalSyncTests: XCTestCase {
  private let now = ISO8601DateFormatter().date(from: "2026-11-01T12:00:00Z")!
  private func date(_ seconds: Double) -> Date { now.addingTimeInterval(seconds) }
  private var session: PlanEntry {
    PlanEntry(activity: .functionalStrength, startDate: now, durationMinutes: 45, muscles: [.back, .core])
  }

  func testUnchangedExternalSnapshotCannotRevertNewLocalState() {
    XCTAssertFalse(TrainingPlanExternalSync.shouldImport(modified: date(10), observed: date(10),
      pending: false, competing: []))
    XCTAssertFalse(TrainingPlanExternalSync.shouldImport(modified: date(9), observed: date(10),
      pending: true, competing: []))
    XCTAssertTrue(TrainingPlanExternalSync.shouldImport(modified: date(10), observed: date(10),
      pending: false, competing: [], contentChanged: true))
    XCTAssertFalse(TrainingPlanExternalSync.shouldImport(modified: date(10), observed: date(10),
      pending: true, competing: [], contentChanged: true))
    XCTAssertFalse(TrainingPlanExternalSync.shouldImport(modified: date(9), observed: date(10),
      pending: false, competing: [], contentChanged: true))
  }

  func testPendingSessionEditsUseMeaningfulModificationClock() {
    XCTAssertFalse(TrainingPlanExternalSync.shouldImport(modified: date(19), observed: date(10),
      pending: true, competing: [date(20)]))
    XCTAssertTrue(TrainingPlanExternalSync.shouldImport(modified: date(21), observed: date(10),
      pending: true, competing: [date(20)]))
    XCTAssertFalse(TrainingPlanExternalSync.shouldImport(modified: nil, observed: date(10),
      pending: true, competing: [date(20)]))
  }

  func testMetadataUpgradeCannotHideOfflineReminderChange() {
    // A Calendar title upgrade at t20 is not a session edit competing with an
    // observed-at-t10 reminder checked offline at t19.
    XCTAssertTrue(TrainingPlanExternalSync.shouldImport(modified: date(19), observed: date(10),
      pending: false, competing: [date(20)]))
    XCTAssertTrue(TrainingPlanExternalSync.shouldImport(modified: nil, observed: nil,
      pending: false, competing: []))
  }

  func testReminderConfirmsCompletesAndCanReopenItsLinkedPlan() {
    var entry = session
    XCTAssertTrue(TrainingPlanExternalSync.reconcileReminder(entry: &entry, due: date(3_600),
      title: "Gym with Alex", isCompleted: false))
    XCTAssertEqual(entry.state, .confirmed)
    XCTAssertEqual(entry.startDate, date(3_600))
    XCTAssertEqual(entry.durationMinutes, 45)
    XCTAssertTrue(TrainingPlanExternalSync.reconcileReminder(entry: &entry, due: nil,
      title: "Gym with Alex", isCompleted: true))
    XCTAssertEqual(entry.state, .completed)
    entry.reminderLastSyncedCompleted = true
    XCTAssertTrue(TrainingPlanExternalSync.reconcileReminder(entry: &entry, due: nil,
      title: "[Completed] Gym with Alex", isCompleted: false))
    XCTAssertEqual(entry.state, .confirmed)
    XCTAssertFalse(TrainingPlanExternalSync.reconcileReminder(entry: &entry, due: nil,
      title: "Gym with Alex", isCompleted: false))
    entry.startDate = date(3_625)
    XCTAssertFalse(TrainingPlanExternalSync.reconcileReminder(entry: &entry, due: date(3_600),
      title: "Gym with Alex", isCompleted: false))
    XCTAssertEqual(entry.startDate, date(3_625)) // Reminders' minute precision cannot erase seconds.
  }

  func testCustomTitlesKeepNameAndReplaceMuscleSummaryWithoutStackingMarkers() {
    var entry = session
    let first = TrainingPlanExternalSync.title(existing: "[Suggested] Lunch lift", entry: entry)
    XCTAssertEqual(first, "[Suggested] Lunch lift · Muscle focus: Back, Core")
    entry.muscles = [.quads, .hamstrings, .glutes, .calves]
    entry.state = .completed
    let updated = TrainingPlanExternalSync.title(existing: first, entry: entry)
    XCTAssertEqual(updated, "[Completed] Lunch lift · Muscle focus: Lower body")
    XCTAssertEqual(TrainingPlanExternalSync.title(existing: updated, entry: entry), updated)
    entry.activity = .cycling
    XCTAssertEqual(TrainingPlanExternalSync.title(existing: updated, entry: entry), "[Completed] Lunch lift")
    XCTAssertEqual(TrainingPlanExternalSync.title(existing: "Running · trail group — Robur", entry: entry),
      "[Completed] Running · trail group — Robur")
  }

  func testOldManagedTitlesUpgradeActivityAndMuscleSummary() {
    var entry = session
    XCTAssertEqual(TrainingPlanExternalSync.title(existing: "[Suggested] Functional strength — Robur", entry: entry), entry.calendarTitle)
    entry.activity = .traditionalStrength
    XCTAssertEqual(TrainingPlanExternalSync.title(existing: "Functional strength · Back, Core — Robur", entry: entry), entry.calendarTitle)
  }

  func testManagedNotesRetainPersonalNotesAndOwnershipAfterRepeatedUpdates() {
    let entry = session
    let old = "Bring straps\nEditable Robur training plan. Confirm in Robur or remove [Suggested] in Calendar.\nRobur plan ID: \(entry.id.uuidString)\n\(entry.url.absoluteString)"
    let updated = TrainingPlanExternalSync.notes(existing: old, entry: entry)
    XCTAssertTrue(updated.hasPrefix("Bring straps\n\n"))
    XCTAssertTrue(updated.components(separatedBy: .newlines).contains("Robur plan ID: \(entry.id.uuidString)"))
    XCTAssertTrue(updated.contains("Muscle groups: Back, Core"))
    XCTAssertEqual(TrainingPlanExternalSync.notes(existing: updated, entry: entry), updated)
    var moved = entry; moved.muscles = [.chest]
    let next = TrainingPlanExternalSync.notes(existing: updated, entry: moved)
    XCTAssertTrue(next.contains("Muscle groups: Chest"))
    XCTAssertFalse(next.contains("Muscle groups: Back, Core"))
  }

  func testDateOnlyReminderRetainsWorkoutTimeInItsTimeZone() {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(identifier: "Europe/Berlin")!
    let fallback = calendar.date(from: DateComponents(year: 2026, month: 10, day: 23, hour: 18, minute: 30))!
    var due = DateComponents(year: 2026, month: 11, day: 2)
    due.calendar = calendar; due.timeZone = calendar.timeZone
    let actual = TrainingPlanExternalSync.reminderDate(due, fallback: fallback)!
    let components = calendar.dateComponents([.year, .month, .day, .hour, .minute], from: actual)
    XCTAssertEqual(components.day, 2)
    XCTAssertEqual(components.hour, 18)
    XCTAssertEqual(components.minute, 30)
    due.hour = 7; due.minute = 15
    let timed = TrainingPlanExternalSync.reminderDate(due, fallback: fallback)!
    XCTAssertEqual(calendar.component(.hour, from: timed), 7)
    XCTAssertEqual(calendar.component(.minute, from: timed), 15)
    XCTAssertTrue(TrainingPlanExternalSync.sameReminderDate(due, sessionStart: timed.addingTimeInterval(25)))
    var normalized = due
    normalized.calendar = nil
    XCTAssertTrue(TrainingPlanExternalSync.sameReminderDate(normalized, sessionStart: timed))
    due.month = 2; due.day = 31
    XCTAssertNil(TrainingPlanExternalSync.reminderDate(due, fallback: fallback))
    XCTAssertNil(TrainingPlanExternalSync.reminderDate(DateComponents(hour: 7), fallback: fallback))
  }

  @MainActor
  func testOldArchiveEnablesCheckboxSyncAndRetainsReminderLinkedSuggestions() async throws {
    struct OldArchive: Encodable {
      var version = 1
      var entries: [PlanEntry]
      var calendarID: String? = nil
      var reminderListID: String? = nil
      var remindersEnabled = true
      var syncReminderCompletion = false
    }
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let url = directory.appendingPathComponent("plan.json")
    var linked = session
    linked.reminderWasCreated = true
    linked.reminderID = "owned-reminder"
    try JSONEncoder().encode(OldArchive(entries: [linked])).write(to: url)
    let store = TrainingPlannerStore(url: url, observeChanges: false, externalAccessDisabled: true)
    XCTAssertTrue(store.syncReminderCompletion)
    await store.generateWeek(workouts: [], categories: [.strength], now: now)
    XCTAssertEqual(store.entries.first(where: { $0.id == linked.id }), linked)
  }
}
