import Combine
import EventKit
import Foundation

struct TrainingPlanCalendar: Identifiable {
  let calendarIdentifier: String
  let title: String
  var id: String { calendarIdentifier }
}

@MainActor
final class TrainingPlannerStore: ObservableObject {
  static let shared = TrainingPlannerStore()
  @Published private(set) var entries: [PlanEntry] = []
  @Published private(set) var calendars: [TrainingPlanCalendar] = []
  @Published private(set) var reminderLists: [TrainingPlanCalendar] = []
  @Published private(set) var selectedCalendarID: String?
  @Published private(set) var selectedReminderListID: String?
  @Published private(set) var remindersEnabled = false
  @Published private(set) var syncReminderCompletion = false
  @Published private(set) var calendarAccess = false
  @Published private(set) var reminderAccess = false
  // This describes external sync only. Local editing never takes this lock.
  @Published private(set) var isWorking = false
  @Published var lastError: String?
  @Published var status = "Your plan stays on this device until you add it to Calendar."
  @Published var focusedEntryID: UUID?
  var pendingSyncCount: Int { entries.filter { $0.calendarSyncPending == true || $0.reminderSyncPending == true }.count }
  private let worker: TrainingPlanEventWorker
  private let url: URL
  private let externalAccessDisabled: Bool
  private var unreadableArchive = false
  private var observer: NSObjectProtocol?
  private var notificationTask: Task<Void, Never>?
  private var localSyncTask: Task<Void, Never>?
  private var externalTask: Task<Void, Never>?
  private var needsAnotherSync = false
  private var exportingIDs: Set<UUID> = []
  private var cachedBusy: [DateInterval] = []

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
  private var settings: TrainingPlanEventWorker.Settings {
    .init(calendarID: selectedCalendarID, reminderListID: selectedReminderListID,
      remindersEnabled: remindersEnabled, syncReminderCompletion: syncReminderCompletion)
  }

  init(url: URL? = nil, eventStore: EKEventStore = EKEventStore(), observeChanges: Bool = true,
       externalAccessDisabled: Bool = false) {
    self.url = url ?? URL.applicationSupportDirectory.appending(path: "Robur/training-plan.json")
    self.externalAccessDisabled = externalAccessDisabled
    worker = TrainingPlanEventWorker(eventStore: eventStore)
    do {
      let saved = try JSONDecoder().decode(Archive.self, from: Data(contentsOf: self.url))
      guard saved.version == 1, saved.entries.allSatisfy(\.isValid),
            Set(saved.entries.map(\.id)).count == saved.entries.count else { throw PlannerError.invalidArchive }
      apply(saved)
    } catch let error as CocoaError where error.code == .fileReadNoSuchFile {
      // A new installation starts without requesting external permissions.
    } catch {
      unreadableArchive = true
      lastError = "Could not open your saved plan. The existing file has been preserved."
    }
    if !externalAccessDisabled {
      calendarAccess = EKEventStore.authorizationStatus(for: .event) == .fullAccess
      reminderAccess = EKEventStore.authorizationStatus(for: .reminder) == .fullAccess
      if observeChanges {
        observer = NotificationCenter.default.addObserver(forName: .EKEventStoreChanged, object: eventStore, queue: .main) { [weak self] _ in
          Task { @MainActor in self?.eventStoreChanged() }
        }
      }
    }
  }

  deinit {
    if let observer { NotificationCenter.default.removeObserver(observer) }
    notificationTask?.cancel()
    localSyncTask?.cancel()
    externalTask?.cancel()
  }

  @discardableResult
  func open(url: URL) -> Bool {
    guard url.scheme == "robur", url.host == "plan", let id = UUID(uuidString: url.lastPathComponent),
          entries.contains(where: { $0.id == id }) else { return false }
    focusedEntryID = id
    return true
  }

  func chooseCalendar(_ id: String?) {
    var next = archive; next.calendarID = id?.isEmpty == false ? id : nil
    _ = commit(next)
  }

  func chooseReminderList(_ id: String?) {
    var next = archive; next.reminderListID = id?.isEmpty == false ? id : nil
    if commit(next) { scheduleSync() }
  }

  func setReminderCompletion(_ enabled: Bool) {
    var next = archive; next.syncReminderCompletion = enabled
    if commit(next) { scheduleSync() }
  }

  @discardableResult
  func create(activity: WorkoutActivity, startDate: Date, durationMinutes: Int,
              muscles: Set<MuscleGroup> = [], state: PlanEntryState = .confirmed) -> UUID? {
    var entry = PlanEntry(activity: activity, startDate: startDate, durationMinutes: durationMinutes, muscles: muscles, state: state)
    entry.isManualSession = true
    entry.reminderSyncPending = remindersEnabled && state != .suggested ? true : nil
    guard entry.isValid else { lastError = "Choose a duration between 1 minute and 24 hours."; return nil }
    var next = archive; next.entries.append(entry)
    guard commit(next) else { return nil }
    status = "Session saved on this device."
    scheduleSync()
    return entry.id
  }

  @discardableResult
  func duplicate(id: UUID, startDate: Date) -> UUID? {
    guard let original = entries.first(where: { $0.id == id }) else { return nil }
    let copy = original.duplicated(startDate: startDate)
    guard copy.isValid else { return nil }
    var next = archive; next.entries.append(copy)
    guard commit(next) else { return nil }
    status = "Session duplicated in your local plan. Review it before adding it to Calendar."
    return copy.id
  }

  @discardableResult
  func reschedule(id: UUID, days: Int, calendar: Calendar = .current) -> Bool {
    guard let entry = entries.first(where: { $0.id == id }),
          let date = calendar.date(byAdding: .day, value: days, to: entry.startDate) else { return false }
    return saveLocalEdit(id: id, startDate: date, durationMinutes: entry.durationMinutes)
  }

  func generateWeek(workouts: [WorkoutRecord], categories: Set<TrainingCategory>,
                    preferredActivities: Set<WorkoutActivity> = [], startHour: Int = 17, endHour: Int = 20,
                    now: Date = Date(), calendar: Calendar = .current) {
    var next = archive
    next.entries.removeAll { $0.state == .suggested && !$0.calendarWasExported &&
      $0.isManualSession != true && !exportingIDs.contains($0.id) }
    let generated = TrainingPlanner.suggest(workouts: workouts, existing: next.entries, categories: categories,
      preferredActivities: preferredActivities, busy: cachedBusy, now: now, startHour: startHour, endHour: endHour, calendar: calendar)
    next.entries.append(contentsOf: generated)
    if commit(next) {
      status = generated.isEmpty ? "No new slots fit. Try a wider time window or review retained plans." :
        "\(generated.count) editable suggestions saved locally. Calendar conflicts are checked when adding sessions."
    }
  }

  @discardableResult
  func update(id: UUID, startDate: Date, durationMinutes: Int, activity: WorkoutActivity? = nil,
              muscles: Set<MuscleGroup>? = nil, state: PlanEntryState? = nil) async -> Bool {
    saveLocalEdit(id: id, startDate: startDate, durationMinutes: durationMinutes, activity: activity, muscles: muscles, state: state)
  }

  private func saveLocalEdit(id: UUID, startDate: Date, durationMinutes: Int, activity: WorkoutActivity? = nil,
                             muscles: Set<MuscleGroup>? = nil, state: PlanEntryState? = nil) -> Bool {
    guard let index = entries.firstIndex(where: { $0.id == id }) else { return false }
    var next = archive
    next.entries[index].startDate = startDate
    next.entries[index].durationMinutes = durationMinutes
    if let activity { next.entries[index].activity = activity }
    if let muscles { next.entries[index].muscles = muscles }
    if let state { next.entries[index].state = state }
    guard next.entries[index].isValid else { lastError = "Choose a duration between 1 minute and 24 hours."; return false }
    // Save first, even when access has been revoked or an external request is stalled.
    if next.entries[index].calendarEventID != nil {
      if next.entries[index].calendarSyncPending != true || next.entries[index].calendarLastKnownStartDate == nil {
        next.entries[index].calendarLastKnownStartDate = entries[index].startDate
      }
      next.entries[index].calendarSyncPending = true
    }
    if next.remindersEnabled && (next.entries[index].state != .suggested || next.entries[index].reminderWasCreated) {
      next.entries[index].reminderSyncPending = true
    } else if !next.entries[index].reminderWasCreated {
      next.entries[index].reminderSyncPending = nil
    }
    guard commit(next) else { return false }
    status = pendingSyncCount > 0 ? "Changes saved on this device. Calendar or Reminders sync is pending." : "Changes saved on this device."
    scheduleSync()
    return true
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
    if exportingIDs.contains(id) { cancelSync() }
    var next = archive; next.entries.removeAll { $0.id == id }
    if commit(next) { status = "Removed from the local plan. Calendar and Reminders items were kept." }
  }

  func requestCalendarAccess() async {
    guard !externalAccessDisabled else { lastError = "Calendar access is unavailable. Your local plan is still saved."; return }
    await performExternal {
      do {
        let granted = try await self.worker.requestAccess(reminders: false)
        self.calendarAccess = granted
        self.lastError = granted ? nil : "Calendar full access is off. You can still keep and edit your local plan."
      } catch { self.externalError(error) }
    }
    if calendarAccess { await reconcile() }
  }

  func setRemindersEnabled(_ enabled: Bool) async {
    var next = archive; next.remindersEnabled = enabled
    for index in next.entries.indices {
      next.entries[index].reminderSyncPending = enabled &&
        (next.entries[index].state != .suggested || next.entries[index].reminderWasCreated) ? true : nil
    }
    guard commit(next), enabled, !externalAccessDisabled else { return }
    if !reminderAccess {
      await performExternal {
        do {
          let granted = try await self.worker.requestAccess(reminders: true)
          self.reminderAccess = granted
          if !granted { self.lastError = "Reminders access is off. Local changes are saved; enable access in Settings to sync." }
        } catch { self.externalError(error) }
      }
    }
    await reconcile()
  }

  /// Only an explicit add action may create a Calendar event.
  func exportPlaceholders(ids: Set<UUID>? = nil, allowReExport: Bool = false) async {
    guard !externalAccessDisabled else { lastError = "Connect Calendar with full access to add a placeholder."; return }
    if let ids, ids.isEmpty { return }
    guard commit(archive) else { return }
    await performExternal {
      let baseline = self.entries
      let settings = self.settings
      self.exportingIDs = Set(baseline.filter { entry in
        (ids?.contains(entry.id) ?? true) &&
          (!entry.calendarWasExported || (ids != nil && allowReExport)) &&
          entry.state != .completed && entry.endDate > Date()
      }.map(\.id))
      defer { self.exportingIDs = [] }
      do {
        let result = try await self.worker.export(entries: baseline, settings: settings, ids: ids, allowReExport: allowReExport) { partial in
          Task { @MainActor in self.merge(partial, baseline: baseline) }
        }
        self.merge(result.entries, baseline: baseline)
        if self.pendingSyncCount > 0 { self.needsAnotherSync = true }
        self.status = "Added \(result.inserted) Calendar placeholder\(result.inserted == 1 ? "" : "s")." +
          (result.conflicting > 0 ? " \(result.conflicting) conflicted with Calendar; edit the time and try again." : "")
      } catch { self.externalError(error) }
    }
  }

  /// Exact ownership is checked again on the worker before deleting anything.
  func removeCalendarPlaceholder(id: UUID) async {
    guard !externalAccessDisabled else { lastError = "Connect Calendar with full access to remove this placeholder."; return }
    guard let entry = entries.first(where: { $0.id == id }), entry.calendarWasExported else { return }
    guard commit(archive) else { return }
    await performExternal {
      do {
        try await self.worker.remove(entry: entry)
        guard let index = self.entries.firstIndex(where: { $0.id == id }) else { return }
        var next = self.archive
        next.entries[index].calendarEventID = nil
        next.entries[index].calendarExternalID = nil
        next.entries[index].calendarLastKnownStartDate = nil
        next.entries[index].calendarSyncPending = nil
        // Keep the export tombstone: refresh and bulk export must not recreate it.
        if self.commit(next) { self.status = "Removed this session from Calendar. Your local plan and reminders were kept." }
      } catch { self.externalError(error) }
    }
  }

  func reconcile() async {
    guard !externalAccessDisabled else { return }
    await performExternal {
      let baseline = self.entries
      let settings = self.settings
      do {
        let snapshot = try await self.worker.refresh(entries: baseline)
        self.calendarAccess = snapshot.calendarAccess
        self.reminderAccess = snapshot.reminderAccess
        self.calendars = snapshot.calendars
        self.reminderLists = snapshot.reminderLists
        self.cachedBusy = snapshot.busy
        if self.selectedCalendarID == nil { self.chooseCalendar(snapshot.defaultCalendarID) }
        if self.selectedReminderListID == nil {
          var next = self.archive; next.reminderListID = snapshot.defaultReminderListID; _ = self.commit(next)
        }
        self.merge(snapshot.entries, baseline: baseline)
        if settings.remindersEnabled && snapshot.reminderAccess {
          let reminderBaseline = self.entries
          let synced = try await self.worker.syncReminders(entries: reminderBaseline, settings: self.settings)
          self.merge(synced, baseline: reminderBaseline)
        }
        if self.pendingSyncCount == 0 { self.status = "Local plan saved. Calendar and Reminders are up to date where connected." }
      } catch { self.externalError(error) }
    }
  }

  func cancelSync() {
    needsAnotherSync = false
    externalTask?.cancel()
    status = "Sync stopped. Your local plan is saved; retry when ready."
  }

  private func eventStoreChanged() {
    // Our own writes also emit this notification. Ignore them during sync and
    // coalesce later notifications; reconciliation only writes actual changes.
    guard !isWorking else { return }
    notificationTask?.cancel()
    notificationTask = Task { [weak self] in
      do { try await Task.sleep(nanoseconds: 500_000_000) } catch { return }
      await self?.reconcile()
    }
  }

  private func scheduleSync() {
    guard !externalAccessDisabled else { return }
    if isWorking { needsAnotherSync = true; return }
    localSyncTask?.cancel()
    localSyncTask = Task { [weak self] in
      do { try await Task.sleep(nanoseconds: 300_000_000) } catch { return }
      self?.localSyncTask = nil
      await self?.reconcile()
    }
  }

  private func performExternal(_ work: @escaping @MainActor () async -> Void) async {
    guard !isWorking else { return }
    localSyncTask?.cancel()
    localSyncTask = nil
    isWorking = true
    let task = Task { await work() }
    externalTask = task
    await task.value
    externalTask = nil
    isWorking = false
    if needsAnotherSync {
      needsAnotherSync = false
      scheduleSync()
    }
  }

  private func externalError(_ error: Error) {
    if error is CancellationError { return }
    lastError = "Your local plan is saved. Sync could not finish: \(error.localizedDescription) Retry sync when ready."
  }

  private func merge(_ synced: [PlanEntry], baseline: [PlanEntry]) {
    let previous = Dictionary(uniqueKeysWithValues: baseline.map { ($0.id, $0) })
    var next = archive
    for result in synced {
      guard let old = previous[result.id], let index = next.entries.firstIndex(where: { $0.id == result.id }) else { continue }
      if next.entries[index] == old { next.entries[index] = result }
      else {
        // An edit made while sync was running wins. Preserve newly saved links
        // and send the newer local values on the next pass.
        if next.entries[index].calendarEventID == old.calendarEventID && result.calendarEventID != old.calendarEventID {
          next.entries[index].calendarEventID = result.calendarEventID
          next.entries[index].calendarWasExported = result.calendarWasExported
          next.entries[index].calendarUsesTentativeAvailability = result.calendarUsesTentativeAvailability
          next.entries[index].calendarSyncPending = result.calendarEventID != nil ? true : nil
        }
        if next.entries[index].calendarExternalID == old.calendarExternalID {
          next.entries[index].calendarExternalID = result.calendarExternalID
        }
        if next.entries[index].reminderID == old.reminderID && result.reminderID != old.reminderID {
          next.entries[index].reminderID = result.reminderID
          next.entries[index].reminderWasCreated = result.reminderWasCreated
          next.entries[index].reminderSyncPending = result.reminderID != nil ? true : nil
        }
      }
    }
    if next != archive {
      let error = lastError
      if commit(next) { lastError = error }
    }
  }

  private func apply(_ saved: Archive) {
    entries = saved.entries.sorted { $0.startDate < $1.startDate }
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
}

private enum PlannerError: LocalizedError {
  case invalidArchive, calendarAccess, readOnly, timeout, reminderFetch
  var errorDescription: String? {
    switch self {
    case .invalidArchive: return "The saved plan could not be read and has been preserved."
    case .calendarAccess: return "Full Calendar access and a writable calendar are required."
    case .readOnly: return "This Calendar event is now read-only."
    case .timeout: return "Calendar or Reminders took too long to respond."
    case .reminderFetch: return "Reminders did not return a result. No new reminders were created."
    }
  }
}

/// EventKit's synchronous database calls must never run on the main actor.
/// Each operation has a deadline; a cancelled/expired result cannot change local state.
private final class TrainingPlanEventWorker: @unchecked Sendable {
  struct Settings {
    let calendarID: String?
    let reminderListID: String?
    let remindersEnabled: Bool
    let syncReminderCompletion: Bool
  }
  struct Snapshot {
    var entries: [PlanEntry]
    let calendarAccess: Bool
    let reminderAccess: Bool
    let calendars: [TrainingPlanCalendar]
    let reminderLists: [TrainingPlanCalendar]
    let defaultCalendarID: String?
    let defaultReminderListID: String?
    let busy: [DateInterval]
  }
  struct ExportResult { var entries: [PlanEntry]; var inserted = 0; var conflicting = 0 }
  private let store: EKEventStore
  private let queue = DispatchQueue(label: "app.robur.training-plan.eventkit", qos: .userInitiated)
  init(eventStore: EKEventStore) { store = eventStore }

  func requestAccess(reminders: Bool) async throws -> Bool {
    try await run(timeout: 45) { store, operation in
      let completion: (Bool, Error?) -> Void = { granted, error in
        if let error { operation.finish(.failure(error)) } else { operation.finish(.success(granted)) }
      }
      if reminders { store.requestFullAccessToReminders(completion: completion) }
      else { store.requestFullAccessToEvents(completion: completion) }
    }
  }

  func refresh(entries: [PlanEntry]) async throws -> Snapshot {
    try await perform { store, operation in
      let calendarAccess = EKEventStore.authorizationStatus(for: .event) == .fullAccess
      let reminderAccess = EKEventStore.authorizationStatus(for: .reminder) == .fullAccess
      let calendars = calendarAccess ? store.calendars(for: .event).filter(\.allowsContentModifications) : []
      let lists = reminderAccess ? store.calendars(for: .reminder).filter(\.allowsContentModifications) : []
      var next = entries
      if calendarAccess {
        for index in next.indices where next[index].calendarEventID != nil || next[index].calendarSyncPending == true {
          try operation.check()
          if let event = try self.findEvent(for: next[index], store: store, operation: operation) {
            if next[index].calendarSyncPending == true { try self.update(event: event, entry: next[index], store: store, operation: operation) }
            else { next[index].reconcile(start: event.startDate, end: event.endDate, title: event.title ?? "", isBusy: event.availability == .busy) }
            next[index].calendarEventID = event.eventIdentifier
            next[index].calendarExternalID = event.calendarItemExternalIdentifier
            next[index].calendarLastKnownStartDate = event.startDate
            next[index].calendarSyncPending = nil
          } else {
            next[index].calendarEventID = nil
            next[index].calendarSyncPending = nil
          }
        }
      }
      let now = Date()
      let end = Calendar.current.date(byAdding: .day, value: 7, to: now) ?? now
      let busy = calendarAccess ? try self.events(from: now, to: end, store: store, operation: operation).compactMap { event -> DateInterval? in
        guard event.availability != .free, event.status != .canceled,
              let start = event.startDate, let end = event.endDate, end > start else { return nil }
        return DateInterval(start: start, end: end)
      } : []
      return Snapshot(entries: next, calendarAccess: calendarAccess, reminderAccess: reminderAccess,
        calendars: calendars.map { .init(calendarIdentifier: $0.calendarIdentifier, title: $0.title) },
        reminderLists: lists.map { .init(calendarIdentifier: $0.calendarIdentifier, title: $0.title) },
        defaultCalendarID: calendarAccess ? store.defaultCalendarForNewEvents?.calendarIdentifier : nil,
        defaultReminderListID: reminderAccess ? store.defaultCalendarForNewReminders()?.calendarIdentifier : nil, busy: busy)
    }
  }

  func export(entries: [PlanEntry], settings: Settings, ids: Set<UUID>?, allowReExport: Bool,
              progress: @escaping ([PlanEntry]) -> Void) async throws -> ExportResult {
    try await perform { store, operation in
      guard EKEventStore.authorizationStatus(for: .event) == .fullAccess,
            let calendar = store.calendars(for: .event).first(where: { $0.calendarIdentifier == settings.calendarID && $0.allowsContentModifications }) else {
        throw PlannerError.calendarAccess
      }
      var result = ExportResult(entries: entries)
      for index in result.entries.indices where (ids?.contains(result.entries[index].id) ?? true) &&
        (!result.entries[index].calendarWasExported || (ids != nil && allowReExport)) &&
        result.entries[index].state != .completed && result.entries[index].endDate > Date() {
        try operation.check()
        var entry = result.entries[index]
        if let found = try self.findEvent(for: entry, store: store, operation: operation) {
          entry.calendarEventID = found.eventIdentifier
          entry.calendarExternalID = found.calendarItemExternalIdentifier
          entry.calendarWasExported = true
          entry.calendarUsesTentativeAvailability = found.calendar.supportedEventAvailabilities.contains(.tentative)
          // An explicit add uses the currently reviewed local values.
          try self.update(event: found, entry: entry, store: store, operation: operation)
        } else {
          let conflict = try self.events(from: entry.startDate, to: entry.endDate, store: store, operation: operation).contains { event in
            guard event.availability != .free, event.status != .canceled,
                  let start = event.startDate, let end = event.endDate, end > start else { return false }
            return TrainingPlanner.overlaps(DateInterval(start: entry.startDate, end: entry.endDate), DateInterval(start: start, end: end))
          }
          if conflict { result.conflicting += 1; continue }
          let event = EKEvent(eventStore: store)
          event.calendar = calendar
          event.title = entry.calendarTitle
          event.startDate = entry.startDate
          event.endDate = entry.endDate
          event.timeZone = .current
          event.url = entry.url
          entry.calendarUsesTentativeAvailability = calendar.supportedEventAvailabilities.contains(.tentative)
          event.notes = "Editable Robur training plan. Confirm in Robur or remove [Suggested] in Calendar.\nRobur plan ID: \(entry.id.uuidString)\n\(entry.url.absoluteString)"
          if entry.state == .suggested && entry.calendarUsesTentativeAvailability { event.availability = .tentative }
          else if calendar.supportedEventAvailabilities.contains(.busy) { event.availability = .busy }
          try operation.check()
          try store.save(event, span: .thisEvent, commit: true)
          entry.calendarEventID = event.eventIdentifier
          entry.calendarExternalID = event.calendarItemExternalIdentifier
          entry.calendarWasExported = true
          result.inserted += 1
        }
        entry.calendarLastKnownStartDate = entry.startDate
        entry.calendarSyncPending = nil
        result.entries[index] = entry
        // Checkpoint links after every external save, including a partial bulk export.
        progress(result.entries)
      }
      return result
    }
  }

  func remove(entry: PlanEntry) async throws {
    let _: Bool = try await perform { store, operation in
      guard EKEventStore.authorizationStatus(for: .event) == .fullAccess else { throw PlannerError.calendarAccess }
      if let event = try self.findEvent(for: entry, store: store, operation: operation) {
        guard event.calendar.allowsContentModifications else { throw PlannerError.readOnly }
        try operation.check()
        try store.remove(event, span: .thisEvent, commit: true)
      }
      return true
    }
  }

  func syncReminders(entries: [PlanEntry], settings: Settings) async throws -> [PlanEntry] {
    guard settings.remindersEnabled else { return entries }
    return try await run { store, operation in
      guard EKEventStore.authorizationStatus(for: .reminder) == .fullAccess else { operation.finish(.success(entries)); return }
      let lists = store.calendars(for: .reminder).filter { $0.calendarIdentifier == settings.reminderListID && $0.allowsContentModifications }
      // Search the chosen list only; known identifiers still find items in other lists.
      guard !lists.isEmpty else { operation.finish(.success(entries)); return }
      let predicate = store.predicateForReminders(in: lists)
      let token = store.fetchReminders(matching: predicate) { reminders in
        self.queue.async {
          do {
            try operation.check()
            guard let reminders else { throw PlannerError.reminderFetch }
            let next = try self.applyReminders(entries: entries, all: reminders, list: lists[0], settings: settings, store: store, operation: operation)
            operation.finish(.success(next))
          } catch { operation.finish(.failure(error)) }
        }
      }
      operation.onCancel { self.queue.async { self.store.cancelFetchRequest(token) } }
    }
  }

  private func applyReminders(entries: [PlanEntry], all: [EKReminder], list: EKCalendar, settings: Settings,
                              store: EKEventStore, operation: PlannerOperation<[PlanEntry]>) throws -> [PlanEntry] {
    var next = entries
    for index in next.indices where next[index].state != .suggested || next[index].reminderWasCreated {
      try operation.check()
      var entry = next[index]
      let byID = entry.reminderID.flatMap { store.calendarItem(withIdentifier: $0) as? EKReminder }
      var reminder = byID.flatMap { self.owns($0, entry: entry) ? $0 : nil } ?? all.first { self.owns($0, entry: entry) }
      if reminder == nil && !entry.reminderWasCreated && entry.state == .confirmed {
        let created = EKReminder(eventStore: store)
        created.calendar = list
        created.title = "\(entry.activity.title) — Robur"
        created.url = entry.url
        created.notes = "Robur plan ID: \(entry.id.uuidString)"
        reminder = created
      }
      guard let reminder, reminder.calendar.allowsContentModifications else {
        entry.reminderID = nil
        entry.reminderSyncPending = nil
        next[index] = entry
        continue
      }
      if settings.syncReminderCompletion && reminder.isCompleted && entry.reminderSyncPending != true { entry.state = .completed }
      let due = Calendar.current.dateComponents([.calendar, .timeZone, .year, .month, .day, .hour, .minute], from: entry.startDate)
      let alarmDate = Calendar.current.date(from: due) ?? entry.startDate
      let previousDue = reminder.dueDateComponents.flatMap { Calendar.current.date(from: $0) }
      var changed = !entry.reminderWasCreated || reminder.dueDateComponents != due
      var alarms = reminder.alarms ?? []
      if !entry.reminderWasCreated && !alarms.contains(where: { $0.absoluteDate == alarmDate }) {
        alarms.append(EKAlarm(absoluteDate: alarmDate)); changed = true
      } else if let previousDue, previousDue != alarmDate,
                let alarmIndex = alarms.firstIndex(where: { $0.absoluteDate == previousDue }) {
        alarms[alarmIndex] = EKAlarm(absoluteDate: alarmDate); changed = true
      }
      if changed { reminder.alarms = alarms; reminder.dueDateComponents = due }
      if self.isDefaultTitle(reminder.title ?? ""), reminder.title != "\(entry.activity.title) — Robur" {
        reminder.title = "\(entry.activity.title) — Robur"; changed = true
      }
      if settings.syncReminderCompletion {
        let completed = entry.state == .completed
        if (entry.reminderSyncPending == true || completed) && reminder.isCompleted != completed {
          reminder.isCompleted = completed; changed = true
        }
      }
      if changed { try operation.check(); try store.save(reminder, commit: true) }
      entry.reminderID = reminder.calendarItemIdentifier
      entry.reminderWasCreated = true
      entry.reminderSyncPending = nil
      next[index] = entry
    }
    return next
  }

  private func update<Value>(event: EKEvent, entry: PlanEntry, store: EKEventStore, operation: PlannerOperation<Value>) throws {
    guard event.calendar.allowsContentModifications else { throw PlannerError.readOnly }
    var changed = false
    if event.startDate != entry.startDate { event.startDate = entry.startDate; changed = true }
    if event.endDate != entry.endDate { event.endDate = entry.endDate; changed = true }
    let title = (event.title ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
    let base = title.hasPrefix("[Suggested]") ? String(title.dropFirst("[Suggested]".count)).trimmingCharacters(in: .whitespacesAndNewlines) : title
    let desired = isDefaultTitle(base) ? entry.calendarTitle : "\(entry.state == .suggested ? "[Suggested] " : "")\(base)"
    if event.title != desired { event.title = desired; changed = true }
    let availability: EKEventAvailability = entry.state == .suggested && event.calendar.supportedEventAvailabilities.contains(.tentative) ? .tentative : .busy
    if event.calendar.supportedEventAvailabilities.contains(availability == .tentative ? .tentative : .busy), event.availability != availability {
      event.availability = availability; changed = true
    }
    if changed { try operation.check(); try store.save(event, span: .thisEvent, commit: true) }
  }

  private func isDefaultTitle(_ title: String) -> Bool { WorkoutActivity.allCases.contains { title == "\($0.title) — Robur" } }
  private func owns(_ item: EKCalendarItem, entry: PlanEntry) -> Bool {
    item.url == entry.url || (item.notes ?? "").components(separatedBy: .newlines).contains("Robur plan ID: \(entry.id.uuidString)")
  }
  private func events<Value>(from start: Date, to end: Date, store: EKEventStore, operation: PlannerOperation<Value>) throws -> [EKEvent] {
    try operation.check()
    guard end > start else { return [] }
    let result = store.events(matching: store.predicateForEvents(withStart: start, end: end, calendars: nil))
    try operation.check()
    return result
  }
  private func findEvent<Value>(for entry: PlanEntry, store: EKEventStore, operation: PlannerOperation<Value>) throws -> EKEvent? {
    try operation.check()
    if let id = entry.calendarEventID, let event = store.event(withIdentifier: id), owns(event, entry: entry) { return event }
    if let externalID = entry.calendarExternalID,
       let event = store.calendarItems(withExternalIdentifier: externalID).compactMap({ $0 as? EKEvent }).first(where: { owns($0, entry: entry) }) {
      try operation.check()
      return event
    }
    // Recovery searches at most two small windows. Keep the last synced date so
    // moving a local session by months still finds its original placeholder.
    let anchors = Set([entry.startDate, entry.calendarLastKnownStartDate].compactMap { $0 })
    for anchor in anchors {
      let start = anchor.addingTimeInterval(-7 * 86_400)
      let end = anchor.addingTimeInterval((7 * 86_400) + Double(entry.durationMinutes) * 60)
      if let event = try events(from: start, to: end, store: store, operation: operation).first(where: { owns($0, entry: entry) }) { return event }
    }
    return nil
  }

  private func perform<Value>(_ work: @escaping (EKEventStore, PlannerOperation<Value>) throws -> Value) async throws -> Value {
    try await run { store, operation in
      do { try operation.check(); let value = try work(store, operation); try operation.check(); operation.finish(.success(value)) }
      catch { operation.finish(.failure(error)) }
    }
  }
  private func run<Value>(timeout: TimeInterval = 12, _ work: @escaping (EKEventStore, PlannerOperation<Value>) -> Void) async throws -> Value {
    let operation = PlannerOperation<Value>()
    return try await withTaskCancellationHandler(operation: {
      try await withCheckedThrowingContinuation { continuation in
        operation.start(continuation)
        DispatchQueue.global().asyncAfter(deadline: .now() + timeout) { operation.cancel(error: PlannerError.timeout) }
        queue.async {
          do { try operation.check(); work(self.store, operation) }
          catch { operation.finish(.failure(error)) }
        }
      }
    }, onCancel: { operation.cancel(error: CancellationError()) })
  }
}

/// A callback, cancellation and deadline may race. Resume the continuation once.
private final class PlannerOperation<Value>: @unchecked Sendable {
  private let lock = NSLock()
  private var continuation: CheckedContinuation<Value, Error>?
  private var result: Result<Value, Error>?
  private var cancelled = false
  private var cancelAction: (() -> Void)?
  func start(_ continuation: CheckedContinuation<Value, Error>) {
    lock.lock()
    if let result { lock.unlock(); continuation.resume(with: result) }
    else { self.continuation = continuation; lock.unlock() }
  }
  func check() throws {
    lock.lock(); let stopped = cancelled; lock.unlock()
    if stopped { throw CancellationError() }
  }
  func finish(_ result: Result<Value, Error>) {
    lock.lock()
    guard self.result == nil else { lock.unlock(); return }
    self.result = result
    let continuation = self.continuation
    self.continuation = nil
    cancelAction = nil
    lock.unlock()
    continuation?.resume(with: result)
  }
  func onCancel(_ action: @escaping () -> Void) {
    lock.lock()
    let stopped = cancelled
    if !stopped && result == nil { cancelAction = action }
    lock.unlock()
    if stopped { action() }
  }
  func cancel(error: Error) {
    lock.lock()
    guard result == nil else { lock.unlock(); return }
    cancelled = true
    result = .failure(error)
    let continuation = self.continuation
    self.continuation = nil
    let action = cancelAction
    cancelAction = nil
    lock.unlock()
    continuation?.resume(throwing: error)
    action?()
  }
}
