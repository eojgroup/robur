import Foundation

/// A transient, on-device projection of readable Calendar events for planning.
/// EventKit objects and calendar contents are never written into the plan archive.
struct TrainingCalendarEvent: Identifiable, Equatable {
  let id: String
  let title: String
  let calendarTitle: String
  let startDate: Date
  let endDate: Date
  var isAllDay = false
  var blocksTime = true
  var linkedPlanID: UUID?

  var isValid: Bool {
    startDate.timeIntervalSince1970.isFinite && endDate.timeIntervalSince1970.isFinite && endDate > startDate
  }
}

struct TrainingCalendarConflict: Identifiable, Equatable {
  let id: String
  let title: String
  let calendarTitle: String
  let startDate: Date
  let endDate: Date
  let isAllDay: Bool
  let isPlannedSession: Bool
  var planID: UUID?
}

enum TrainingCalendar {
  /// A session's own exported event is not a conflict. Other linked sessions are
  /// represented once using the current local plan, including pending edits.
  static func conflicts(for entry: PlanEntry, events: [TrainingCalendarEvent],
                        plans: [PlanEntry] = []) -> [TrainingCalendarConflict] {
    guard entry.isValid else { return [] }
    let interval = DateInterval(start: entry.startDate, end: entry.endDate)
    var seenPlans: Set<UUID> = []
    let validPlans = plans.filter { $0.isValid && $0.id != entry.id && seenPlans.insert($0.id).inserted }
    let represented = Set(validPlans.map(\.id))
    var result: [TrainingCalendarConflict] = []
    var seenEvents: Set<String> = []
    for event in events where event.isValid && event.blocksTime &&
      event.linkedPlanID != entry.id && seenEvents.insert(event.id).inserted {
      if let id = event.linkedPlanID, represented.contains(id) { continue }
      let occupied = DateInterval(start: event.startDate, end: event.endDate)
      guard TrainingPlanner.overlaps(interval, occupied) else { continue }
      result.append(.init(id: "calendar:\(event.id)", title: event.title,
        calendarTitle: event.calendarTitle, startDate: event.startDate, endDate: event.endDate,
        isAllDay: event.isAllDay, isPlannedSession: false, planID: event.linkedPlanID))
    }
    for plan in validPlans {
      let occupied = DateInterval(start: plan.startDate, end: plan.endDate)
      guard TrainingPlanner.overlaps(interval, occupied) else { continue }
      result.append(.init(id: "plan:\(plan.id.uuidString)", title: plan.activity.title,
        calendarTitle: "Robur plan", startDate: plan.startDate, endDate: plan.endDate,
        isAllDay: false, isPlannedSession: true, planID: plan.id))
    }
    return result.sorted {
      if $0.startDate != $1.startDate { return $0.startDate < $1.startDate }
      if $0.endDate != $1.endDate { return $0.endDate < $1.endDate }
      return $0.id < $1.id
    }
  }

  static func overlappingMinutes(for entry: PlanEntry, events: [TrainingCalendarEvent],
                                 plans: [PlanEntry] = []) -> Double {
    guard entry.isValid else { return 0 }
    let intervals = conflicts(for: entry, events: events, plans: plans).map {
      DateInterval(start: $0.startDate, end: $0.endDate)
    }
    return overlappingSeconds(in: DateInterval(start: entry.startDate, end: entry.endDate), with: intervals) / 60
  }

  /// Measure the union so simultaneous meetings do not count the same minutes
  /// twice. Boundary-touching events contribute zero actual overlap.
  static func overlappingSeconds(in interval: DateInterval, with occupied: [DateInterval]) -> TimeInterval {
    guard interval.start.timeIntervalSince1970.isFinite, interval.end.timeIntervalSince1970.isFinite,
          interval.end > interval.start else { return 0 }
    let clipped = occupied.compactMap { other -> DateInterval? in
      guard other.start.timeIntervalSince1970.isFinite, other.end.timeIntervalSince1970.isFinite,
            TrainingPlanner.overlaps(interval, other) else { return nil }
      return DateInterval(start: max(interval.start, other.start), end: min(interval.end, other.end))
    }
    return mergedIntervals(clipped).reduce(0) { $0 + $1.duration }
  }

  /// Normalize once before examining many candidate slots in a crowded calendar.
  static func mergedIntervals(_ intervals: [DateInterval]) -> [DateInterval] {
    let sorted = intervals.filter {
      $0.start.timeIntervalSince1970.isFinite && $0.end.timeIntervalSince1970.isFinite && $0.end > $0.start
    }.sorted { $0.start < $1.start }
    var merged: [DateInterval] = []
    var current: DateInterval?
    for next in sorted {
      if let previous = current {
        if next.start <= previous.end {
          current = DateInterval(start: previous.start, end: max(previous.end, next.end))
        } else {
          merged.append(previous)
          current = next
        }
      } else { current = next }
    }
    if let current { merged.append(current) }
    return merged
  }
}
