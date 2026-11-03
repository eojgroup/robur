import Combine
import EventKit
import Foundation

struct TrainingPlanCalendar: Identifiable {
  let calendarIdentifier: String
  let title: String
  var id: String { calendarIdentifier }
}

/// A user action waits for an in-flight refresh instead of disappearing behind it.
@MainActor
final class TrainingPlanOperationQueue {
  private var running = false
  private var waiters: [CheckedContinuation<Void, Never>] = []
  func acquire() async {
    if running { await withCheckedContinuation { waiters.append($0) } }
    else { running = true }
  }
  func release() {
    if waiters.isEmpty { running = false }
    else { waiters.removeFirst().resume() }
  }
}

protocol TrainingPlanEventWorking {
  func requestAccess(reminders: Bool) async throws -> Bool
  func availability(now: Date, calendar: Calendar) async throws -> [DateInterval]
  func calendarEvents(in interval: DateInterval) async throws -> [TrainingCalendarEvent]
  func refresh(entries: [PlanEntry], settings: TrainingPlanEventWorker.Settings) async throws -> TrainingPlanEventWorker.Snapshot
  func syncCalendarChanges(entries: [PlanEntry]) async throws -> [PlanEntry]
  func export(entries: [PlanEntry], settings: TrainingPlanEventWorker.Settings, ids: Set<UUID>?, allowReExport: Bool,
              progress: @escaping ([PlanEntry]) -> Void) async throws -> TrainingPlanEventWorker.ExportResult
  func remove(entry: PlanEntry, includeReminders: Bool) async throws
  func syncReminders(entries: [PlanEntry], settings: TrainingPlanEventWorker.Settings) async throws -> [PlanEntry]
}

extension TrainingPlanEventWorking {
  func calendarEvents(in interval: DateInterval) async throws -> [TrainingCalendarEvent] { [] }
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
  @Published private(set) var syncReminderCompletion = true
  @Published private(set) var calendarAccess = false
  @Published private(set) var reminderAccess = false
  @Published private(set) var calendarEvents: [TrainingCalendarEvent] = []
  @Published private(set) var calendarWindow: DateInterval?
  @Published private(set) var calendarEventsLoading = false
  @Published private(set) var calendarEventsError: String?
  // This describes external sync only. Local editing never takes this lock.
  @Published private(set) var isWorking = false
  @Published var lastError: String?
  @Published var status = "Your plan stays on this device until you add it to Calendar."
  @Published var focusedEntryID: UUID?
  @Published var actionMessage: String?
  var pendingSyncCount: Int { entries.filter { $0.calendarSyncPending == true || $0.reminderSyncPending == true }.count }
  private let worker: any TrainingPlanEventWorking
  private let operationQueue = TrainingPlanOperationQueue()
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
  private var requestedCalendarWindow: DateInterval?

  private struct Archive: Codable, Equatable {
    var version = 1
    var entries: [PlanEntry]
    var calendarID: String?
    var reminderListID: String?
    var remindersEnabled = false
    var syncReminderCompletion = true
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
       externalAccessDisabled: Bool = false, worker: (any TrainingPlanEventWorking)? = nil) {
    self.url = url ?? URL.applicationSupportDirectory.appending(path: "Robur/training-plan.json")
    self.externalAccessDisabled = externalAccessDisabled
    self.worker = worker ?? TrainingPlanEventWorker(eventStore: eventStore)
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

  /// Calendar context is an in-memory view, separate from the saved training plan.
  /// Changing weeks discards the previous week's events immediately so an older
  /// asynchronous response cannot paint the wrong dates or imply a clear calendar.
  func loadCalendarEvents(in interval: DateInterval) async {
    guard interval.start.timeIntervalSince1970.isFinite, interval.end.timeIntervalSince1970.isFinite,
          interval.duration > 0, interval.duration <= 35 * 86_400 else {
      requestedCalendarWindow = nil
      calendarEvents = []; calendarWindow = nil
      calendarEventsLoading = false
      calendarEventsError = "Choose a Calendar range of up to 35 days."
      return
    }
    if requestedCalendarWindow == interval && calendarEventsLoading { return }
    requestedCalendarWindow = interval
    if calendarWindow != interval { calendarEvents = []; calendarWindow = nil }
    calendarEventsError = nil
    guard !externalAccessDisabled else {
      calendarEvents = []; calendarWindow = nil; calendarEventsLoading = false
      calendarEventsError = "Connect Calendar to see existing events. Your local plan still works."
      return
    }
    calendarEventsLoading = true
    defer { if requestedCalendarWindow == interval { calendarEventsLoading = false } }
    await performExternal { await self.refreshCalendarEvents(in: interval) }
  }

  /// Called inside the existing serial sync operation; never reacquires its lock.
  private func refreshCalendarEvents(in interval: DateInterval) async {
    guard requestedCalendarWindow == interval else { return }
    calendarEventsLoading = true
    defer { if requestedCalendarWindow == interval { calendarEventsLoading = false } }
    do {
      let events = try await worker.calendarEvents(in: interval)
      guard requestedCalendarWindow == interval else { return }
      calendarEvents = events.filter { $0.startDate < interval.end && $0.endDate > interval.start }
        .sorted { $0.startDate == $1.startDate ? $0.id < $1.id : $0.startDate < $1.startDate }
      calendarWindow = interval
      calendarEventsError = nil
      calendarAccess = true
    } catch {
      guard requestedCalendarWindow == interval else { return }
      calendarEvents = []; calendarWindow = nil
      if case PlannerError.calendarReadAccess = error { calendarAccess = false }
      calendarEventsError = error is CancellationError ? "Calendar refresh stopped. Retry to check existing events." : error.localizedDescription
    }
  }

  @discardableResult
  func create(activity: WorkoutActivity, startDate: Date, durationMinutes: Int,
              muscles: Set<MuscleGroup> = [], state: PlanEntryState = .confirmed) -> UUID? {
    var entry = PlanEntry(activity: activity, startDate: startDate, durationMinutes: durationMinutes, muscles: muscles, state: state)
    entry.isManualSession = true
    entry.localModificationDate = Date()
    entry.reminderSyncPending = remindersEnabled ? true : nil
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
    var copy = original.duplicated(startDate: startDate)
    copy.localModificationDate = Date()
    copy.reminderSyncPending = remindersEnabled ? true : nil
    guard copy.isValid else { return nil }
    var next = archive; next.entries.append(copy)
    guard commit(next) else { return nil }
    status = "Session duplicated in your local plan. Review it before adding it to Calendar."
    scheduleSync()
    return copy.id
  }

  @discardableResult
  func reschedule(id: UUID, days: Int, calendar: Calendar = .current) -> Bool {
    guard let entry = entries.first(where: { $0.id == id }),
          let date = calendar.date(byAdding: .day, value: days, to: entry.startDate) else { return false }
    return saveLocalEdit(id: id, startDate: date, durationMinutes: entry.durationMinutes)
  }

  @discardableResult
  func generateWeek(workouts: [WorkoutRecord], categories: Set<TrainingCategory>,
                    annotations: [String: WorkoutAnnotation] = [:],
                    preferredActivities: Set<WorkoutActivity> = [], startHour: Int = 7, endHour: Int = 21,
                    now: Date = Date(), calendar: Calendar = .current, minimumNewSessions: Int = 0) async -> Int? {
    // Suggestions must use today's readable calendars, not a previous screen visit's
    // cache. Failed or cancelled fetches leave the existing plan untouched.
    if !externalAccessDisabled && EKEventStore.authorizationStatus(for: .event) == .fullAccess {
      var receivedAvailability = false
      await performExternal {
        do {
          self.cachedBusy = try await self.worker.availability(now: now, calendar: calendar)
          self.calendarAccess = true
          receivedAvailability = true
        } catch { self.externalError(error) }
      }
      guard receivedAvailability else { return nil }
    } else { cachedBusy = []; calendarAccess = false }
    var next = archive
    next.entries.removeAll { $0.state == .suggested && !$0.calendarWasExported &&
      !$0.reminderWasCreated && $0.isManualSession != true && !exportingIDs.contains($0.id) }
    let generated = TrainingPlanner.suggest(workouts: workouts, existing: next.entries, annotations: annotations,
      categories: categories, preferredActivities: preferredActivities, busy: cachedBusy, now: now, startHour: startHour, endHour: endHour, calendar: calendar, minimumNewSessions: minimumNewSessions)
    next.entries.append(contentsOf: generated.map { suggestion in
      var entry = suggestion
      entry.localModificationDate = Date()
      entry.reminderSyncPending = remindersEnabled ? true : nil
      return entry
    })
    if commit(next) {
      status = generated.isEmpty ? "No new slots fit. Try a wider time window or review retained plans." :
        (calendarAccess ? "\(generated.count) suggestions ready. Review their timing and any Calendar overlaps before adding sessions." :
          "\(generated.count) local suggestions. Connect Calendar to fit them around your existing events.")
      scheduleSync()
      return generated.count
    }
    return nil
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
    next.entries[index].localModificationDate = Date()
    guard next.entries[index].isValid else { lastError = "Choose a duration between 1 minute and 24 hours."; return false }
    // Save first, even when access has been revoked or an external request is stalled.
    if next.entries[index].calendarEventID != nil {
      if next.entries[index].calendarSyncPending != true || next.entries[index].calendarLastKnownStartDate == nil {
        next.entries[index].calendarLastKnownStartDate = entries[index].startDate
      }
      next.entries[index].calendarSyncPending = true
    }
    if next.remindersEnabled {
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

  /// Remove a session and its owned external items only after cleanup succeeds.
  func removeSession(id: UUID) async {
    guard entries.contains(where: { $0.id == id }) else { return }
    await performExternal {
      guard let entry = self.entries.first(where: { $0.id == id }) else { return }
      do {
        if entry.calendarWasExported || entry.reminderWasCreated {
          guard !self.externalAccessDisabled else { throw PlannerError.calendarAccess }
          try await self.worker.remove(entry: entry, includeReminders: true)
        }
        var next = self.archive; next.entries.removeAll { $0.id == id }
        if self.commit(next) {
          self.lastError = nil
          self.status = "Session and its linked Calendar and Reminders items removed."
          self.actionMessage = self.status
        } else { self.actionMessage = self.lastError }
        if let window = self.requestedCalendarWindow { await self.refreshCalendarEvents(in: window) }
      } catch { self.externalError(error); self.actionMessage = self.lastError }
    }
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
      next.entries[index].reminderSyncPending = enabled ? true : nil
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
    actionMessage = nil
    guard !externalAccessDisabled else { lastError = "Connect Calendar with full access to add a placeholder."; actionMessage = lastError; return }
    if let ids, ids.isEmpty { return }
    guard commit(archive) else { actionMessage = lastError; return }
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
        self.lastError = nil
        self.merge(result.entries, baseline: baseline)
        guard self.lastError == nil else { self.actionMessage = self.lastError; return }
        if self.pendingSyncCount > 0 { self.needsAnotherSync = true }
        self.status = "Added \(result.inserted) Calendar placeholder\(result.inserted == 1 ? "" : "s")." +
          (result.conflicting > 0 ? " \(result.conflicting) session\(result.conflicting == 1 ? " overlaps" : "s overlap") existing Calendar events. Review the overlap in your plan." : "")
        self.actionMessage = result.inserted > 0 || result.conflicting > 0 ? self.status :
          "No Calendar event was added. This session may already be linked, completed, or in the past. Review its details and selected calendar."
        if let window = self.requestedCalendarWindow { await self.refreshCalendarEvents(in: window) }
      } catch { self.externalError(error); self.actionMessage = self.lastError }
    }
  }

  /// Exact ownership is checked again on the worker before deleting anything.
  func removeCalendarPlaceholder(id: UUID) async {
    guard !externalAccessDisabled else { lastError = "Connect Calendar with full access to remove this placeholder."; return }
    guard let entry = entries.first(where: { $0.id == id }), entry.calendarWasExported else { return }
    guard commit(archive) else { return }
    await performExternal {
      do {
        try await self.worker.remove(entry: entry, includeReminders: true)
        guard let index = self.entries.firstIndex(where: { $0.id == id }) else { return }
        var next = self.archive
        next.entries[index].calendarEventID = nil
        next.entries[index].calendarExternalID = nil
        next.entries[index].calendarContainerID = nil
        next.entries[index].calendarLastKnownStartDate = nil
        next.entries[index].calendarSyncPending = nil
        next.entries[index].reminderID = nil
        next.entries[index].reminderWasCreated = true
        next.entries[index].reminderSyncPending = nil
        // Keep the export tombstone: refresh and bulk export must not recreate it.
        if self.commit(next) {
          self.lastError = nil
          self.status = "Removed this session from Calendar and its linked reminders. Your local plan was kept."
          self.actionMessage = self.status
        } else { self.actionMessage = self.lastError }
        if let window = self.requestedCalendarWindow { await self.refreshCalendarEvents(in: window) }
      } catch { self.externalError(error); self.actionMessage = self.lastError }
    }
  }

  func reconcile() async {
    guard !externalAccessDisabled else { return }
    guard !isWorking else { needsAnotherSync = true; return }
    await performExternal {
      let baseline = self.entries
      let settings = self.settings
      do {
        let snapshot = try await self.worker.refresh(entries: baseline, settings: settings)
        self.calendarAccess = snapshot.calendarAccess
        self.reminderAccess = snapshot.reminderAccess
        self.calendars = snapshot.calendars
        self.reminderLists = snapshot.reminderLists
        self.cachedBusy = snapshot.busy
        if !snapshot.calendars.contains(where: { $0.id == self.selectedCalendarID }) { self.chooseCalendar(snapshot.defaultCalendarID) }
        if !snapshot.reminderLists.contains(where: { $0.id == self.selectedReminderListID }) {
          var next = self.archive; next.reminderListID = snapshot.defaultReminderListID; _ = self.commit(next)
        }
        self.merge(snapshot.entries, baseline: baseline)
        if snapshot.reminderAccess && (settings.remindersEnabled || self.entries.contains(where: { $0.calendarWasExported && $0.calendarEventID == nil })) {
          let reminderBaseline = self.entries
          let synced = try await self.worker.syncReminders(entries: reminderBaseline, settings: self.settings)
          self.merge(synced, baseline: reminderBaseline)
        }
        // A Reminder checkbox or due-date edit must update its linked Calendar in
        // this pass, rather than waiting for another foreground/notification.
        if snapshot.calendarAccess && self.entries.contains(where: { $0.calendarSyncPending == true }) {
          let calendarBaseline = self.entries
          let synced = try await self.worker.syncCalendarChanges(entries: calendarBaseline)
          self.merge(synced, baseline: calendarBaseline)
          if synced.contains(where: { entry in entry.reminderSyncPending == true &&
            calendarBaseline.first(where: { $0.id == entry.id })?.reminderSyncPending != true }) {
            self.needsAnotherSync = true
          }
        }
        if self.pendingSyncCount == 0 {
          self.lastError = nil
          self.status = "Local plan saved. Calendar and Reminders are up to date where connected."
        }
        if let window = self.requestedCalendarWindow { await self.refreshCalendarEvents(in: window) }
      } catch { self.externalError(error) }
    }
  }

  func cancelSync() {
    needsAnotherSync = false
    externalTask?.cancel()
    status = "Sync stopped. Your local plan is saved; retry when ready."
  }

  private func eventStoreChanged() {
    // Our own writes also emit this notification. Coalesce changes arriving
    // during sync into one later pass; reconciliation only writes actual changes.
    guard !isWorking else { needsAnotherSync = true; return }
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
    await operationQueue.acquire()
    guard !Task.isCancelled else { operationQueue.release(); return }
    localSyncTask?.cancel()
    localSyncTask = nil
    isWorking = true
    let task = Task { await work() }
    externalTask = task
    await task.value
    externalTask = nil
    isWorking = false
    operationQueue.release()
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
        if next.entries[index].calendarLastModifiedDate == old.calendarLastModifiedDate {
          next.entries[index].calendarLastModifiedDate = result.calendarLastModifiedDate
          next.entries[index].calendarLastSyncedTitle = result.calendarLastSyncedTitle
        }
        if next.entries[index].reminderLastModifiedDate == old.reminderLastModifiedDate {
          next.entries[index].reminderLastModifiedDate = result.reminderLastModifiedDate
          next.entries[index].reminderLastSyncedTitle = result.reminderLastSyncedTitle
          next.entries[index].reminderLastSyncedCompleted = result.reminderLastSyncedCompleted
        }
        if next.entries[index].calendarExternalID == old.calendarExternalID {
          next.entries[index].calendarExternalID = result.calendarExternalID
        }
        if next.entries[index].calendarContainerID == old.calendarContainerID {
          next.entries[index].calendarContainerID = result.calendarContainerID
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
    // Older releases silently ignored checked reminders unless this switch was
    // enabled. Connected Reminders now always share completion with Robur.
    syncReminderCompletion = true
  }

  @discardableResult private func commit(_ next: Archive) -> Bool {
    do {
      guard !unreadableArchive else { throw PlannerError.invalidArchive }
      let data = try JSONEncoder().encode(next)
      try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
      try data.write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
      apply(next)
      return true
    } catch {
      lastError = "Could not save your plan: \(error.localizedDescription). Local changes were rolled back."
      return false
    }
  }
}

private enum PlannerError: LocalizedError {
  case invalidArchive, calendarAccess, calendarReadAccess, reminderAccess, readOnly, timeout, reminderFetch
  var errorDescription: String? {
    switch self {
    case .invalidArchive: return "The saved plan could not be read and has been preserved."
    case .calendarAccess: return "Full Calendar access and a writable calendar are required."
    case .calendarReadAccess: return "Full Calendar access is off. Connect Calendar to see existing events."
    case .reminderAccess: return "Enable Reminders access in Settings to remove this session's linked reminders."
    case .readOnly: return "This Calendar event is now read-only."
    case .timeout: return "Calendar or Reminders took too long to respond."
    case .reminderFetch: return "Reminders did not return a result. No new reminders were created."
    }
  }
}

/// EventKit's synchronous database calls must never run on the main actor.
/// Each operation has a deadline; a cancelled/expired result cannot change local state.
final class TrainingPlanEventWorker: TrainingPlanEventWorking, @unchecked Sendable {
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

  func availability(now: Date, calendar: Calendar) async throws -> [DateInterval] {
    try await perform { store, operation in
      guard EKEventStore.authorizationStatus(for: .event) == .fullAccess else { throw PlannerError.calendarAccess }
      let end = calendar.date(byAdding: .day, value: 7, to: now) ?? now
      return try self.busyIntervals(from: now, to: end, store: store, operation: operation)
    }
  }

  func calendarEvents(in interval: DateInterval) async throws -> [TrainingCalendarEvent] {
    try await perform { store, operation in
      guard EKEventStore.authorizationStatus(for: .event) == .fullAccess else { throw PlannerError.calendarReadAccess }
      var seen: Set<String> = []
      return try self.events(from: interval.start, to: interval.end, store: store, operation: operation).compactMap { event in
        guard event.status != .canceled, let start = event.startDate, let end = event.endDate,
              start.timeIntervalSince1970.isFinite, end.timeIntervalSince1970.isFinite, end > start else { return nil }
        let id = "\(event.eventIdentifier ?? event.calendarItemIdentifier)|\(start.timeIntervalSinceReferenceDate)"
        guard seen.insert(id).inserted else { return nil }
        let title = (event.title ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        return TrainingCalendarEvent(id: id, title: title.isEmpty ? "Untitled event" : title,
          calendarTitle: event.calendar.title, startDate: start, endDate: end,
          isAllDay: event.isAllDay, blocksTime: event.availability != .free,
          linkedPlanID: self.linkedPlanID(for: event))
      }
    }
  }

  func refresh(entries: [PlanEntry], settings: Settings) async throws -> Snapshot {
    try await perform { store, operation in
      let calendarAccess = EKEventStore.authorizationStatus(for: .event) == .fullAccess
      let reminderAccess = EKEventStore.authorizationStatus(for: .reminder) == .fullAccess
      let calendars = calendarAccess ? store.calendars(for: .event).filter(\.allowsContentModifications) : []
      let lists = reminderAccess ? store.calendars(for: .reminder).filter(\.allowsContentModifications) : []
      var next = entries
      if calendarAccess {
        for index in next.indices where next[index].calendarEventID != nil || next[index].calendarSyncPending == true {
          try operation.check()
          var entry = next[index]
          if let event = try self.findEvent(for: entry, store: store, operation: operation) {
            let before = entry
            let calendarContentChanged = event.title != entry.calendarLastSyncedTitle ||
              event.startDate != entry.calendarLastKnownStartDate ||
              event.endDate != entry.endDate ||
              (entry.state == .suggested && entry.calendarUsesTentativeAvailability && event.availability == .busy)
            let importChange = TrainingPlanExternalSync.shouldImport(modified: event.lastModifiedDate,
              observed: entry.calendarLastModifiedDate, pending: entry.calendarSyncPending == true,
              competing: [entry.localModificationDate], contentChanged: calendarContentChanged)
            if importChange {
              entry.reconcile(start: event.startDate, end: event.endDate, title: event.title ?? "", isBusy: event.availability == .busy)
              entry.calendarSyncPending = nil
              if entry.startDate != before.startDate || entry.durationMinutes != before.durationMinutes || entry.state != before.state {
                TrainingPlanExternalSync.recordSessionChange(entry: &entry, modified: event.lastModifiedDate)
                if settings.remindersEnabled { entry.reminderSyncPending = true }
              }
            }
            entry.calendarEventID = event.eventIdentifier
            entry.calendarExternalID = event.calendarItemExternalIdentifier
            entry.calendarContainerID = event.calendar.calendarIdentifier
            entry.calendarLastKnownStartDate = event.startDate
            entry.calendarLastModifiedDate = event.lastModifiedDate
            entry.calendarLastSyncedTitle = event.title
            // Upgrade existing default titles and focus summaries after reading both
            // sources. An early write here would hide an older unchecked Reminder edit.
            if event.calendar.allowsContentModifications &&
                (self.desiredTitle(event.title ?? "", entry: entry) != event.title ||
                self.notes(existing: event.notes, entry: entry) != event.notes) {
              entry.calendarSyncPending = true
            }
          } else if self.calendarUnavailable(for: entry, fallback: settings.calendarID, store: store) {
            // An unavailable account/calendar is not evidence that its event was
            // deleted. Keep links and reminders until the calendar is accessible.
            entry.calendarSyncPending = true
            entry.calendarContainerID = entry.calendarContainerID ?? settings.calendarID
          } else {
            entry.calendarEventID = nil
            entry.calendarSyncPending = nil
            // A deleted Calendar session must not leave a live reminder behind.
            if entry.calendarWasExported && entry.reminderWasCreated { entry.reminderSyncPending = true }
          }
          next[index] = entry
        }
      }
      let now = Date()
      let end = Calendar.current.date(byAdding: .day, value: 7, to: now) ?? now
      let busy = calendarAccess ? try self.busyIntervals(from: now, to: end, store: store, operation: operation) : []
      return Snapshot(entries: next, calendarAccess: calendarAccess, reminderAccess: reminderAccess,
        calendars: calendars.map { .init(calendarIdentifier: $0.calendarIdentifier, title: $0.title) },
        reminderLists: lists.map { .init(calendarIdentifier: $0.calendarIdentifier, title: $0.title) },
        defaultCalendarID: calendarAccess ? store.defaultCalendarForNewEvents?.calendarIdentifier : nil,
        defaultReminderListID: reminderAccess ? store.defaultCalendarForNewReminders()?.calendarIdentifier : nil, busy: busy)
    }
  }

  func syncCalendarChanges(entries: [PlanEntry]) async throws -> [PlanEntry] {
    try await perform { store, operation in
      var next = entries
      for index in next.indices where next[index].calendarSyncPending == true {
        try operation.check()
        var entry = next[index]
        if let event = try self.findEvent(for: entry, store: store, operation: operation) {
          // Refetching may reveal an edit made after this pass's first snapshot.
          if TrainingPlanExternalSync.shouldImport(modified: event.lastModifiedDate,
              observed: entry.calendarLastModifiedDate, pending: true, competing: [entry.localModificationDate]) {
            let previous = entry
            entry.reconcile(start: event.startDate, end: event.endDate, title: event.title ?? "", isBusy: event.availability == .busy)
            entry.calendarSyncPending = nil
            if entry.startDate != previous.startDate || entry.durationMinutes != previous.durationMinutes || entry.state != previous.state {
              TrainingPlanExternalSync.recordSessionChange(entry: &entry, modified: event.lastModifiedDate)
              if entry.reminderWasCreated { entry.reminderSyncPending = true }
            }
          }
          entry.calendarLastModifiedDate = event.lastModifiedDate
          entry.calendarLastSyncedTitle = event.title
          guard event.calendar.allowsContentModifications else { next[index] = entry; continue }
          try self.update(event: event, entry: entry, store: store, operation: operation)
          entry.calendarEventID = event.eventIdentifier
          entry.calendarExternalID = event.calendarItemExternalIdentifier
          entry.calendarContainerID = event.calendar.calendarIdentifier
          entry.calendarLastKnownStartDate = event.startDate
          entry.calendarLastModifiedDate = event.lastModifiedDate
          entry.calendarLastSyncedTitle = event.title
        } else if self.calendarUnavailable(for: entry, store: store) {
          next[index] = entry
          continue
        } else { entry.calendarEventID = nil }
        entry.calendarSyncPending = nil
        next[index] = entry
      }
      return next
    }
  }

  func export(entries: [PlanEntry], settings: Settings, ids: Set<UUID>?, allowReExport: Bool,
              progress: @escaping ([PlanEntry]) -> Void) async throws -> ExportResult {
    try await perform { store, operation in
      guard EKEventStore.authorizationStatus(for: .event) == .fullAccess,
            let calendar = store.calendars(for: .event).first(where: { $0.calendarIdentifier == (settings.calendarID ?? store.defaultCalendarForNewEvents?.calendarIdentifier) && $0.allowsContentModifications }) else {
        throw PlannerError.calendarAccess
      }
      var result = ExportResult(entries: entries)
      for index in result.entries.indices where (ids?.contains(result.entries[index].id) ?? true) &&
        (!result.entries[index].calendarWasExported || (ids != nil && allowReExport)) &&
        result.entries[index].state != .completed && result.entries[index].endDate > Date() {
        try operation.check()
        var entry = result.entries[index]
        let restoring = entry.calendarWasExported && entry.calendarEventID == nil && allowReExport
        let conflict = try self.events(from: entry.startDate, to: entry.endDate, store: store, operation: operation).contains { event in
          guard !self.owns(event, entry: entry), event.availability != .free, event.status != .canceled,
                let start = event.startDate, let end = event.endDate, end > start else { return false }
          return TrainingPlanner.overlaps(DateInterval(start: entry.startDate, end: entry.endDate), DateInterval(start: start, end: end))
        }
        // Adding is explicit user intent. A busy calendar is advisory, never a
        // reason to discard the request or force another scheduling round.
        if conflict { result.conflicting += 1 }
        if let found = try self.findEvent(for: entry, store: store, operation: operation) {
          entry.calendarEventID = found.eventIdentifier
          entry.calendarExternalID = found.calendarItemExternalIdentifier
          entry.calendarContainerID = found.calendar.calendarIdentifier
          entry.calendarWasExported = true
          entry.calendarUsesTentativeAvailability = found.calendar.supportedEventAvailabilities.contains(.tentative)
          // An explicit add uses the currently reviewed local values.
          try self.update(event: found, entry: entry, store: store, operation: operation)
        } else {
          let event = EKEvent(eventStore: store)
          event.calendar = calendar
          event.title = entry.calendarTitle
          event.startDate = entry.startDate
          event.endDate = entry.endDate
          event.timeZone = .current
          event.url = entry.url
          entry.calendarUsesTentativeAvailability = calendar.supportedEventAvailabilities.contains(.tentative)
          event.notes = self.notes(existing: nil, entry: entry)
          if entry.state == .suggested && entry.calendarUsesTentativeAvailability { event.availability = .tentative }
          else if calendar.supportedEventAvailabilities.contains(.busy) { event.availability = .busy }
          try operation.check()
          try store.save(event, span: .thisEvent, commit: true)
          entry.calendarEventID = event.eventIdentifier
          entry.calendarExternalID = event.calendarItemExternalIdentifier
          entry.calendarContainerID = event.calendar.calendarIdentifier
          entry.calendarWasExported = true
          result.inserted += 1
        }
        entry.calendarLastKnownStartDate = entry.startDate
        if let id = entry.calendarEventID, let savedEvent = store.event(withIdentifier: id) {
          entry.calendarLastModifiedDate = savedEvent.lastModifiedDate
          entry.calendarLastSyncedTitle = savedEvent.title
        }
        entry.calendarSyncPending = nil
        if restoring && entry.reminderID == nil && settings.remindersEnabled {
          entry.reminderWasCreated = false
          entry.reminderSyncPending = true
          entry.reminderLastModifiedDate = nil
          entry.reminderLastSyncedTitle = nil
          entry.reminderLastSyncedCompleted = nil
        }
        result.entries[index] = entry
        // Checkpoint links after every external save, including a partial bulk export.
        progress(result.entries)
      }
      return result
    }
  }

  func remove(entry: PlanEntry, includeReminders: Bool) async throws {
    let _: Bool = try await perform { store, operation in
      if entry.calendarWasExported {
        guard EKEventStore.authorizationStatus(for: .event) == .fullAccess else { throw PlannerError.calendarAccess }
        guard !self.calendarUnavailable(for: entry, store: store) else { throw PlannerError.calendarAccess }
        if let event = try self.findEvent(for: entry, store: store, operation: operation) {
          guard event.calendar.allowsContentModifications else { throw PlannerError.readOnly }
          try operation.check()
          try store.remove(event, span: .thisEvent, commit: true)
        }
      }
      return true
    }
    guard includeReminders, entry.reminderWasCreated || entry.reminderID != nil else { return }
    let _: Bool = try await run { store, operation in
      guard EKEventStore.authorizationStatus(for: .reminder) == .fullAccess else {
        operation.finish(.failure(PlannerError.reminderAccess)); return
      }
      let predicate = store.predicateForReminders(in: nil)
      let token = store.fetchReminders(matching: predicate) { reminders in
        self.queue.async {
          do {
            try operation.check()
            guard let reminders else { throw PlannerError.reminderFetch }
            // Search all lists so retries, moved items and older duplicates are cleaned.
            for reminder in reminders where self.owns(reminder, entry: entry) {
              guard reminder.calendar.allowsContentModifications else { throw PlannerError.readOnly }
              try operation.check(); try store.remove(reminder, commit: true)
            }
            operation.finish(.success(true))
          } catch { operation.finish(.failure(error)) }
        }
      }
      operation.onCancel { self.queue.async { self.store.cancelFetchRequest(token) } }
    }
  }

  func syncReminders(entries: [PlanEntry], settings: Settings) async throws -> [PlanEntry] {
    return try await run { store, operation in
      guard EKEventStore.authorizationStatus(for: .reminder) == .fullAccess else { operation.finish(.success(entries)); return }
      let lists = store.calendars(for: .reminder).filter { $0.calendarIdentifier == settings.reminderListID && $0.allowsContentModifications }
      // Fetch all lists: moved items and older retries share the same ownership URL.
      let predicate = store.predicateForReminders(in: nil)
      let token = store.fetchReminders(matching: predicate) { reminders in
        self.queue.async {
          do {
            try operation.check()
            guard let reminders else { throw PlannerError.reminderFetch }
            let next = try self.applyReminders(entries: entries, all: reminders, list: lists.first, settings: settings, store: store, operation: operation)
            operation.finish(.success(next))
          } catch { operation.finish(.failure(error)) }
        }
      }
      operation.onCancel { self.queue.async { self.store.cancelFetchRequest(token) } }
    }
  }

  private func applyReminders(entries: [PlanEntry], all: [EKReminder], list: EKCalendar?, settings: Settings,
                              store: EKEventStore, operation: PlannerOperation<[PlanEntry]>) throws -> [PlanEntry] {
    var next = entries
    for index in next.indices {
      try operation.check()
      var entry = next[index]
      let owned = all.filter { self.owns($0, entry: entry) }
      if entry.calendarWasExported && entry.calendarEventID == nil {
        var blocked = false
        for reminder in owned {
          guard reminder.calendar.allowsContentModifications else { blocked = true; continue }
          try operation.check(); try store.remove(reminder, commit: true)
        }
        entry.reminderID = blocked ? owned.first(where: { !$0.calendar.allowsContentModifications })?.calendarItemIdentifier : nil
        entry.reminderWasCreated = true
        entry.reminderSyncPending = blocked ? true : nil
        next[index] = entry
        continue
      }
      guard settings.remindersEnabled else { continue }
      let byID = entry.reminderID.flatMap { store.calendarItem(withIdentifier: $0) as? EKReminder }
      let known = byID.flatMap { self.owns($0, entry: entry) ? $0 : nil }
      var candidates = owned
      if let known, !candidates.contains(where: { $0.calendarItemIdentifier == known.calendarItemIdentifier }) {
        candidates.append(known)
      }
      var reminder = candidates.sorted {
        if $0.calendarItemIdentifier == $1.calendarItemIdentifier { return false }
        // Favor a completed item if an older retry left duplicate reminders.
        if $0.isCompleted != $1.isCompleted { return $0.isCompleted }
        let left = $0.lastModifiedDate ?? .distantPast, right = $1.lastModifiedDate ?? .distantPast
        if left != right { return left > right }
        if $0.calendarItemIdentifier == entry.reminderID { return true }
        if $1.calendarItemIdentifier == entry.reminderID { return false }
        return $0.calendarItemIdentifier < $1.calendarItemIdentifier
      }.first
      let isNew = reminder == nil && list != nil && !entry.reminderWasCreated && entry.state != .completed && entry.endDate > Date()
      if isNew, let list {
        let created = EKReminder(eventStore: store)
        created.calendar = list
        created.title = entry.reminderTitle
        created.url = entry.url
        created.notes = self.notes(existing: nil, entry: entry)
        reminder = created
      }
      guard let reminder else {
        entry.reminderID = nil
        entry.reminderSyncPending = list == nil && !entry.reminderWasCreated ? true : nil
        next[index] = entry
        continue
      }
      // Keep one owned reminder. Never touch entries from another plan or app.
      for duplicate in owned where duplicate.calendarItemIdentifier != reminder.calendarItemIdentifier && duplicate.calendar.allowsContentModifications {
        try operation.check(); try store.remove(duplicate, commit: true)
      }
      let previousDue = reminder.dueDateComponents.flatMap { TrainingPlanExternalSync.reminderDate($0, fallback: entry.startDate) }
      let previousSessionAlarm = Calendar.current.date(from: Calendar.current.dateComponents(
        [.calendar, .timeZone, .year, .month, .day, .hour, .minute], from: entry.startDate))
      let reminderContentChanged = reminder.title != entry.reminderLastSyncedTitle ||
        reminder.isCompleted != entry.reminderLastSyncedCompleted ||
        (reminder.dueDateComponents != nil && !TrainingPlanExternalSync.sameReminderDate(reminder.dueDateComponents, sessionStart: entry.startDate))
      let importChange = !isNew && TrainingPlanExternalSync.shouldImport(modified: reminder.lastModifiedDate,
        observed: entry.reminderLastModifiedDate, pending: entry.reminderSyncPending == true,
        competing: [entry.localModificationDate], contentChanged: reminderContentChanged)
      if importChange {
        entry.reminderSyncPending = nil
        if TrainingPlanExternalSync.reconcileReminder(entry: &entry, due: previousDue,
            title: reminder.title ?? "", isCompleted: reminder.isCompleted) {
          TrainingPlanExternalSync.recordSessionChange(entry: &entry, modified: reminder.lastModifiedDate)
          if entry.calendarEventID != nil { entry.calendarSyncPending = true }
        }
      }
      entry.reminderLastModifiedDate = reminder.lastModifiedDate
      entry.reminderLastSyncedTitle = reminder.title
      entry.reminderLastSyncedCompleted = reminder.isCompleted
      // Import changes from a moved read-only list too, but never write into it.
      guard reminder.calendar.allowsContentModifications else { next[index] = entry; continue }
      let due = Calendar.current.dateComponents([.calendar, .timeZone, .year, .month, .day, .hour, .minute], from: entry.startDate)
      let alarmDate = Calendar.current.date(from: due) ?? entry.startDate
      // Providers normalize calendar/time-zone metadata. Compare the represented
      // minute, not DateComponents equality, or our own saves can loop forever.
      // Preserve date-only/cleared due dates unless a local session edit is pending.
      let dateChanged = isNew || (reminder.dueDateComponents != nil &&
        !TrainingPlanExternalSync.sameReminderDate(reminder.dueDateComponents, sessionStart: entry.startDate)) ||
        (entry.reminderSyncPending == true && reminder.dueDateComponents?.hour == nil)
      var changed = dateChanged
      var alarms = reminder.alarms ?? []
      if isNew && !alarms.contains(where: { $0.absoluteDate == alarmDate }) {
        alarms.append(EKAlarm(absoluteDate: alarmDate)); reminder.alarms = alarms; changed = true
      } else if let priorAlarm = importChange ? previousSessionAlarm : previousDue,
                priorAlarm != alarmDate,
                let alarmIndex = alarms.firstIndex(where: { $0.absoluteDate == priorAlarm }) {
        alarms[alarmIndex] = EKAlarm(absoluteDate: alarmDate); reminder.alarms = alarms; changed = true
      }
      if dateChanged { reminder.dueDateComponents = due }
      let title = self.desiredTitle(reminder.title ?? "", entry: entry)
      if reminder.title != title { reminder.title = title; changed = true }
      let notes = self.notes(existing: reminder.notes, entry: entry)
      if reminder.notes != notes { reminder.notes = notes; changed = true }
      let completed = entry.state == .completed
      if reminder.isCompleted != completed { reminder.isCompleted = completed; changed = true }
      if changed { try operation.check(); try store.save(reminder, commit: true) }
      entry.reminderID = reminder.calendarItemIdentifier
      entry.reminderWasCreated = true
      entry.reminderSyncPending = nil
      entry.reminderLastModifiedDate = reminder.lastModifiedDate
      entry.reminderLastSyncedTitle = reminder.title
      entry.reminderLastSyncedCompleted = reminder.isCompleted
      next[index] = entry
    }
    return next
  }

  private func update<Value>(event: EKEvent, entry: PlanEntry, store: EKEventStore, operation: PlannerOperation<Value>) throws {
    guard event.calendar.allowsContentModifications else { throw PlannerError.readOnly }
    var changed = false
    if event.startDate != entry.startDate { event.startDate = entry.startDate; changed = true }
    if event.endDate != entry.endDate { event.endDate = entry.endDate; changed = true }
    let desired = desiredTitle(event.title ?? "", entry: entry)
    if event.title != desired { event.title = desired; changed = true }
    let notes = self.notes(existing: event.notes, entry: entry)
    if event.notes != notes { event.notes = notes; changed = true }
    let availability: EKEventAvailability = entry.state == .suggested && event.calendar.supportedEventAvailabilities.contains(.tentative) ? .tentative : .busy
    if event.calendar.supportedEventAvailabilities.contains(availability == .tentative ? .tentative : .busy), event.availability != availability {
      event.availability = availability; changed = true
    }
    if changed { try operation.check(); try store.save(event, span: .thisEvent, commit: true) }
  }

  private func desiredTitle(_ existing: String, entry: PlanEntry) -> String {
    TrainingPlanExternalSync.title(existing: existing, entry: entry)
  }

  private func notes(existing: String?, entry: PlanEntry) -> String {
    TrainingPlanExternalSync.notes(existing: existing, entry: entry)
  }

  private func busyIntervals<Value>(from start: Date, to end: Date, store: EKEventStore,
                                   operation: PlannerOperation<Value>) throws -> [DateInterval] {
    try events(from: start, to: end, store: store, operation: operation).compactMap { event in
      guard event.availability != .free, event.status != .canceled,
            let start = event.startDate, let end = event.endDate, end > start else { return nil }
      return DateInterval(start: start, end: end)
    }
  }

  private func owns(_ item: EKCalendarItem, entry: PlanEntry) -> Bool {
    item.url == entry.url || (item.notes ?? "").components(separatedBy: .newlines).contains("Robur plan ID: \(entry.id.uuidString)")
  }
  private func linkedPlanID(for item: EKCalendarItem) -> UUID? {
    if let url = item.url, url.scheme?.lowercased() == "robur", url.host?.lowercased() == "plan",
       url.pathComponents.count == 2, let id = UUID(uuidString: url.lastPathComponent) { return id }
    let marker = "Robur plan ID: "
    return (item.notes ?? "").components(separatedBy: .newlines).compactMap { line in
      line.hasPrefix(marker) ? UUID(uuidString: String(line.dropFirst(marker.count))) : nil
    }.first
  }
  private func calendarUnavailable(for entry: PlanEntry, fallback: String? = nil, store: EKEventStore) -> Bool {
    guard let id = entry.calendarContainerID ?? fallback else { return false }
    return store.calendar(withIdentifier: id) == nil
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
