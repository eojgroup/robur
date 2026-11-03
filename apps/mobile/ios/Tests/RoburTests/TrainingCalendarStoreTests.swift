import Combine
import XCTest
@testable import Robur

@MainActor
final class TrainingCalendarStoreTests: XCTestCase {
  private final class Worker: TrainingPlanEventWorking {
    var events: [TrainingCalendarEvent] = []
    var eventError: Error?
    var requests: [DateInterval] = []
    var holdNext = false
    var started: (() -> Void)?
    var continuation: CheckedContinuation<Void, Never>?

    func requestAccess(reminders: Bool) async throws -> Bool { true }
    func availability(now: Date, calendar: Calendar) async throws -> [DateInterval] { [] }
    func calendarEvents(in interval: DateInterval) async throws -> [TrainingCalendarEvent] {
      requests.append(interval)
      let snapshot = events
      if holdNext {
        holdNext = false
        await withCheckedContinuation { continuation in self.continuation = continuation; started?() }
      }
      if let eventError { throw eventError }
      return snapshot
    }
    func refresh(entries: [PlanEntry], settings: TrainingPlanEventWorker.Settings) async throws -> TrainingPlanEventWorker.Snapshot {
      .init(entries: entries, calendarAccess: true, reminderAccess: false,
        calendars: [.init(calendarIdentifier: "calendar", title: "Training")], reminderLists: [],
        defaultCalendarID: "calendar", defaultReminderListID: nil, busy: [])
    }
    func syncCalendarChanges(entries: [PlanEntry]) async throws -> [PlanEntry] { entries }
    func syncReminders(entries: [PlanEntry], settings: TrainingPlanEventWorker.Settings) async throws -> [PlanEntry] { entries }
    func remove(entry: PlanEntry, includeReminders: Bool) async throws {}
    func export(entries: [PlanEntry], settings: TrainingPlanEventWorker.Settings, ids: Set<UUID>?, allowReExport: Bool,
                progress: @escaping ([PlanEntry]) -> Void) async throws -> TrainingPlanEventWorker.ExportResult {
      var next = entries
      for index in next.indices where ids?.contains(next[index].id) ?? true {
        next[index].calendarEventID = "added-despite-overlap"
        next[index].calendarWasExported = true
      }
      progress(next)
      return .init(entries: next, inserted: 1, conflicting: 1)
    }
    func resume() { continuation?.resume(); continuation = nil }
  }

  private let start = ISO8601DateFormatter().date(from: "2026-11-03T00:00:00Z")!
  private var week: DateInterval { DateInterval(start: start, duration: 7 * 86_400) }
  private func event(title: String = "Private calendar appointment", day: Int = 0) -> TrainingCalendarEvent {
    let date = start.addingTimeInterval(Double(day * 86_400 + 12 * 3_600))
    return TrainingCalendarEvent(id: "external-\(day)", title: title, calendarTitle: "Work",
      startDate: date, endDate: date.addingTimeInterval(3_600))
  }
  private func file() -> URL { FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".json") }

  func testExportKeepsCalendarLinkAndReportsOverlapAsAdvisory() async throws {
    let url = file(); defer { try? FileManager.default.removeItem(at: url) }
    let worker = Worker()
    let store = TrainingPlannerStore(url: url, observeChanges: false, worker: worker)
    let id = try XCTUnwrap(store.create(activity: .cycling, startDate: Date().addingTimeInterval(86_400), durationMinutes: 30))
    await store.exportPlaceholders(ids: [id])
    XCTAssertEqual(store.entries.first?.calendarEventID, "added-despite-overlap")
    XCTAssertTrue(store.actionMessage?.contains("Added 1") == true)
    XCTAssertTrue(store.actionMessage?.contains("overlaps") == true)
    XCTAssertFalse(store.actionMessage?.contains("try again") == true)
    XCTAssertNil(store.lastError)
    store.cancelSync()
  }

  func testCalendarContextReloadsAfterSyncAndNeverEntersArchive() async throws {
    let url = file(); defer { try? FileManager.default.removeItem(at: url) }
    let worker = Worker(); worker.events = [event()]
    let store = TrainingPlannerStore(url: url, observeChanges: false, worker: worker)
    await store.loadCalendarEvents(in: week)
    XCTAssertEqual(store.calendarEvents, worker.events)
    XCTAssertEqual(store.calendarWindow, week)
    XCTAssertTrue(store.calendarAccess)
    worker.events = [event(title: "Moved private appointment")]
    await store.reconcile()
    XCTAssertEqual(store.calendarEvents, worker.events)
    XCTAssertEqual(worker.requests, [week, week])
    let archive = try String(contentsOf: url, encoding: .utf8)
    XCTAssertFalse(archive.contains("private appointment"))
    XCTAssertFalse(archive.contains("Private calendar appointment"))
  }

  func testLateCalendarResponseCannotReplaceNewlySelectedWeek() async throws {
    let url = file(); defer { try? FileManager.default.removeItem(at: url) }
    let worker = Worker(); worker.events = [event()]
    let store = TrainingPlannerStore(url: url, observeChanges: false, worker: worker)
    await store.loadCalendarEvents(in: week)
    worker.holdNext = true
    let started = expectation(description: "Previous week refresh started")
    worker.started = { started.fulfill() }
    let oldRefresh = Task { await store.loadCalendarEvents(in: week) }
    await fulfillment(of: [started], timeout: 2)
    let cleared = expectation(description: "Changing weeks clears old events")
    let observation = store.$calendarWindow.dropFirst().sink { value in if value == nil { cleared.fulfill() } }
    let nextWeek = DateInterval(start: week.end, duration: 7 * 86_400)
    worker.events = [event(title: "Next week appointment", day: 8)]
    let nextRefresh = Task { await store.loadCalendarEvents(in: nextWeek) }
    await fulfillment(of: [cleared], timeout: 2)
    XCTAssertTrue(store.calendarEvents.isEmpty)
    worker.resume()
    await oldRefresh.value; await nextRefresh.value
    withExtendedLifetime(observation) {}
    XCTAssertEqual(store.calendarWindow, nextWeek)
    XCTAssertEqual(store.calendarEvents, worker.events)
    XCTAssertFalse(store.calendarEventsLoading)
  }

  func testFailedRefreshClearsStaleCalendarInsteadOfImplyingAvailability() async {
    let url = file(); defer { try? FileManager.default.removeItem(at: url) }
    let worker = Worker(); worker.events = [event()]
    let store = TrainingPlannerStore(url: url, observeChanges: false, worker: worker)
    await store.loadCalendarEvents(in: week)
    worker.eventError = NSError(domain: "Calendar unavailable", code: 1)
    await store.loadCalendarEvents(in: week)
    XCTAssertTrue(store.calendarEvents.isEmpty)
    XCTAssertNil(store.calendarWindow)
    XCTAssertNotNil(store.calendarEventsError)
    XCTAssertFalse(store.calendarEventsLoading)
  }

  func testCalendarQueriesRejectUnboundedRanges() async {
    let url = file(); defer { try? FileManager.default.removeItem(at: url) }
    let worker = Worker()
    let store = TrainingPlannerStore(url: url, observeChanges: false, worker: worker)
    await store.loadCalendarEvents(in: DateInterval(start: start, duration: 36 * 86_400))
    XCTAssertTrue(worker.requests.isEmpty)
    XCTAssertNil(store.calendarWindow)
    XCTAssertNotNil(store.calendarEventsError)
    XCTAssertFalse(store.calendarEventsLoading)
  }
}
