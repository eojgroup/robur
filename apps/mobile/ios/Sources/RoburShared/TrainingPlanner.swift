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

  var endDate: Date { startDate.addingTimeInterval(Double(durationMinutes) * 60) }
  var url: URL { URL(string: "robur://plan/\(id.uuidString)")! }
  var calendarTitle: String {
    "\(state == .suggested ? "[Suggested] " : "")\(activity.title) — Robur"
  }
  var isValid: Bool {
    startDate.timeIntervalSince1970.isFinite && (1...1_440).contains(durationMinutes)
  }

  /// Calendar dates remain authoritative even while an entry is still a suggestion.
  /// Removing the marker (including a custom title) or changing tentative to Busy
  /// confirms it. Confirmation and completion never regress during reconciliation.
  mutating func reconcile(start: Date, end: Date, title: String, isBusy: Bool) {
    let minutes = end.timeIntervalSince(start) / 60
    guard start.timeIntervalSince1970.isFinite, minutes.isFinite, minutes > 0, minutes <= 1_440 else { return }
    startDate = start
    durationMinutes = max(1, Int(minutes.rounded()))
    let hasMarker = title.trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix("[Suggested]")
    if state == .suggested && (!hasMarker || (calendarUsesTentativeAvailability && isBusy)) {
      state = .confirmed
    }
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
                      categories: Set<TrainingCategory> = [.endurance, .strength, .mobility],
                      preferredActivities: Set<WorkoutActivity> = [],
                      busy: [DateInterval] = [], now: Date = Date(),
                      startHour: Int = 17, endHour: Int = 20,
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
        let left = categoryCounts[$0, default: 0], right = categoryCounts[$1, default: 0]
        return left == right ? $0.rawValue < $1.rawValue : left < right
      }
      guard let category = choices.first(where: { $0 != .strength || !adjacentStrength(day) }) else { continue }
      let selected = preferredActivities.filter { $0.category == category }
      let activity = selected.sorted {
        let left = activityCounts[$0, default: 0], right = activityCounts[$1, default: 0]
        return left == right ? $0.rawValue < $1.rawValue : left < right
      }.first ?? defaults[category] ?? .walking
      let duration = category == .mobility ? 15 : (category == .strength ? 30 : 25)
      guard var candidate = calendar.date(bySettingHour: startHour, minute: 0, second: 0, of: day,
                                          matchingPolicy: .nextTime, repeatedTimePolicy: .first, direction: .forward),
            let windowEnd = endHour == 24 ? calendar.date(byAdding: .day, value: 1, to: day) :
              calendar.date(bySettingHour: endHour, minute: 0, second: 0, of: day,
                            matchingPolicy: .nextTime, repeatedTimePolicy: .first, direction: .forward) else { continue }
      while candidate < windowEnd && calendar.isDate(candidate, inSameDayAs: day) {
        let end = candidate.addingTimeInterval(Double(duration) * 60)
        let interval = DateInterval(start: candidate, end: end)
        if candidate >= now && candidate < limit && end <= windowEnd &&
          !(occupied + result.map { DateInterval(start: $0.startDate, end: $0.endDate) }).contains(where: { overlaps(interval, $0) }) {
          result.append(PlanEntry(activity: activity, startDate: candidate, durationMinutes: duration))
          categoryCounts[category, default: 0] += 1
          activityCounts[activity, default: 0] += 1
          break
        }
        guard let next = calendar.date(byAdding: .minute, value: 30, to: candidate), next > candidate else { break }
        candidate = next
      }
    }
    return result.sorted { $0.startDate < $1.startDate }
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
