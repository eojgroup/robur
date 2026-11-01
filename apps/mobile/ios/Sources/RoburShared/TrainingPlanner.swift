import Foundation

enum PlanEntryState: String, Codable, CaseIterable {
  case suggested, confirmed, completed
  var title: String { rawValue.capitalized }
}

struct PlanEntry: Identifiable, Codable, Equatable {
  var id = UUID()
  var activity: WorkoutActivity
  var startDate: Date
  var durationMinutes: Int
  var muscles: Set<MuscleGroup> = []
  var state: PlanEntryState = .suggested
  var calendarEventID: String?
  var reminderID: String?
  // Preserve these after an external deletion: refreshing must never recreate an item.
  var calendarWasExported = false
  var reminderWasCreated = false
  var calendarUsesTentativeAvailability = false
  // Optional fields keep version-1 archives readable. Local edits remain authoritative
  // while an external app is unavailable, until that edit has been synchronized.
  var calendarSyncPending: Bool?
  var reminderSyncPending: Bool?
  var isManualSession: Bool?
  // Keep a bounded recovery anchor when an unsynced local edit moves the session.
  var calendarLastKnownStartDate: Date?
  var calendarExternalID: String?
  var calendarLastModifiedDate: Date?
  var reminderLastModifiedDate: Date?
  var localModificationDate: Date?
  var calendarLastSyncedTitle: String?
  var reminderLastSyncedTitle: String?
  var reminderLastSyncedCompleted: Bool?

  var endDate: Date { startDate.addingTimeInterval(Double(durationMinutes) * 60) }
  var url: URL { URL(string: "robur://plan/\(id.uuidString)")! }
  var muscleSummary: String {
    let upper: Set<MuscleGroup> = [.chest, .back, .shoulders, .arms]
    let lower: Set<MuscleGroup> = [.quads, .hamstrings, .glutes, .calves]
    if muscles == Set(MuscleGroup.allCases) { return "Full body" }
    if muscles == upper { return "Upper body" }
    if muscles == lower { return "Lower body" }
    if muscles == upper.union([.core]) { return "Upper body + Core" }
    if muscles == lower.union([.core]) { return "Lower body + Core" }
    return MuscleGroup.allCases.filter { muscles.contains($0) }.map(\.rawValue).joined(separator: ", ")
  }
  var calendarTitle: String {
    let focus = activity.category == .strength && !muscles.isEmpty ? " · \(muscleSummary)" : ""
    return Self.rewritingTitle("\(activity.title)\(focus) — Robur", state: state)
  }
  var reminderTitle: String { calendarTitle }

  /// Calendar has no completion checkbox. Explicit title markers provide a portable
  /// round trip, while a Reminders checkbox remains the simplest completion action.
  static func stateMarker(in title: String) -> PlanEntryState? {
    let value = title.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    return PlanEntryState.allCases.first { value.hasPrefix("[\($0.rawValue)]") }
  }

  static func rewritingTitle(_ title: String, state: PlanEntryState) -> String {
    var value = title.trimmingCharacters(in: .whitespacesAndNewlines)
    // Strip repeated recognized prefixes so successive updates cannot stack them.
    while let marker = stateMarker(in: value) {
      value = String(value.dropFirst(marker.rawValue.count + 2)).trimmingCharacters(in: .whitespacesAndNewlines)
    }
    switch state {
    case .suggested: return "[Suggested] \(value)"
    case .confirmed: return value
    case .completed: return "[Completed] \(value)"
    }
  }

  mutating func reconcileExternalTitle(_ title: String, isBusy: Bool = false) {
    let marker = Self.stateMarker(in: title)
    if marker == .completed { state = .completed }
    else if state == .suggested && (marker != .suggested || (calendarUsesTentativeAvailability && isBusy)) {
      state = .confirmed
    }
  }
  var isValid: Bool {
    startDate.timeIntervalSince1970.isFinite && (1...1_440).contains(durationMinutes)
  }

  /// A copy is a new local suggestion, never another association with the original's
  /// Calendar event or reminder. Export remains a separate, explicit action.
  func duplicated(startDate: Date) -> PlanEntry {
    var copy = PlanEntry(activity: activity, startDate: startDate, durationMinutes: durationMinutes, muscles: muscles)
    copy.isManualSession = true
    return copy
  }

  /// Calendar dates remain authoritative even while an entry is still a suggestion.
  /// Removing the marker (including a custom title) or changing tentative to Busy
  /// confirms it. Confirmation and completion never regress during reconciliation.
  mutating func reconcile(start: Date, end: Date, title: String, isBusy: Bool) {
    let minutes = end.timeIntervalSince(start) / 60
    guard start.timeIntervalSince1970.isFinite, minutes.isFinite, minutes > 0, minutes <= 1_440 else { return }
    startDate = start
    durationMinutes = max(1, Int(minutes.rounded()))
    reconcileExternalTitle(title, isBusy: isBusy)
  }
}

struct TrainingPlanSummary {
  let suggested: Int
  let confirmed: Int
  let completed: Int
  let minutes: Int
}

enum TrainingPlanner {
  /// A small, editable scheduling rule, based on recorded labels rather than a
  /// medical or recovery assessment. Calendar arithmetic preserves local days at DST.
  static func suggest(workouts: [WorkoutRecord], existing: [PlanEntry] = [],
                      annotations: [String: WorkoutAnnotation] = [:],
                      categories: Set<TrainingCategory> = [.endurance, .strength, .mobility],
                      preferredActivities: Set<WorkoutActivity> = [],
                      busy: [DateInterval] = [], now: Date = Date(),
                      startHour: Int = 7, endHour: Int = 21, transitionMinutes: Int = 10,
                      calendar: Calendar = .current) -> [PlanEntry] {
    guard !categories.isEmpty, (0...23).contains(startHour), (1...24).contains(endHour), endHour > startHour,
          let limit = calendar.date(byAdding: .day, value: 7, to: now) else { return [] }
    let recentStart = calendar.date(byAdding: .day, value: -28, to: now) ?? now
    var seen: Set<String> = []
    let recent = workouts.filter {
      $0.start >= recentStart && $0.start <= now && $0.minutes.isFinite && $0.minutes > 0 && seen.insert($0.id).inserted
    }
    let lastWeek = calendar.date(byAdding: .day, value: -7, to: now) ?? now
    let target = recent.filter { $0.start >= lastWeek }.count >= 4 ? 4 : 3
    let retained = existing.filter { $0.startDate >= now && $0.startDate < limit }
    guard retained.count < target else { return [] }
    var categoryCounts = Dictionary(grouping: recent, by: { $0.activityType.category }).mapValues(\.count)
    for entry in retained { categoryCounts[entry.activity.category, default: 0] += 1 }
    var plannedCategoryCounts = Dictionary(grouping: retained, by: { $0.activity.category }).mapValues(\.count)
    var activityCounts = Dictionary(grouping: recent, by: \.activityType).mapValues(\.count)
    let defaults: [TrainingCategory: WorkoutActivity] = [
      .endurance: .walking, .strength: .functionalStrength, .mobility: .mobility, .sport: .tennis, .other: .other
    ]
    var result: [PlanEntry] = []
    let today = calendar.startOfDay(for: now)
    let occupied = busy + retained.map { DateInterval(start: $0.startDate, end: $0.endDate) }
    let strengthDates = recent.filter { $0.activityType.category == .strength }.map(\.start) +
      existing.filter { $0.activity.category == .strength }.map(\.startDate)
    func adjacentStrength(_ day: Date) -> Bool {
      (strengthDates + result.filter { $0.activity.category == .strength }.map(\.startDate)).contains {
        abs(calendar.dateComponents([.day], from: calendar.startOfDay(for: $0), to: day).day ?? 0) <= 1
      }
    }
    // Prefer alternating days, then use remaining days when the calendar is busy.
    for offset in [0, 2, 4, 6, 1, 3, 5] {
      guard result.count + retained.count < target,
            let day = calendar.date(byAdding: .day, value: offset, to: today),
            !retained.contains(where: { calendar.isDate($0.startDate, inSameDayAs: day) }) else { continue }
      let choices = categories.sorted {
        let leftPlanned = plannedCategoryCounts[$0, default: 0], rightPlanned = plannedCategoryCounts[$1, default: 0]
        if leftPlanned != rightPlanned { return leftPlanned < rightPlanned }
        let left = categoryCounts[$0, default: 0], right = categoryCounts[$1, default: 0]
        return left == right ? $0.rawValue < $1.rawValue : left < right
      }
      for category in choices where category != .strength || !adjacentStrength(day) {
        let selected = preferredActivities.filter { $0.category == category }
        let activity = selected.sorted {
          let left = activityCounts[$0, default: 0], right = activityCounts[$1, default: 0]
          return left == right ? $0.rawValue < $1.rawValue : left < right
        }.first ?? defaults[category] ?? .walking
        let duration = category == .mobility ? 15 : (category == .strength ? 30 : 25)
        let occupiedNow = occupied + result.map { DateInterval(start: $0.startDate, end: $0.endDate) }
        guard let candidate = bestSlot(on: day, durationMinutes: duration, busy: occupiedNow,
          now: now, limit: limit, startHour: startHour, endHour: endHour,
          transitionMinutes: transitionMinutes, calendar: calendar) else { continue }
        let muscles = category == .strength ? suggestedMuscles(workouts: recent, annotations: annotations,
          existing: retained + result) : []
        result.append(PlanEntry(activity: activity, startDate: candidate, durationMinutes: duration, muscles: muscles))
        categoryCounts[category, default: 0] += 1
        plannedCategoryCounts[category, default: 0] += 1
        activityCounts[activity, default: 0] += 1
        break
      }
    }
    return result.sorted { $0.startDate < $1.startDate }
  }

  /// Only explicitly recorded muscle labels inform this rotation. Activity names
  /// alone cannot tell which muscles someone trained.
  static func suggestedMuscles(workouts: [WorkoutRecord], annotations: [String: WorkoutAnnotation],
                               existing: [PlanEntry]) -> Set<MuscleGroup> {
    let focuses: [Set<MuscleGroup>] = [
      [.quads, .hamstrings, .glutes, .calves], [.chest, .back, .shoulders, .arms], [.core]
    ]
    var counts: [MuscleGroup: Int] = [:]
    for workout in workouts where workout.activityType.category == .strength {
      for muscle in annotations[workout.id]?.muscles ?? [] { counts[muscle, default: 0] += 1 }
    }
    for entry in existing where entry.activity.category == .strength {
      for muscle in entry.muscles { counts[muscle, default: 0] += 1 }
    }
    return focuses.enumerated().min { left, right in
      let l = Double(left.element.reduce(0) { $0 + counts[$1, default: 0] }) / Double(left.element.count)
      let r = Double(right.element.reduce(0) { $0 + counts[$1, default: 0] }) / Double(right.element.count)
      return l == r ? left.offset < right.offset : l < r
    }?.element ?? Set(MuscleGroup.allCases)
  }

  /// Search a bounded set of quarter-hour starts. Useful morning, lunch and evening
  /// windows rank ahead of arbitrary gaps, and a short transfer buffer prevents a
  /// session being squeezed directly against a meeting. Narrow user windows retain
  /// their earliest valid start (including DST's next valid local time).
  private static func bestSlot(on day: Date, durationMinutes: Int, busy: [DateInterval],
                               now: Date, limit: Date, startHour: Int, endHour: Int,
                               transitionMinutes: Int, calendar: Calendar) -> Date? {
    guard let windowStart = calendar.date(bySettingHour: startHour, minute: 0, second: 0, of: day,
      matchingPolicy: .nextTime, repeatedTimePolicy: .first, direction: .forward),
      let windowEnd = endHour == 24 ? calendar.date(byAdding: .day, value: 1, to: day) :
        calendar.date(bySettingHour: endHour, minute: 0, second: 0, of: day,
          matchingPolicy: .nextTime, repeatedTimePolicy: .first, direction: .forward) else { return nil }
    let buffer = Double(min(max(transitionMinutes, 0), 60) * 60)
    let validBusy = busy.filter { $0.end > $0.start }
    var candidate = windowStart
    var choices: [(Date, Int)] = []
    // An absolute-time increment traverses repeated/skipped DST hours safely.
    for _ in 0..<100 {
      let end = candidate.addingTimeInterval(Double(durationMinutes) * 60)
      guard candidate < windowEnd, calendar.isDate(candidate, inSameDayAs: day) else { break }
      let interval = DateInterval(start: candidate.addingTimeInterval(-buffer), end: end.addingTimeInterval(buffer))
      if candidate >= now && candidate < limit && end <= windowEnd &&
        !validBusy.contains(where: { overlaps(interval, $0) }) {
        let minute = calendar.component(.hour, from: candidate) * 60 + calendar.component(.minute, from: candidate)
        let endMinute = minute + durationMinutes
        let broadWindow = endHour - startHour >= 6
        let rank: Int
        if !broadWindow { rank = 0 }
        else if minute >= 7 * 60 && endMinute <= 10 * 60 { rank = 300 }
        else if minute >= 11 * 60 + 30 && endMinute <= 14 * 60 { rank = 200 }
        else if minute >= 17 * 60 && endMinute <= 21 * 60 { rank = 100 }
        else { rank = 0 }
        choices.append((candidate, rank))
      }
      candidate = candidate.addingTimeInterval(15 * 60)
    }
    return choices.max { a, b in a.1 == b.1 ? a.0 > b.0 : a.1 < b.1 }?.0
  }

  static func overlaps(_ lhs: DateInterval, _ rhs: DateInterval) -> Bool {
    lhs.start < rhs.end && rhs.start < lhs.end
  }

  static func summary(entries: [PlanEntry], now: Date = Date(), calendar: Calendar = .current) -> TrainingPlanSummary {
    let week = calendar.dateInterval(of: .weekOfYear, for: now)
    let included = entries.filter { entry in week.map { entry.startDate >= $0.start && entry.startDate < $0.end } ?? false }
    return TrainingPlanSummary(suggested: included.filter { $0.state == .suggested }.count,
      confirmed: included.filter { $0.state == .confirmed }.count,
      completed: included.filter { $0.state == .completed }.count,
      minutes: included.reduce(0) { $0 + $1.durationMinutes })
  }
}
