import XCTest
@testable import Robur

@MainActor
final class TrainingPlannerActionTests: XCTestCase {
  private final class Worker: TrainingPlanEventWorking {
    var holdRefresh = false
    var refreshStarted: (() -> Void)?
    var refreshContinuation: CheckedContinuation<Void, Never>?
    var exports = 0
    var reminderSyncs = 0
    var deletedCalendar = false
    var removalError: Error?
    var removed: [(UUID, Bool)] = []

    func requestAccess(reminders: Bool) async throws -> Bool { true }
    func availability(now: Date, calendar: Calendar) async throws -> [DateInterval] { [] }
    func refresh(entries: [PlanEntry], settings: TrainingPlanEventWorker.Settings) async throws -> TrainingPlanEventWorker.Snapshot {
      if holdRefresh {
        await withCheckedContinuation { continuation in
          refreshContinuation = continuation
          refreshStarted?()
        }
      }
      var next = entries
      if deletedCalendar { for index in next.indices { next[index].calendarEventID = nil } }
      return .init(entries: next, calendarAccess: true, reminderAccess: true,
        calendars: [.init(calendarIdentifier: "calendar", title: "Training")],
        reminderLists: [.init(calendarIdentifier: "reminders", title: "Training")],
        defaultCalendarID: "calendar", defaultReminderListID: "reminders", busy: [])
    }
    func syncCalendarChanges(entries: [PlanEntry]) async throws -> [PlanEntry] { entries }
    func export(entries: [PlanEntry], settings: TrainingPlanEventWorker.Settings, ids: Set<UUID>?, allowReExport: Bool,
                progress: @escaping ([PlanEntry]) -> Void) async throws -> TrainingPlanEventWorker.ExportResult {
      exports += 1
      var next = entries
      var inserted = 0
      for index in next.indices where ids?.contains(next[index].id) ?? true {
        guard next[index].calendarEventID == nil else { continue }
        next[index].calendarEventID = "event-\(next[index].id)"
        next[index].calendarWasExported = true
        next[index].calendarSyncPending = nil
        inserted += 1
      }
      progress(next)
      return .init(entries: next, inserted: inserted)
    }
    func remove(entry: PlanEntry, includeReminders: Bool) async throws {
      if let removalError { throw removalError }
      removed.append((entry.id, includeReminders))
    }
    func syncReminders(entries: [PlanEntry], settings: TrainingPlanEventWorker.Settings) async throws -> [PlanEntry] {
      reminderSyncs += 1
      return entries.map { entry in
        var next = entry
        if next.calendarWasExported && next.calendarEventID == nil {
          next.reminderID = nil; next.reminderWasCreated = true; next.reminderSyncPending = nil
        }
        return next
      }
    }
    func releaseRefresh() {
      holdRefresh = false
      refreshContinuation?.resume(); refreshContinuation = nil
    }
  }

  private func file() -> URL { FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".json") }
  private struct Archive: Encodable {
    var version = 1
    let entries: [PlanEntry]
    var calendarID = "calendar"
    var reminderListID = "reminders"
    var remindersEnabled = false
    var syncReminderCompletion = true
  }
  private func linkedSession() -> PlanEntry {
    var entry = PlanEntry(activity: .running, startDate: Date().addingTimeInterval(86_400), durationMinutes: 30)
    entry.calendarWasExported = true; entry.calendarEventID = "owned-event"
    entry.reminderWasCreated = true; entry.reminderID = "owned-reminder"
    return entry
  }

  func testAddWaitsForRefreshAndExportsLatestLocalEditInsteadOfDroppingTap() async throws {
    let url = file(); defer { try? FileManager.default.removeItem(at: url) }
    let worker = Worker()
    let store = TrainingPlannerStore(url: url, observeChanges: false, worker: worker)
    let start = Date().addingTimeInterval(86_400)
    let id = try XCTUnwrap(store.create(activity: .cycling, startDate: start, durationMinutes: 30))
    let started = expectation(description: "Refresh started")
    worker.holdRefresh = true; worker.refreshStarted = { started.fulfill() }
    let refresh = Task { await store.reconcile() }
    await fulfillment(of: [started], timeout: 2)
    let add = Task { await store.exportPlaceholders(ids: [id]) }
    _ = await store.update(id: id, startDate: start.addingTimeInterval(3_600), durationMinutes: 45)
    XCTAssertEqual(worker.exports, 0)
    worker.releaseRefresh()
    await refresh.value; await add.value
    XCTAssertEqual(worker.exports, 1)
    XCTAssertNotNil(store.entries.first?.calendarEventID)
    XCTAssertEqual(store.entries.first?.durationMinutes, 45)
    XCTAssertEqual(store.entries.first?.startDate, start.addingTimeInterval(3_600))
    XCTAssertTrue(store.actionMessage?.contains("Added 1") == true)
    store.cancelSync()
  }

  func testDeletingCalendarAlsoCleansReminderWhenReminderSyncIsOff() async throws {
    let url = file(); defer { try? FileManager.default.removeItem(at: url) }
    let entry = linkedSession()
    try JSONEncoder().encode(Archive(entries: [entry])).write(to: url)
    let worker = Worker(); worker.deletedCalendar = true
    let store = TrainingPlannerStore(url: url, observeChanges: false, worker: worker)
    await store.reconcile()
    XCTAssertEqual(worker.reminderSyncs, 1)
    XCTAssertNil(store.entries.first?.calendarEventID)
    XCTAssertNil(store.entries.first?.reminderID)
    XCTAssertTrue(store.entries.first?.reminderWasCreated == true)
  }

  func testRemoveCalendarRequestsReminderCleanupAndKeepsDeletionTombstones() async throws {
    let url = file(); defer { try? FileManager.default.removeItem(at: url) }
    let entry = linkedSession()
    try JSONEncoder().encode(Archive(entries: [entry])).write(to: url)
    let worker = Worker()
    let store = TrainingPlannerStore(url: url, observeChanges: false, worker: worker)
    await store.removeCalendarPlaceholder(id: entry.id)
    XCTAssertEqual(worker.removed.count, 1)
    XCTAssertEqual(worker.removed.first?.0, entry.id)
    XCTAssertEqual(worker.removed.first?.1, true)
    XCTAssertNil(store.entries.first?.reminderID)
    XCTAssertTrue(store.entries.first?.calendarWasExported == true)
    XCTAssertTrue(store.entries.first?.reminderWasCreated == true)
    let reloaded = TrainingPlannerStore(url: url, observeChanges: false, externalAccessDisabled: true)
    XCTAssertEqual(reloaded.entries, store.entries)
  }

  func testFailedExternalDeletionPreservesSessionAndErrorAcrossLocalSaves() async throws {
    let url = file(); defer { try? FileManager.default.removeItem(at: url) }
    let entry = linkedSession()
    try JSONEncoder().encode(Archive(entries: [entry])).write(to: url)
    let worker = Worker(); worker.removalError = NSError(domain: "Calendar", code: 1)
    let store = TrainingPlannerStore(url: url, observeChanges: false, worker: worker)
    await store.removeSession(id: entry.id)
    XCTAssertEqual(store.entries, [entry])
    XCTAssertNotNil(store.actionMessage)
    let error = store.lastError
    store.chooseCalendar("calendar")
    XCTAssertEqual(store.lastError, error)
    worker.removalError = nil
    await store.removeSession(id: entry.id)
    XCTAssertTrue(store.entries.isEmpty)
    XCTAssertEqual(worker.removed.first?.1, true)
  }
}
