import Combine
import EventKit
import Foundation

@MainActor
final class TrainingPlannerStore: ObservableObject {
  static let shared = TrainingPlannerStore()
  @Published private(set) var entries: [PlanEntry] = []
  @Published private(set) var calendars: [EKCalendar] = []
  @Published private(set) var reminderLists: [EKCalendar] = []
  @Published private(set) var selectedCalendarID: String?
  @Published private(set) var selectedReminderListID: String?
  @Published private(set) var remindersEnabled = false
  @Published private(set) var syncReminderCompletion = false
  @Published private(set) var calendarAccess = false
  @Published private(set) var reminderAccess = false
  @Published private(set) var isWorking = false
  @Published var lastError: String?
  @Published var status = "Suggestions stay on this device until you add placeholders."
  @Published var focusedEntryID: UUID?
  private let eventStore: EKEventStore
  private let url: URL
  private var unreadableArchive = false
  private var observer: NSObjectProtocol?

  private struct Archive: Codable, Equatable {
    var version = 1
    var entries: [PlanEntry]
    var calendarID: String?
    var reminderListID: String?
    var remindersEnabled = false
    var syncReminderCompletion = false
  }
  private var archive: Archive {
    Archive(entries: entries, calendarID: selectedCalendarID, reminderListID: selectedReminderListID,
      remindersEnabled: remindersEnabled, syncReminderCompletion: syncReminderCompletion)
  }

  init(url: URL? = nil, eventStore: EKEventStore = EKEventStore(), observeChanges: Bool = true) {
    self.url = url ?? URL.applicationSupportDirectory.appending(path: "Robur/training-plan.json")
    self.eventStore = eventStore
    do {
      let saved = try JSONDecoder().decode(Archive.self, from: Data(contentsOf: self.url))
      guard saved.version == 1, saved.entries.allSatisfy(\.isValid),
            Set(saved.entries.map(\.id)).count == saved.entries.count else { throw PlannerError.invalidArchive }
      apply(saved)
    } catch let error as CocoaError where error.code == .fileReadNoSuchFile {
      // A new installation starts with no plan and no external permissions requested.
    } catch {
      unreadableArchive = true
      lastError = "Could not open your saved plan. The existing file has been preserved."
    }
    refreshAccess()
    if observeChanges {
      observer = NotificationCenter.default.addObserver(forName: .EKEventStoreChanged, object: eventStore, queue: .main) { [weak self] _ in
        Task { @MainActor in await self?.reconcile() }
      }
    }
  }

  deinit { if let observer { NotificationCenter.default.removeObserver(observer) } }

  @discardableResult
  func open(url: URL) -> Bool {
    guard url.scheme == "robur", url.host == "plan", let id = UUID(uuidString: url.lastPathComponent),
          entries.contains(where: { $0.id == id }) else { return false }
    focusedEntryID = id
    return true
  }

  func chooseCalendar(_ id: String?) {
    var next = archive; next.calendarID = id
    _ = commit(next)
  }

  func chooseReminderList(_ id: String?) {
    var next = archive; next.reminderListID = id
    _ = commit(next)
  }

  func setReminderCompletion(_ enabled: Bool) {
    var next = archive; next.syncReminderCompletion = enabled
    if commit(next) { Task { await reconcile() } }
  }

  func requestCalendarAccess() async {
    guard !isWorking else { return }
    isWorking = true
    do {
      let granted = try await eventStore.requestFullAccessToEvents()
      refreshAccess()
      if !granted { lastError = "Calendar full access is off. You can still keep a local plan; enable full access in Settings to check conflicts and add placeholders." }
      else { lastError = nil; status = "Calendar connected. Review your plan before adding placeholders." }
    } catch { lastError = "Could not request Calendar access: \(error.localizedDescription)" }
    isWorking = false
    if calendarAccess { await reconcile() }
  }

  func setRemindersEnabled(_ enabled: Bool) async {
    guard !isWorking else { return }
    if enabled && !reminderAccess {
      isWorking = true
      do {
        let granted = try await eventStore.requestFullAccessToReminders()
        refreshAccess()
        isWorking = false
        guard granted else { lastError = "Reminders access is off. Enable it in Settings to use optional plan reminders."; return }
      } catch { isWorking = false; lastError = "Could not request Reminders access: \(error.localizedDescription)"; return }
    }
    var next = archive
    next.remindersEnabled = enabled
    if next.reminderListID == nil { next.reminderListID = reminderLists.first?.calendarIdentifier }
    if commit(next), enabled { await reconcile() }
  }

  func generateWeek(workouts: [WorkoutRecord], categories: Set<TrainingCategory>,
                    preferredActivities: Set<WorkoutActivity> = [], startHour: Int = 17, endHour: Int = 20,
                    now: Date = Date(), calendar: Calendar = .current) {
    guard !isWorking else { return }
    refreshAccess()
    var next = archive
    // Only replace local, unexported drafts. Exported suggestions and confirmed plans survive regeneration.
    next.entries.removeAll { $0.state == .suggested && !$0.calendarWasExported }
    let end = calendar.date(byAdding: .day, value: 7, to: now) ?? now
    let busy = calendarAccess ? events(from: now, to: end).filter { $0.availability != .free && $0.status != .canceled }
      .compactMap { event -> DateInterval? in
        guard let start = event.startDate, let finish = event.endDate, finish > start else { return nil }
        return DateInterval(start: start, end: finish)
      } : []
    let generated = TrainingPlanner.suggest(workouts: workouts, existing: next.entries, categories: categories,
      preferredActivities: preferredActivities, busy: busy, now: now, startHour: startHour, endHour: endHour, calendar: calendar)
    next.entries.append(contentsOf: generated)
    next.entries.sort { $0.startDate < $1.startDate }
    if commit(next) {
      status = generated.isEmpty ? "No new slots fit. Try a wider time window or review retained plans." :
        "\(generated.count) editable suggestions created. \(calendarAccess ? "Existing Calendar events were checked." : "Connect Calendar to check conflicts before export.")"
    }
  }

  /// The sole entry point that inserts Calendar events, called by the explicit export button.
  func exportPlaceholders() async {
    guard !isWorking else { return }
    refreshAccess()
    guard calendarAccess, let calendar = calendars.first(where: { $0.calendarIdentifier == selectedCalendarID }) else {
      lastError = "Connect Calendar with full access and choose a writable calendar first."; return
    }
    guard commit(archive) else { return } // Verify local persistence before touching Calendar.
    isWorking = true
    defer { isWorking = false }
    var next = archive
    var inserted = 0
    do {
      for index in next.entries.indices where !next.entries[index].calendarWasExported &&
        next.entries[index].state != .completed && next.entries[index].endDate > Date() {
        var entry = next.entries[index]
        if let found = findEvent(for: entry) {
          // Recovers an export whose external save succeeded but local disk write failed.
          entry.calendarEventID = found.eventIdentifier
          entry.calendarWasExported = true
          entry.calendarUsesTentativeAvailability = found.calendar.supportedEventAvailabilities.contains(.tentative)
          entry.reconcile(start: found.startDate, end: found.endDate, title: found.title ?? "", isBusy: found.availability == .busy)
        } else {
          let conflicts = events(from: entry.startDate, to: entry.endDate).contains { event in
            guard event.availability != .free, event.status != .canceled,
                  let start = event.startDate, let end = event.endDate, end > start else { return false }
            return TrainingPlanner.overlaps(DateInterval(start: entry.startDate, end: entry.endDate), DateInterval(start: start, end: end))
          }
          guard !conflicts else { status = "Some slots now conflict with Calendar. Edit those times and try again."; continue }
          let event = EKEvent(eventStore: eventStore)
          event.calendar = calendar
          event.title = entry.calendarTitle
          event.startDate = entry.startDate
          event.endDate = entry.endDate
          event.timeZone = .current
          event.url = entry.url
          entry.calendarUsesTentativeAvailability = calendar.supportedEventAvailabilities.contains(.tentative)
          event.notes = notes(for: entry)
          if entry.state == .suggested && entry.calendarUsesTentativeAvailability { event.availability = .tentative }
          else if entry.state != .suggested && calendar.supportedEventAvailabilities.contains(.busy) { event.availability = .busy }
          try eventStore.save(event, span: .thisEvent, commit: true)
          entry.calendarEventID = event.eventIdentifier
          entry.calendarWasExported = true
          inserted += 1
        }
        next.entries[index] = entry
        // Checkpoint each item so a later export failure cannot orphan earlier associations.
        guard commit(next) else { return }
      }
      status = "Added \(inserted) Calendar placeholder\(inserted == 1 ? "" : "s"). Confirm a suggestion in Robur, or remove [Suggested] in Calendar."
      try await syncReminders(in: &next)
      _ = commit(next)
    } catch { lastError = "Calendar export stopped: \(error.localizedDescription). Already linked entries will not be duplicated." }
  }

  @discardableResult
  func update(id: UUID, startDate: Date, durationMinutes: Int, activity: WorkoutActivity? = nil, muscles: Set<MuscleGroup>? = nil,
              state: PlanEntryState? = nil) async -> Bool {
    guard !isWorking, let index = entries.firstIndex(where: { $0.id == id }) else { return false }
    var next = archive
    var entry = next.entries[index]
    let previousActivity = entry.activity
    if let activity { entry.activity = activity }
    entry.startDate = startDate
    entry.durationMinutes = durationMinutes
    if let muscles { entry.muscles = muscles }
    if let state, entry.state != .completed { entry.state = state }
    guard entry.isValid else { lastError = "Choose a duration between 1 minute and 24 hours."; return false }
    guard commit(archive) else { return false }
    isWorking = true
    defer { isWorking = false }
    do {
      refreshAccess()
      if entry.calendarWasExported {
        guard calendarAccess else { throw PlannerError.calendarAccess }
        if let event = findEvent(for: entry) {
          guard event.calendar.allowsContentModifications else { throw PlannerError.readOnly }
          event.startDate = entry.startDate
          event.endDate = entry.endDate
          // Update our default label for activity edits; preserve custom Calendar titles.
          let title = (event.title ?? entry.calendarTitle).trimmingCharacters(in: .whitespacesAndNewlines)
          let baseTitle = title.hasPrefix("[Suggested]") ?
            String(title.dropFirst("[Suggested]".count)).trimmingCharacters(in: .whitespacesAndNewlines) : title
          if baseTitle == "\(previousActivity.title) — Robur" { event.title = entry.calendarTitle }
          else if entry.state != .suggested { event.title = baseTitle }
          if entry.state != .suggested {
            if event.calendar.supportedEventAvailabilities.contains(.busy) { event.availability = .busy }
          }
          try eventStore.save(event, span: .thisEvent, commit: true)
          entry.calendarEventID = event.eventIdentifier
        } else {
          entry.calendarEventID = nil
          status = "Calendar item is unlinked. Your local edit was saved; no replacement was created."
        }
      }
      next.entries[index] = entry
      // Publish only after the atomic write; a failed write leaves the local model unchanged.
      guard commit(next) else { return false }
      try await syncReminders(in: &next, previousActivities: [entry.id: previousActivity])
      return commit(next)
    } catch { lastError = "Could not update this plan: \(error.localizedDescription)"; return false }
  }

  func confirm(id: UUID) async {
    guard let entry = entries.first(where: { $0.id == id }) else { return }
    _ = await update(id: id, startDate: entry.startDate, durationMinutes: entry.durationMinutes, state: .confirmed)
  }

  func complete(id: UUID) async {
    guard let entry = entries.first(where: { $0.id == id }), entry.state == .confirmed else { return }
    _ = await update(id: id, startDate: entry.startDate, durationMinutes: entry.durationMinutes, state: .completed)
  }

  func removeLocalEntry(id: UUID) {
    guard !isWorking else { return }
    var next = archive
    next.entries.removeAll { $0.id == id }
    if commit(next) { status = "Removed from the local plan. Calendar and Reminders items were kept." }
  }

  func reconcile() async {
    guard !isWorking else { return }
    refreshAccess()
    isWorking = true
    defer { isWorking = false }
    var next = archive
    if calendarAccess {
      for index in next.entries.indices where next.entries[index].calendarWasExported {
        if let event = findEvent(for: next.entries[index]) {
          next.entries[index].calendarEventID = event.eventIdentifier
          next.entries[index].reconcile(start: event.startDate, end: event.endDate, title: event.title ?? "", isBusy: event.availability == .busy)
        } else {
          next.entries[index].calendarEventID = nil
        }
      }
    }
    do {
      try await syncReminders(in: &next)
      if next != archive { _ = commit(next) }
    } catch { lastError = "Could not sync plan reminders: \(error.localizedDescription)" }
  }

  private func refreshAccess() {
    calendarAccess = EKEventStore.authorizationStatus(for: .event) == .fullAccess
    reminderAccess = EKEventStore.authorizationStatus(for: .reminder) == .fullAccess
    calendars = calendarAccess ? eventStore.calendars(for: .event).filter(\.allowsContentModifications) : []
    reminderLists = reminderAccess ? eventStore.calendars(for: .reminder).filter(\.allowsContentModifications) : []
    // Defaults are local choices only; no new calendar/list is ever created.
    if calendarAccess && selectedCalendarID == nil { selectedCalendarID = eventStore.defaultCalendarForNewEvents?.calendarIdentifier }
    if reminderAccess && selectedReminderListID == nil { selectedReminderListID = eventStore.defaultCalendarForNewReminders()?.calendarIdentifier }
  }

  private func events(from start: Date, to end: Date) -> [EKEvent] {
    guard end > start else { return [] }
    return eventStore.events(matching: eventStore.predicateForEvents(withStart: start, end: end, calendars: nil))
  }

  private func owns(_ item: EKCalendarItem, entry: PlanEntry) -> Bool {
    item.url == entry.url || (item.notes ?? "").contains("Robur plan ID: \(entry.id.uuidString)")
  }

  private func findEvent(for entry: PlanEntry) -> EKEvent? {
    if let id = entry.calendarEventID, let event = eventStore.event(withIdentifier: id), owns(event, entry: entry) { return event }
    // Identifier changes after a sync are common. Search a bounded two-year range
    // around the last known date and associate only our exact URL/UUID marker.
    let calendar = Calendar.current
    let start = calendar.date(byAdding: .year, value: -1, to: entry.startDate) ?? entry.startDate
    let end = calendar.date(byAdding: .year, value: 1, to: entry.startDate) ?? entry.endDate
    return events(from: start, to: end).first { owns($0, entry: entry) }
  }

  private func notes(for entry: PlanEntry) -> String {
    "Editable Robur training suggestion, not a medical or recovery recommendation. Confirm in Robur or remove [Suggested] from the Calendar title\(entry.calendarUsesTentativeAvailability ? " (or change availability to Busy)" : "").\nRobur plan ID: \(entry.id.uuidString)\n\(entry.url.absoluteString)"
  }

  private func syncReminders(in next: inout Archive, previousActivities: [UUID: WorkoutActivity] = [:]) async throws {
    guard remindersEnabled, reminderAccess else { return }
    let predicate = eventStore.predicateForReminders(in: nil)
    let all = await withCheckedContinuation { (continuation: CheckedContinuation<[EKReminder], Never>) in
      eventStore.fetchReminders(matching: predicate) { continuation.resume(returning: $0 ?? []) }
    }
    for index in next.entries.indices where next.entries[index].state != .suggested {
      var entry = next.entries[index]
      let byID = entry.reminderID.flatMap { eventStore.calendarItem(withIdentifier: $0) as? EKReminder }
      var reminder = byID.flatMap { owns($0, entry: entry) ? $0 : nil } ?? all.first { owns($0, entry: entry) }
      if reminder == nil && !entry.reminderWasCreated && entry.state == .confirmed {
        guard let list = reminderLists.first(where: { $0.calendarIdentifier == next.reminderListID }) else { continue }
        let created = EKReminder(eventStore: eventStore)
        created.calendar = list
        created.title = "\(entry.activity.title) — Robur"
        created.url = entry.url
        created.notes = "Robur plan ID: \(entry.id.uuidString)"
        reminder = created
      }
      guard let reminder, reminder.calendar.allowsContentModifications else {
        entry.reminderID = nil
        next.entries[index] = entry
        continue
      }
      if next.syncReminderCompletion && reminder.isCompleted { entry.state = .completed }
      let due = Calendar.current.dateComponents([.calendar, .timeZone, .year, .month, .day, .hour, .minute], from: entry.startDate)
      let alarmDate = Calendar.current.date(from: due) ?? entry.startDate
      var changed = !entry.reminderWasCreated || reminder.dueDateComponents != due
      if let previousActivity = previousActivities[entry.id], previousActivity != entry.activity,
         reminder.title == "\(previousActivity.title) — Robur" {
        reminder.title = "\(entry.activity.title) — Robur"
        changed = true
      }
      let previousDue = reminder.dueDateComponents.flatMap { Calendar.current.date(from: $0) }
      var alarms = reminder.alarms ?? []
      if !entry.reminderWasCreated {
        if !alarms.contains(where: { $0.absoluteDate == alarmDate }) {
          alarms.append(EKAlarm(absoluteDate: alarmDate))
          changed = true
        }
      } else if let previousDue, previousDue != alarmDate,
                let alarmIndex = alarms.firstIndex(where: { $0.absoluteDate == previousDue }) {
        // Move only the alarm at the previous due time; preserve unrelated user alarms.
        alarms[alarmIndex] = EKAlarm(absoluteDate: alarmDate)
        changed = true
      }
      if changed { reminder.alarms = alarms }
      if reminder.dueDateComponents != due { reminder.dueDateComponents = due }
      if next.syncReminderCompletion && entry.state == .completed && !reminder.isCompleted {
        reminder.isCompleted = true; changed = true
      }
      if changed { try eventStore.save(reminder, commit: true) }
      entry.reminderID = reminder.calendarItemIdentifier
      entry.reminderWasCreated = true
      next.entries[index] = entry
    }
  }

  private func apply(_ saved: Archive) {
    entries = saved.entries
    selectedCalendarID = saved.calendarID
    selectedReminderListID = saved.reminderListID
    remindersEnabled = saved.remindersEnabled
    syncReminderCompletion = saved.syncReminderCompletion
  }

  @discardableResult private func commit(_ next: Archive) -> Bool {
    do {
      guard !unreadableArchive else { throw PlannerError.invalidArchive }
      let data = try JSONEncoder().encode(next)
      try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
      try data.write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
      apply(next)
      lastError = nil
      return true
    } catch {
      lastError = "Could not save your plan: \(error.localizedDescription). Local changes were rolled back."
      return false
    }
  }

  private enum PlannerError: LocalizedError {
    case invalidArchive, calendarAccess, readOnly
    var errorDescription: String? {
      switch self {
      case .invalidArchive: return "The saved plan could not be read and has been preserved."
      case .calendarAccess: return "Full Calendar access is needed to update a linked event."
      case .readOnly: return "This Calendar event is now read-only."
      }
    }
  }
}
