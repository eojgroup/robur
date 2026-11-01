import Foundation

/// Deterministic rules shared by the EventKit worker and its regression tests.
/// Observation dates detect changes; only session edits compete with pending edits.
enum TrainingPlanExternalSync {
  static func shouldImport(modified: Date?, observed: Date?, pending: Bool,
                           competing: [Date?], contentChanged: Bool = false) -> Bool {
    if let modified, let observed {
      if modified < observed { return false }
      if modified == observed { return contentChanged && !pending }
    }
    guard pending else { return true }
    guard let modified else { return false }
    return competing.compactMap { $0 }.allSatisfy { modified > $0 }
  }

  static func title(existing: String, entry: PlanEntry) -> String {
    var base = PlanEntry.rewritingTitle(existing, state: .confirmed)
    if let suffix = base.range(of: " · Muscle focus: ", options: .backwards) {
      base = String(base[..<suffix.lowerBound])
    }
    let managed = base.isEmpty || WorkoutActivity.allCases.contains { activity in
      if base == "\(activity.title) — Robur" { return true }
      let prefix = "\(activity.title) · ", suffix = " — Robur"
      guard activity.category == .strength, base.hasPrefix(prefix), base.hasSuffix(suffix) else { return false }
      let focus = String(base.dropFirst(prefix.count).dropLast(suffix.count))
      let presets: Set<String> = ["Full body", "Upper body", "Lower body", "Upper body + Core", "Lower body + Core"]
      if presets.contains(focus) { return true }
      let named = focus.components(separatedBy: ", ")
      return !named.isEmpty && named.allSatisfy { MuscleGroup(rawValue: $0) != nil }
    }
    if managed { return entry.calendarTitle }
    if entry.activity.category == .strength && !entry.muscles.isEmpty {
      base += " · Muscle focus: \(entry.muscleSummary)"
    }
    return PlanEntry.rewritingTitle(base, state: entry.state)
  }

  static func notes(existing: String?, entry: PlanEntry) -> String {
    let open = "[Robur training plan]", close = "[/Robur training plan]"
    var userNotes = existing ?? ""
    if let start = userNotes.range(of: open), let end = userNotes.range(of: close, range: start.upperBound..<userNotes.endIndex) {
      userNotes.removeSubrange(start.lowerBound..<end.upperBound)
    }
    // Upgrade the old unbounded note format without discarding personal notes.
    let legacy = "Editable Robur training plan. Confirm in Robur or remove [Suggested] in Calendar."
    userNotes = userNotes.components(separatedBy: .newlines).filter {
      $0 != legacy && $0 != "Robur plan ID: \(entry.id.uuidString)" && $0 != entry.url.absoluteString
    }.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
    var lines = [open, "Robur plan ID: \(entry.id.uuidString)"]
    if entry.activity.category == .strength && !entry.muscles.isEmpty {
      lines.append("Muscle focus: \(entry.muscleSummary)")
      lines.append("Muscle groups: " + MuscleGroup.allCases.filter { entry.muscles.contains($0) }.map(\.rawValue).joined(separator: ", "))
    }
    lines += ["Remove [Suggested] from the title to confirm. Add [Completed] to complete in Calendar, or check the linked reminder.",
              entry.url.absoluteString, close]
    return (userNotes.isEmpty ? "" : userNotes + "\n\n") + lines.joined(separator: "\n")
  }

  /// A date-only reminder moves the training day while retaining its session time.
  /// Respect the provider's calendar/time zone and never turn an absent due date
  /// into an invented date or midnight session.
  static func reminderDate(_ components: DateComponents, fallback: Date) -> Date? {
    guard components.year != nil, components.month != nil, components.day != nil else { return nil }
    var calendar = components.calendar ?? .current
    if let zone = components.timeZone { calendar.timeZone = zone }
    var complete = components
    complete.calendar = calendar
    complete.timeZone = calendar.timeZone
    if components.hour == nil {
      let time = calendar.dateComponents([.hour, .minute, .second], from: fallback)
      complete.hour = time.hour; complete.minute = time.minute; complete.second = time.second
    } else {
      complete.minute = components.minute ?? 0
      complete.second = components.second ?? 0
    }
    guard let date = calendar.date(from: complete), date.timeIntervalSince1970.isFinite else { return nil }
    let checked = calendar.dateComponents([.era, .year, .month, .day], from: date)
    guard checked.year == components.year, checked.month == components.month, checked.day == components.day,
          components.era == nil || checked.era == components.era else { return nil }
    return date
  }

  static func sameReminderDate(_ components: DateComponents?, sessionStart: Date) -> Bool {
    guard let components, let date = reminderDate(components, fallback: sessionStart) else { return false }
    return Calendar.current.compare(date, to: sessionStart, toGranularity: .minute) == .orderedSame
  }

  @discardableResult
  static func reconcileReminder(entry: inout PlanEntry, due: Date?, title: String, isCompleted: Bool) -> Bool {
    let before = entry
    if let due, due.timeIntervalSince1970.isFinite,
       Calendar.current.compare(due, to: entry.startDate, toGranularity: .minute) != .orderedSame {
      entry.startDate = due
    }
    entry.reconcileExternalTitle(title)
    if isCompleted { entry.state = .completed }
    else if entry.reminderLastSyncedCompleted == true { entry.state = .confirmed }
    return before.startDate != entry.startDate || before.state != entry.state
  }

  static func recordSessionChange(entry: inout PlanEntry, modified: Date?) {
    entry.localModificationDate = max(entry.localModificationDate ?? .distantPast, modified ?? Date())
  }
}
