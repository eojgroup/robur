import XCTest
@testable import Robur

final class TrainingCalendarTests: XCTestCase {
  private let now = ISO8601DateFormatter().date(from: "2026-11-03T12:00:00Z")!
  private var session: PlanEntry { PlanEntry(activity: .running, startDate: now, durationMinutes: 60) }
  private func event(_ id: String, start: Double, end: Double, blocksTime: Bool = true,
                     linkedPlanID: UUID? = nil) -> TrainingCalendarEvent {
    .init(id: id, title: id, calendarTitle: "Work", startDate: now.addingTimeInterval(start * 60),
      endDate: now.addingTimeInterval(end * 60), blocksTime: blocksTime, linkedPlanID: linkedPlanID)
  }

  func testSelfLinkedEventsFreeEventsAndTouchingBoundariesAreNotConflicts() {
    let entry = session
    let events = [event("self", start: 0, end: 60, linkedPlanID: entry.id),
      event("free", start: 0, end: 60, blocksTime: false),
      event("after", start: 60, end: 90), event("before", start: -30, end: 0)]
    XCTAssertTrue(TrainingCalendar.conflicts(for: entry, events: events, plans: [entry]).isEmpty)
    XCTAssertEqual(TrainingCalendar.overlappingMinutes(for: entry, events: events, plans: [entry]), 0)
  }

  func testOverlappingCalendarEventsAndPlansCountTheirUnionOnly() {
    let entry = session
    let events = [event("first", start: 10, end: 40), event("second", start: 20, end: 50)]
    let other = PlanEntry(activity: .cycling, startDate: now.addingTimeInterval(30 * 60), durationMinutes: 30)
    let conflicts = TrainingCalendar.conflicts(for: entry, events: events, plans: [other])
    XCTAssertEqual(conflicts.count, 3)
    XCTAssertEqual(TrainingCalendar.overlappingMinutes(for: entry, events: events), 40)
    XCTAssertEqual(TrainingCalendar.overlappingMinutes(for: entry, events: events, plans: [other]), 50)
  }

  func testLinkedCalendarEventAndItsLocalPlanAppearOnlyOnce() {
    let entry = session
    let other = PlanEntry(activity: .functionalStrength, startDate: now.addingTimeInterval(15 * 60), durationMinutes: 30)
    let linked = event("linked", start: 15, end: 45, linkedPlanID: other.id)
    let conflicts = TrainingCalendar.conflicts(for: entry, events: [linked, linked], plans: [entry, other, other])
    XCTAssertEqual(conflicts.count, 1)
    XCTAssertEqual(conflicts.first?.planID, other.id)
    XCTAssertEqual(conflicts.first?.isPlannedSession, true)
    XCTAssertEqual(TrainingCalendar.overlappingMinutes(for: entry, events: [linked], plans: [other]), 30)
  }

  func testAllDayEventWarnsForTheWholeSessionAndInvalidEventsAreIgnored() {
    let entry = session
    var allDay = event("holiday", start: -12 * 60, end: 12 * 60)
    allDay.isAllDay = true
    let invalid = event("invalid", start: 30, end: 20)
    let conflicts = TrainingCalendar.conflicts(for: entry, events: [allDay, invalid])
    XCTAssertEqual(conflicts.count, 1)
    XCTAssertEqual(conflicts.first?.isAllDay, true)
    XCTAssertEqual(TrainingCalendar.overlappingMinutes(for: entry, events: [allDay, invalid]), 60)
  }

  func testAChangedDraftDoesNotConflictWithItsOldCalendarTime() {
    var entry = session
    let original = entry
    let own = event("own old title", start: 20, end: 80, linkedPlanID: entry.id)
    entry.startDate = now.addingTimeInterval(30 * 60)
    XCTAssertTrue(TrainingCalendar.conflicts(for: entry, events: [own], plans: [original]).isEmpty)
  }

  func testOverlapAcrossRepeatedDSTHourUsesElapsedTime() {
    let formatter = ISO8601DateFormatter()
    let start = formatter.date(from: "2026-10-25T00:30:00Z")!
    let entry = PlanEntry(activity: .running, startDate: start, durationMinutes: 90)
    let event = TrainingCalendarEvent(id: "repeated hour", title: "Meeting", calendarTitle: "Work",
      startDate: formatter.date(from: "2026-10-25T00:45:00Z")!, endDate: formatter.date(from: "2026-10-25T01:30:00Z")!)
    XCTAssertEqual(TrainingCalendar.overlappingMinutes(for: entry, events: [event]), 45)
  }
}
