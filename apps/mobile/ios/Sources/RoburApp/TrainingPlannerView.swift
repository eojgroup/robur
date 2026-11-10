import Charts
import SwiftUI

private enum TrainingOverviewMode: String, CaseIterable, Identifiable {
  case sessions = "Sessions", calendar = "Calendar", mix = "Mix"
  var id: String { rawValue }
}
private enum TrainingSessionFilter: String, CaseIterable, Identifiable {
  case all = "All", planned = "Planned", performed = "Performed"
  var id: String { rawValue }
}

@MainActor
struct TrainingPlannerView: View {
  @StateObject private var store: TrainingPlannerStore
  @EnvironmentObject private var healthKit: HealthKitClient
  @EnvironmentObject private var journal: WorkoutJournal
  @Environment(\.scenePhase) private var scenePhase
  @AppStorage("RoburTrainingBalanceCategories") private var categoryNames = "endurance,strength,mobility"
  @AppStorage("RoburTrainingBalanceActivities") private var activityNames = ""
  @AppStorage("RoburPlanSchedulingMode") private var schedulingMode = "gaps"
  @AppStorage("RoburPlanStartHour") private var startHour = 7
  @AppStorage("RoburPlanEndHour") private var endHour = 21
  @State private var newEntry: PlanEntry?
  @State private var weekOffset = 0
  @State private var selectedDay: Date?
  @State private var generating = false
  @State private var addingCalendarIDs: Set<UUID> = []
  @State private var resultMessage: String?
  @State private var offerExtraSession = false
  @State private var overviewMode: TrainingOverviewMode = .sessions
  @State private var sessionFilter: TrainingSessionFilter = .all
  @State private var selectedWorkout: WorkoutRecord?
  @State private var search = ""
  @State private var choosingWeek = false
  @State private var jumpDate = Date()

  init(store: TrainingPlannerStore? = nil) {
    _store = StateObject(wrappedValue: store ?? .shared)
  }

  private var categories: Set<TrainingCategory> {
    Set(categoryNames.split(separator: ",").compactMap { TrainingCategory(rawValue: String($0)) })
  }
  private var week: DateInterval {
    let date = Calendar.current.date(byAdding: .weekOfYear, value: weekOffset, to: Date()) ?? Date()
    return Calendar.current.dateInterval(of: .weekOfYear, for: date) ?? DateInterval(start: date, duration: 604_800)
  }
  private var days: [Date] {
    (0..<7).compactMap { Calendar.current.date(byAdding: .day, value: $0, to: week.start) }
  }
  private var weekEntries: [PlanEntry] {
    store.entries.filter { $0.startDate >= week.start && $0.startDate < week.end }.sorted { $0.startDate < $1.startDate }
  }
  private var weekWorkouts: [WorkoutRecord] {
    healthKit.workouts.filter { $0.start >= week.start && $0.start < week.end }.sorted { $0.start < $1.start }
  }
  private var comparisons: [TrainingSessionComparison] {
    TrainingSessionOverview.compare(plans: weekEntries, workouts: weekWorkouts)
  }
  private var visibleSessions: [TrainingSessionComparison] {
    comparisons.filter { session in
      if let selectedDay, !Calendar.current.isDate(session.date, inSameDayAs: selectedDay) { return false }
      if sessionFilter == .planned && session.plan == nil { return false }
      if sessionFilter == .performed && session.workout == nil { return false }
      guard !search.isEmpty else { return true }
      let workout = session.workout
      let annotation = workout.flatMap { journal.annotations[$0.id] }
      let text = [session.plan?.activity.title, session.plan?.muscleSummary, workout?.title,
        annotation?.notes, annotation?.muscles.map(\.rawValue).joined(separator: " ")].compactMap { $0 }.joined(separator: " ")
      return text.localizedCaseInsensitiveContains(search)
    }
  }
  private var coveredMuscles: Set<MuscleGroup> {
    Set(weekEntries.filter { $0.activity.category == .strength }.flatMap { $0.muscles })
  }

  var body: some View {
    NavigationStack {
      ScrollView {
        VStack(alignment: .leading, spacing: 14) {
          weekNavigation
          syncStatus
          Picker("Training view", selection: $overviewMode) {
            ForEach(TrainingOverviewMode.allCases) { mode in Text(mode.rawValue).tag(mode) }
          }.pickerStyle(.segmented)
          if overviewMode == .calendar {
            TrainingCalendarView(week: week, events: store.calendarEvents, entries: store.entries,
              isLoading: store.calendarEventsLoading, error: store.calendarEventsError,
              calendarAccess: store.calendarAccess, onEdit: { store.focusedEntryID = $0 },
              onConnect: {
                Task { await store.requestCalendarAccess(); await store.loadCalendarEvents(in: week) }
              }, selection: $selectedDay)
          } else if overviewMode == .mix {
            AdaptiveCardLayout { trainingMixCard; muscleCoverageCard }
          } else {
            overviewCard
          }
          sessionsSection
          if !healthKit.authorizationRequested {
            Button("Connect Apple Health", systemImage: "heart.text.square") { healthKit.requestAuthorization() }
              .buttonStyle(.bordered)
          }
          if let historyStart = healthKit.historyRange.startDate(), week.end < historyStart {
            Button("Read all workout history", systemImage: "clock.arrow.circlepath") {
              Task { await healthKit.loadHistory(range: .all) }
            }.disabled(healthKit.isLoadingHistory)
            Text("This week is outside the currently loaded Health history.").font(.caption).foregroundStyle(.secondary)
          }
          if healthKit.isLoadingHistory { ProgressView("Reading workout history…").font(.caption) }
          if let historyError = healthKit.historyError { Text(historyError).font(.caption).foregroundStyle(.red) }
          if let effortError = healthKit.effortImportError { Text(effortError).font(.caption).foregroundStyle(.secondary) }
          DisclosureGroup {
            Text("Nearby plan comparisons use the same activity and local day, starts within 3 hours, and durations between half and twice the plan. They are approximate and never mark a plan completed. A plan checked off in Robur or Reminders is separate from a workout recorded in Apple Health.")
              .font(.caption).foregroundStyle(.secondary)
          } label: { Text("How plan comparisons work").font(.caption) }
          DisclosureGroup {
            AdaptiveCardLayout { preferencesCard; calendarCard }
          } label: {
            Label("Suggestions & calendar settings", systemImage: "slider.horizontal.3").font(.headline)
          }
          .padding().background(RoburStyle.surface, in: RoundedRectangle(cornerRadius: 20))
        }
        .frame(maxWidth: RoburStyle.contentWidth).padding().frame(maxWidth: .infinity)
      }
      .background(RoburStyle.background)
      .navigationTitle("Training").navigationBarTitleDisplayMode(.inline)
      .searchable(text: $search, prompt: "Activity, muscle or notes")
      .toolbar {
        ToolbarItemGroup(placement: .topBarTrailing) {
          Button { PhoneWorkoutRecorder.shared.presentationRequested = true } label: { Image(systemName: "play.circle") }
            .accessibilityLabel("Start or continue a workout")
          Menu {
            Button("New session", systemImage: "plus") { createSession() }
            Button("Suggest sessions", systemImage: "sparkles") { generatePlan() }.disabled(categories.isEmpty || generating)
            Button("Choose week", systemImage: "calendar") { jumpDate = week.start; choosingWeek = true }
            NavigationLink { WorkoutHistoryView() } label: { Label("Workout history", systemImage: "clock.arrow.circlepath") }
          } label: { Image(systemName: "plus") }.accessibilityLabel("Training actions")
        }
      }
      .refreshable { await store.reconcile(); await healthKit.loadHistory(range: healthKit.historyRange) }
      .sheet(item: $selectedWorkout) { WorkoutDetailView(workout: $0) }
      .sheet(isPresented: $choosingWeek) {
        NavigationStack {
          DatePicker("Training week", selection: $jumpDate, displayedComponents: .date).datePickerStyle(.graphical).padding()
            .navigationTitle("Choose week")
            .toolbar {
              Button("Show week") {
                let current = Calendar.current.dateInterval(of: .weekOfYear, for: Date())?.start ?? Date()
                let target = Calendar.current.dateInterval(of: .weekOfYear, for: jumpDate)?.start ?? jumpDate
                weekOffset = Calendar.current.dateComponents([.weekOfYear], from: current, to: target).weekOfYear ?? 0
                selectedDay = nil; choosingWeek = false
              }
            }
        }.presentationDetents([.medium, .large])
      }
      .task { await store.reconcile() }
      .task(id: week.start) { await store.loadCalendarEvents(in: week) }
      .onChange(of: scenePhase) { _, phase in if phase == .active { Task { await store.reconcile() } } }
      .sheet(item: Binding(get: { store.entries.first { $0.id == store.focusedEntryID } },
                           set: { if $0 == nil { store.focusedEntryID = nil } })) { entry in
        TrainingPlanEditor(entry: entry, store: store)
      }
      .sheet(item: $newEntry) { entry in TrainingPlanEditor(entry: entry, store: store, isNew: true) }
      .onChange(of: store.actionMessage) { _, message in
        if message != nil { presentCalendarResult() }
      }
      .onChange(of: store.focusedEntryID) { _, _ in presentCalendarResult(); restoreCalendarWindow() }
      .onChange(of: newEntry?.id) { _, _ in presentCalendarResult(); restoreCalendarWindow() }
      .alert("Training plan", isPresented: Binding(get: { resultMessage != nil }, set: { if !$0 { resultMessage = nil } })) {
        if offerExtraSession { Button("Suggest one more session") { generatePlan(minimumNewSessions: 1) } }
        Button("OK", role: .cancel) { }
      } message: { Text(resultMessage ?? "") }
    }
  }

  private var weekNavigation: some View {
    VStack(alignment: .leading, spacing: 8) {
      HStack {
        Button { moveWeek(-1) } label: { Image(systemName: "chevron.left") }.accessibilityLabel("Previous week")
        Spacer()
        VStack(spacing: 3) {
          Button { jumpDate = week.start; choosingWeek = true } label: {
            Text(week.start.formatted(.dateTime.day().month()) + " – " +
              (days.last ?? week.start).formatted(.dateTime.day().month())).font(.headline)
          }.buttonStyle(.plain).accessibilityLabel("Choose training week")
          Text("\(weekEntries.count) planned · \(weekWorkouts.count) performed")
            .font(.caption).foregroundStyle(.secondary)
        }
        Spacer()
        Button { moveWeek(1) } label: { Image(systemName: "chevron.right") }.accessibilityLabel("Next week")
      }
      if weekOffset != 0 { Button("This week") { weekOffset = 0; selectedDay = nil }.font(.caption) }
    }
  }

  private var overviewCard: some View {
    VStack(alignment: .leading, spacing: 10) {
      Chart {
        ForEach(days, id: \.self) { day in
          BarMark(x: .value("Day", day, unit: .day), y: .value("Minutes", plannedMinutes(on: day)))
            .foregroundStyle(by: .value("Sessions", "Planned")).position(by: .value("Sessions", "Planned"))
          BarMark(x: .value("Day", day, unit: .day), y: .value("Minutes", performedMinutes(on: day)))
            .foregroundStyle(by: .value("Sessions", "Performed")).position(by: .value("Sessions", "Performed"))
        }
      }
      .chartForegroundStyleScale(["Planned": RoburStyle.blue.opacity(0.5), "Performed": RoburStyle.orange])
      .chartXScale(domain: week.start...week.end)
      .chartXAxis { AxisMarks(values: .stride(by: .day)) { AxisValueLabel(format: .dateTime.weekday(.narrow)) } }
      .chartYAxis { AxisMarks(position: .leading) }
      .chartYAxisLabel("min").frame(height: 135)
      HStack(spacing: 4) { ForEach(days, id: \.self) { day in dayButton(day) } }
    }.padding(14).background(RoburStyle.surface, in: RoundedRectangle(cornerRadius: 18))
      .accessibilityIdentifier("training-week-overview")
  }

  private func plannedMinutes(on day: Date) -> Double {
    Double(weekEntries.filter { Calendar.current.isDate($0.startDate, inSameDayAs: day) }.reduce(0) { $0 + $1.durationMinutes })
  }
  private func performedMinutes(on day: Date) -> Double {
    weekWorkouts.filter { Calendar.current.isDate($0.start, inSameDayAs: day) }.reduce(0) { $0 + $1.minutes }
  }

  private func dayButton(_ day: Date) -> some View {
    let planned = weekEntries.filter { Calendar.current.isDate($0.startDate, inSameDayAs: day) }.count
    let performed = weekWorkouts.filter { Calendar.current.isDate($0.start, inSameDayAs: day) }.count
    let selected = selectedDay.map { Calendar.current.isDate($0, inSameDayAs: day) } ?? false
    return Button { selectedDay = selected ? nil : day } label: {
      VStack(spacing: 5) {
        Text(day.formatted(.dateTime.weekday(.narrow))).font(.caption2).foregroundStyle(.secondary)
        Text(day.formatted(.dateTime.day())).font(.subheadline.bold())
        HStack(spacing: 3) {
          Circle().fill(planned > 0 ? RoburStyle.blue.opacity(0.6) : .clear).frame(width: 4, height: 4)
          Circle().fill(performed > 0 ? RoburStyle.orange : .clear).frame(width: 4, height: 4)
        }
      }.frame(maxWidth: .infinity).padding(.vertical, 7)
        .background(selected ? RoburStyle.orange.opacity(0.15) : .clear, in: RoundedRectangle(cornerRadius: 10))
    }.buttonStyle(.plain)
      .accessibilityLabel(day.formatted(date: .complete, time: .omitted) + ", \(planned) planned, \(performed) performed")
      .accessibilityAddTraits(selected ? .isSelected : [])
  }

  private var sessionsSection: some View {
    VStack(alignment: .leading, spacing: 10) {
      HStack {
        Text(selectedDay.map { $0.formatted(.dateTime.weekday(.abbreviated).day().month()) } ?? "Sessions").font(.headline)
        Spacer()
        if selectedDay != nil { Button("Show week") { selectedDay = nil }.font(.caption) }
        Button { generatePlan() } label: { Image(systemName: "sparkles") }
          .accessibilityLabel("Suggest training sessions").accessibilityIdentifier("generate-training-plan")
          .disabled(categories.isEmpty || generating)
      }
      Picker("Session filter", selection: $sessionFilter) {
        ForEach(TrainingSessionFilter.allCases) { filter in Text(filter.rawValue).tag(filter) }
      }.pickerStyle(.segmented)
      if generating { ProgressView("Finding training time…").font(.caption) }
      if visibleSessions.isEmpty {
        ContentUnavailableView("No sessions to show", systemImage: "calendar.badge.plus",
          description: Text("Add a session, choose another week or refresh Apple Health."))
        Button("New session", systemImage: "plus") { createSession() }.buttonStyle(.bordered)
          .accessibilityIdentifier("new-training-session")
      } else {
        LazyVStack(spacing: 0) {
          ForEach(visibleSessions) { session in
            if let entry = session.plan { entryCard(entry, workout: session.workout) }
            else if let workout = session.workout { performedRow(workout) }
            if session.id != visibleSessions.last?.id { Divider().padding(.horizontal, 12) }
          }
        }.background(RoburStyle.surface, in: RoundedRectangle(cornerRadius: 18))
      }
    }
  }

  private var mixCategories: [TrainingCategory] {
    TrainingCategory.allCases.filter { category in categories.contains(category) ||
      weekEntries.contains { $0.activity.category == category } || weekWorkouts.contains { $0.activityType.category == category } }
  }

  private var trainingMixCard: some View {
    VStack(alignment: .leading, spacing: 12) {
      Label("Training mix", systemImage: "chart.bar.fill").font(.headline)
      Chart {
        ForEach(mixCategories) { category in
          let planned = weekEntries.filter { $0.activity.category == category }.reduce(0) { $0 + $1.durationMinutes }
          let performed = weekWorkouts.filter { $0.activityType.category == category }.reduce(0) { $0 + $1.minutes }
          BarMark(x: .value("Minutes", Double(planned)), y: .value("Type", shortTitle(category)))
            .foregroundStyle(by: .value("Sessions", "Planned")).position(by: .value("Sessions", "Planned"))
          BarMark(x: .value("Minutes", performed), y: .value("Type", shortTitle(category)))
            .foregroundStyle(by: .value("Sessions", "Performed")).position(by: .value("Sessions", "Performed"))
        }
      }.chartForegroundStyleScale(["Planned": RoburStyle.blue.opacity(0.5), "Performed": RoburStyle.orange])
        .chartXAxisLabel("minutes").frame(height: max(130, CGFloat(mixCategories.count) * 44))
      Text("Planned includes suggestions and checked-off plans. Performed comes from Apple Health.")
        .font(.caption).foregroundStyle(.secondary)
    }.roburCard()
  }

  private var muscleCoverageCard: some View {
    VStack(alignment: .leading, spacing: 12) {
      Label("Muscle coverage", systemImage: "figure.strengthtraining.traditional").font(.headline)
      HStack { Text("Muscle"); Spacer(); Text("Planned / Performed") }.font(.caption2).foregroundStyle(.secondary)
      ForEach(MuscleGroup.allCases) { muscle in
        let planned = weekEntries.filter { $0.activity.category == .strength && $0.muscles.contains(muscle) }.count
        let performed = weekWorkouts.filter { $0.activityType.category == .strength &&
          (journal.annotations[$0.id]?.muscles.contains(muscle) ?? false) }.count
        HStack {
          Text(muscle.rawValue).font(.caption)
          Spacer()
          Text("\(planned)").foregroundStyle(RoburStyle.blue)
          Text("/").foregroundStyle(.secondary)
          Text("\(performed)").foregroundStyle(performed > 0 ? RoburStyle.orange : .secondary)
        }.font(.caption.bold()).monospacedDigit()
      }
      let missing = weekEntries.filter { $0.activity.category == .strength && $0.muscles.isEmpty }
      if !missing.isEmpty {
        Button("Add muscle focus to \(missing.count) plan\(missing.count == 1 ? "" : "s")") {
          store.focusedEntryID = missing.first?.id
        }.font(.caption)
      }
      Text("Performed muscle groups use your saved workout reviews.").font(.caption2).foregroundStyle(.secondary)
    }.roburCard()
  }

  @ViewBuilder private var syncStatus: some View {
    if let error = store.lastError { Text(error).font(.callout).foregroundStyle(.red) }
    if store.isWorking {
      HStack {
        ProgressView("Syncing Calendar & Reminders…")
        Spacer()
        Button("Stop sync") { store.cancelSync() }
      }
    }
    if store.pendingSyncCount > 0 {
      Text("\(store.pendingSyncCount) sessions waiting to sync").font(.caption).foregroundStyle(.secondary)
    }
    HStack {
      Text(store.status).font(.caption).foregroundStyle(.secondary).accessibilityIdentifier("plan-status")
      Spacer()
      if store.calendarAccess || store.remindersEnabled || store.pendingSyncCount > 0 {
        Button { Task { await store.reconcile() } } label: { Image(systemName: "arrow.clockwise") }
          .accessibilityLabel("Refresh Calendar and Reminders").disabled(store.isWorking)
      }
    }
  }

  private var preferencesCard: some View {
    VStack(alignment: .leading, spacing: 14) {
      Label("Find training time", systemImage: "sparkles").font(.headline)
      ForEach(TrainingCategory.allCases) { category in
        Toggle(category.title, isOn: Binding(get: { categories.contains(category) }, set: { enabled in
          var chosen = categories
          if enabled { chosen.insert(category) } else { chosen.remove(category) }
          categoryNames = chosen.map(\.rawValue).sorted().joined(separator: ",")
        }))
      }
      Picker("Find slots", selection: $schedulingMode) {
        Text("Flexible times").tag("gaps")
        Text("Custom hours").tag("custom")
      }.pickerStyle(.segmented)
      if schedulingMode == "custom" {
        HStack {
          Picker("From", selection: $startHour) { ForEach(0..<24, id: \.self) { Text(hourLabel($0)).tag($0) } }
          Picker("Until", selection: $endHour) { ForEach(1...24, id: \.self) { Text(hourLabel($0)).tag($0) } }
        }
        .onChange(of: startHour) { _, hour in if endHour <= hour { endHour = hour + 1 } }
        .onChange(of: endHour) { _, hour in if startHour >= hour { startHour = hour - 1 } }
      }
      Text(schedulingMode == "gaps" ? "Prefers morning, lunch and evening gaps, 07:00–21:00. " + (store.calendarAccess ? "Busy periods can still be suggested with an overlap warning." : "Connect Calendar to show existing events.") : store.calendarAccess ? "Prefers available time within this window; overlaps are allowed and marked." :
        "Connect Calendar to fit suggestions around your existing events.")
        .font(.caption).foregroundStyle(.secondary)
      Text("Suggestions cover the next seven days and balance your selected training types and recent muscle focus.")
        .font(.caption).foregroundStyle(.secondary)
      Text("Replaces local suggestions; keeps manual, confirmed and linked sessions. Times follow your current time zone.")
        .font(.caption).foregroundStyle(.secondary)
    }.roburCard()
  }

  private var calendarCard: some View {
    VStack(alignment: .leading, spacing: 14) {
      Label("Calendar & Reminders", systemImage: "calendar.badge.clock").font(.headline)
      if store.calendarAccess {
        Picker("Save sessions to", selection: Binding(get: { store.selectedCalendarID ?? "" }, set: { store.chooseCalendar($0) })) {
          Text("Choose a calendar").tag("")
          ForEach(store.calendars, id: \.calendarIdentifier) { Text($0.title).tag($0.calendarIdentifier) }
        }
        Button("Add planned sessions to Calendar", systemImage: "calendar.badge.plus") { Task { await store.exportPlaceholders() } }
          .buttonStyle(.borderedProminent)
          .disabled(store.selectedCalendarID == nil ||
            !store.entries.contains { !$0.calendarWasExported && $0.state != .completed && $0.endDate > Date() })
          .accessibilityIdentifier("export-training-placeholders")
      } else {
        Button("Connect Calendar", systemImage: "calendar") { Task { await store.requestCalendarAccess() } }
          .buttonStyle(.bordered).disabled(store.isWorking)
      }
      Text("In Calendar: remove [Suggested] to confirm, or prefix the title with [Completed] to finish. Muscle focus is included in the title. Changes sync when you return to Robur.")
        .font(.caption).foregroundStyle(.secondary)
      Divider()
      Toggle("Sync sessions with Reminders", isOn: Binding(get: { store.remindersEnabled }, set: { enabled in
        Task { await store.setRemindersEnabled(enabled) }
      })).disabled(store.isWorking)
      if store.remindersEnabled {
        if store.reminderAccess {
          Picker("Reminders list", selection: Binding(get: { store.selectedReminderListID ?? "" }, set: { store.chooseReminderList($0) })) {
            Text("Choose a list").tag("")
            ForEach(store.reminderLists, id: \.calendarIdentifier) { Text($0.title).tag($0.calendarIdentifier) }
          }
          Text("Remove [Suggested] to confirm. Check a reminder to complete its session in Robur.")
            .font(.caption).foregroundStyle(.secondary)
        } else { Text("Enable Reminders access in Settings to sync.").font(.caption) }
      }
      Link("Open app settings", destination: URL(string: UIApplication.openSettingsURLString)!).font(.caption)
    }.roburCard()
  }

  private func entryCard(_ entry: PlanEntry, workout: WorkoutRecord? = nil) -> some View {
    VStack(alignment: .leading, spacing: 6) {
      HStack(alignment: .top, spacing: 10) {
        Image(systemName: entry.activity.symbol).font(.title3).foregroundStyle(color(entry.activity.category))
          .frame(width: 28, height: 30)
        Button {
          if let workout { selectedWorkout = workout } else { store.focusedEntryID = entry.id }
        } label: {
          VStack(alignment: .leading, spacing: 4) {
            Text(entry.activity.title).font(.subheadline.bold())
            Text(entry.startDate.formatted(.dateTime.weekday(.abbreviated).hour().minute()) + " · \(entry.durationMinutes) min planned")
              .font(.caption).foregroundStyle(.secondary)
            if entry.activity.category == .strength {
              Text(entry.muscles.isEmpty ? "Choose muscle focus" : entry.muscleSummary)
                .font(.caption).foregroundStyle(RoburStyle.orange)
            }
          }.frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
        }.buttonStyle(.plain)
        VStack(alignment: .trailing, spacing: 6) {
          Text(entry.state == .completed ? "Plan checked" : entry.state.title).font(.caption2.weight(.medium))
            .foregroundStyle(stateColor(entry.state))
          entryMenu(entry)
        }
      }
      if let workout {
        Button { selectedWorkout = workout } label: {
          HStack(spacing: 5) {
            Image(systemName: "checkmark.circle.fill")
            Text("Performed \(workout.start.formatted(.dateTime.hour().minute())) · \(Int(workout.minutes)) min")
            if let effort = workout.appleEffort { Text(String(format: "· %.1f/10", effort)) }
            Spacer(minLength: 0)
            Image(systemName: "chevron.right")
          }.font(.caption).foregroundStyle(RoburStyle.orange)
        }.buttonStyle(.plain)
        Text("Near planned session · comparison only").font(.caption2).foregroundStyle(.secondary)
      }
      let overlaps = TrainingCalendar.conflicts(for: entry, events: store.calendarEvents, plans: store.entries)
      if !overlaps.isEmpty {
        Label("\(overlaps.count) overlap\(overlaps.count == 1 ? "" : "s") · allowed", systemImage: "exclamationmark.triangle")
          .font(.caption2).foregroundStyle(RoburStyle.orange)
      }
      if entry.calendarSyncPending == true || entry.reminderSyncPending == true {
        Label("Sync pending", systemImage: "arrow.clockwise").font(.caption2).foregroundStyle(.secondary)
      }
    }.padding(12)
  }

  private func performedRow(_ workout: WorkoutRecord) -> some View {
    let annotation = journal.annotations[workout.id] ?? WorkoutAnnotation()
    return Button { selectedWorkout = workout } label: {
      HStack(alignment: .top, spacing: 10) {
        Image(systemName: workout.symbol).font(.title3).foregroundStyle(RoburStyle.orange).frame(width: 28, height: 30)
        VStack(alignment: .leading, spacing: 4) {
          Text(workout.title).font(.subheadline.bold())
          Text(workout.start.formatted(.dateTime.weekday(.abbreviated).hour().minute()) + " · \(Int(workout.minutes)) min")
            .font(.caption).foregroundStyle(.secondary)
          if !annotation.muscles.isEmpty {
            Text(annotation.muscles.map(\.rawValue).sorted().joined(separator: ", ")).font(.caption).foregroundStyle(RoburStyle.orange)
          }
          Text("Not linked to a plan").font(.caption2).foregroundStyle(.secondary)
        }
        Spacer(minLength: 4)
        VStack(alignment: .trailing, spacing: 5) {
          Label("Performed", systemImage: "checkmark.circle.fill").font(.caption2).foregroundStyle(RoburStyle.orange)
          if let effort = workout.appleEffort { Text(String(format: "%.1f/10", effort)).font(.caption.bold()) }
          Image(systemName: "chevron.right").font(.caption2).foregroundStyle(.secondary)
        }
      }.padding(12).contentShape(Rectangle())
    }.buttonStyle(.plain)
  }

  private func entryMenu(_ entry: PlanEntry) -> some View {
    Menu {
      Button("Edit session", systemImage: "pencil") { store.focusedEntryID = entry.id }
      if entry.state == .suggested {
        Button("Confirm", systemImage: "checkmark") {
          if entry.activity.category == .strength && entry.muscles.isEmpty { store.focusedEntryID = entry.id }
          else { Task { await store.confirm(id: entry.id) } }
        }
      } else if entry.state == .confirmed {
        Button("Start workout", systemImage: "play.fill") {
          PhoneWorkoutRecorder.shared.queueStart(activity: entry.activity)
          if !PhoneWorkoutRecorder.shared.isActive { PhoneWorkoutRecorder.shared.muscleGroups = entry.muscles }
        }
        Button("Mark plan completed", systemImage: "checkmark.circle") { Task { await store.complete(id: entry.id) } }
      }
      if (!entry.calendarWasExported || entry.calendarEventID == nil) && entry.state != .completed && entry.endDate > Date() {
        Button(addingCalendarIDs.contains(entry.id) ? "Adding to Calendar…" : "Add to Calendar", systemImage: "calendar.badge.plus") {
          addingCalendarIDs.insert(entry.id)
          Task {
            defer { addingCalendarIDs.remove(entry.id) }
            if !store.calendarAccess { await store.requestCalendarAccess() }
            if store.calendarAccess { await store.exportPlaceholders(ids: [entry.id], allowReExport: entry.calendarWasExported) }
          }
        }.disabled(addingCalendarIDs.contains(entry.id))
          .accessibilityIdentifier("add-session-to-calendar-\(entry.id.uuidString)")
      }
      Button("Move one day later", systemImage: "calendar.badge.clock") { _ = store.reschedule(id: entry.id, days: 1) }
      Button("Move one week later", systemImage: "calendar.badge.clock") { _ = store.reschedule(id: entry.id, days: 7) }
      Button("Duplicate session", systemImage: "plus.square.on.square") {
        let date = Calendar.current.date(byAdding: .day, value: 7, to: entry.startDate) ?? entry.startDate
        if let id = store.duplicate(id: entry.id, startDate: date) { store.focusedEntryID = id }
      }
    } label: { Image(systemName: "ellipsis.circle").font(.title3).padding(4) }
      .accessibilityLabel("Actions for \(entry.activity.title)")
  }

  private func generatePlan(minimumNewSessions: Int = 0) {
    guard !generating else { return }
    generating = true
    Task {
      defer { generating = false }
      if !store.calendarAccess { await store.requestCalendarAccess() }
      let added = await store.generateWeek(workouts: healthKit.analyticsWorkouts, categories: categories, annotations: journal.annotations,
        preferredActivities: Set(activityNames.split(separator: ",").compactMap { WorkoutActivity(rawValue: String($0)) }),
        startHour: schedulingMode == "gaps" ? 7 : startHour, endHour: schedulingMode == "gaps" ? 21 : endHour,
        minimumNewSessions: minimumNewSessions)
      weekOffset = 0; selectedDay = nil
      await store.loadCalendarEvents(in: week)
      let limit = Calendar.current.date(byAdding: .day, value: 7, to: Date()) ?? Date()
      let planned = store.entries.filter { $0.startDate >= Date() && $0.startDate < limit }.count
      offerExtraSession = added == 0 && planned >= 3 && minimumNewSessions == 0
      if let added, added > 0 {
        resultMessage = "Added \(added) editable suggestion\(added == 1 ? "" : "s") for the next seven days. Available time is preferred; overlapping sessions are marked and can still be saved or added to Calendar."
      } else if offerExtraSession {
        resultMessage = "You already have \(planned) sessions in the next seven days. Your existing sessions were kept. You can ask for one more suggestion or edit a session to move it."
      } else if added == 0 {
        resultMessage = "No new session fits the remaining training days and time window. Calendar overlaps are allowed. Try wider hours or another training type in Suggestions & calendar settings."
      } else { resultMessage = store.lastError ?? "The search did not finish. Your existing plan was kept. Please retry." }
    }
  }

  private func presentCalendarResult() {
    guard store.focusedEntryID == nil, newEntry == nil, let message = store.actionMessage else { return }
    offerExtraSession = false
    resultMessage = message
    store.actionMessage = nil
  }

  private func restoreCalendarWindow() {
    guard store.focusedEntryID == nil, newEntry == nil else { return }
    Task { await store.loadCalendarEvents(in: week) }
  }

  private func createSession() {
    let nextHour = Calendar.current.nextDate(after: Date(), matching: DateComponents(minute: 0), matchingPolicy: .nextTime) ?? Date()
    var start = nextHour
    if let targetDay = selectedDay ?? (weekOffset == 0 ? nil : week.start),
       let date = Calendar.current.date(bySettingHour: 12, minute: 0, second: 0, of: targetDay) { start = date }
    newEntry = PlanEntry(activity: .functionalStrength, startDate: start, durationMinutes: 30, state: .confirmed)
  }
  private func moveWeek(_ delta: Int) { weekOffset += delta; selectedDay = nil }
  private func hourLabel(_ hour: Int) -> String { hour == 24 ? "24:00" : String(format: "%02d:00", hour) }
  private func stateColor(_ state: PlanEntryState) -> Color {
    switch state { case .suggested: return RoburStyle.orange.opacity(0.5); case .confirmed: return RoburStyle.blue; case .completed: return .teal }
  }
  private func stateSymbol(_ state: PlanEntryState) -> String {
    switch state { case .suggested: return "circle.dashed"; case .confirmed: return "circle.fill"; case .completed: return "checkmark.circle.fill" }
  }
  private func shortTitle(_ category: TrainingCategory) -> String {
    switch category { case .endurance: return "Endurance"; case .mobility: return "Mobility"; default: return category.title }
  }
  private func color(_ category: TrainingCategory) -> Color {
    switch category {
    case .strength: return RoburStyle.orange
    case .endurance: return RoburStyle.blue
    case .mobility: return .teal
    case .sport: return .purple
    case .other: return .secondary
    }
  }
}

@MainActor
struct TrainingPlanEditor: View {
  @State var entry: PlanEntry
  @ObservedObject var store: TrainingPlannerStore
  var isNew = false
  @Environment(\.dismiss) private var dismiss
  @State private var showingCalendarRemoval = false
  @State private var showingSessionRemoval = false
  @State private var updatingCalendar = false
  @State private var hasCreatedEntry = false
  @State private var validationMessage: String?

  private var savedEntry: PlanEntry { store.entries.first { $0.id == entry.id } ?? entry }
  private var isUnsaved: Bool { isNew && !hasCreatedEntry }
  private var calendarSearchWindow: DateInterval {
    let week = Calendar.current.dateInterval(of: .weekOfYear, for: entry.startDate) ??
      DateInterval(start: Calendar.current.startOfDay(for: entry.startDate), duration: 604_800)
    return DateInterval(start: week.start, end: max(week.end, entry.endDate))
  }
  private var calendarDataCoversSession: Bool {
    guard let window = store.calendarWindow else { return false }
    return window.start <= entry.startDate && window.end >= entry.endDate && store.calendarEventsError == nil
  }
  private var sessionEvents: [TrainingCalendarEvent] { calendarDataCoversSession ? store.calendarEvents : [] }
  private var overlaps: [TrainingCalendarConflict] {
    TrainingCalendar.conflicts(for: entry, events: sessionEvents, plans: store.entries)
  }

  var body: some View {
    NavigationStack {
      Form {
        Section("Session") {
          Picker("Activity", selection: $entry.activity) {
            ForEach(WorkoutActivity.allCases) { Text($0.title).tag($0) }
          }
          DatePicker("Start", selection: $entry.startDate, displayedComponents: [.date, .hourAndMinute])
          LabeledContent("Duration (minutes)") {
            TextField("Minutes", value: $entry.durationMinutes, format: .number)
              .multilineTextAlignment(.trailing).frame(maxWidth: 90)
          }
          Stepper("Adjust duration", value: $entry.durationMinutes, in: 1...1_440, step: 5)
          Picker("State", selection: $entry.state) {
            ForEach(PlanEntryState.allCases, id: \.self) { Text($0.title).tag($0) }
          }
          Text("Completed plans are marked by you. You can change the state again at any time.")
            .font(.caption).foregroundStyle(.secondary)
        }
        if entry.activity.category == .strength {
          Section("Muscle focus") {
            muscleFocusFields
            Text("Choose the muscles you intend to train. This focus is included in Calendar and Reminders.")
              .font(.caption).foregroundStyle(.secondary)
          }
        } else if !entry.muscles.isEmpty {
          Section { DisclosureGroup("Muscle focus") { muscleFocusFields } }
        }
        calendarFitSection
        Section("Move session") {
          Button("One day later") { moveDraft(days: 1) }
          Button("One week later") { moveDraft(days: 7) }
          Text("Keeps the same local time. Save to apply the new date.").font(.caption).foregroundStyle(.secondary)
        }
        if let validationMessage { Section { Text(validationMessage).foregroundStyle(.red) } }
        if let error = store.lastError { Section { Text(error).foregroundStyle(.red) } }
        Section {
          Button(isUnsaved ? "Create session" : "Save changes") {
            Task { if await persist() != nil { dismiss() } }
          }
          .accessibilityIdentifier("save-training-session")
          if !isUnsaved {
            Button("Duplicate session for next week", systemImage: "plus.square.on.square") {
              Task {
                guard let id = await persist() else { return }
                let date = Calendar.current.date(byAdding: .day, value: 7, to: entry.startDate) ?? entry.startDate
                if store.duplicate(id: id, startDate: date) != nil { dismiss() }
              }
            }
          }
          Text("Changes save on this device immediately. Linked Calendar events and optional reminders sync in the background.")
            .font(.caption).foregroundStyle(.secondary)
          if savedEntry.calendarSyncPending == true || savedEntry.reminderSyncPending == true {
            Label("Saved locally · sync pending", systemImage: "arrow.clockwise")
            Button("Retry sync") { Task { await store.reconcile() } }.disabled(store.isWorking)
          }
        }
        Section("Calendar") {
          if updatingCalendar { ProgressView("Updating Calendar & Reminders…") }
          if let message = store.actionMessage, !updatingCalendar {
            Text(message).font(.callout).foregroundStyle(.secondary)
          }
          if savedEntry.calendarWasExported {
            if savedEntry.calendarEventID != nil {
              Label("Linked to Calendar", systemImage: "link")
              Text("Saving changes queues an update to this session's Calendar event.")
                .font(.caption).foregroundStyle(.secondary)
              Button("Remove from Calendar", role: .destructive) { showingCalendarRemoval = true }
            } else {
              Label("Calendar unlinked", systemImage: "link.badge.plus")
              Text("Your local plan is kept. Add it again to create a Calendar placeholder.")
                .font(.caption).foregroundStyle(.secondary)
              if entry.state != .completed && entry.endDate > Date() { calendarAddControls(allowReExport: true) }
            }
          } else if entry.state != .completed && entry.endDate > Date() {
            calendarAddControls(allowReExport: false)
          } else { Text("Only in your local plan").foregroundStyle(.secondary) }
        }.disabled(updatingCalendar)
        if !isUnsaved {
          Section {
            Button("Delete session", role: .destructive) { showingSessionRemoval = true }
              .disabled(updatingCalendar)
            Text("Deletes this session and its linked Robur Calendar events and reminders.")
              .font(.caption).foregroundStyle(.secondary)
          }
        }
      }
      .navigationTitle(isUnsaved ? "New session" : "Edit session").navigationBarTitleDisplayMode(.inline)
      .task(id: calendarSearchWindow) { await store.loadCalendarEvents(in: calendarSearchWindow) }
      .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Close") { dismiss() } } }
      .confirmationDialog("Remove this session from Calendar?", isPresented: $showingCalendarRemoval, titleVisibility: .visible) {
        Button("Remove from Calendar", role: .destructive) {
          updatingCalendar = true
          Task { await store.removeCalendarPlaceholder(id: entry.id); updatingCalendar = false }
        }
      } message: {
        Text("Deletes this session's linked Calendar event and reminders. Your local plan is kept. Adding it again is an explicit action.")
      }
      .confirmationDialog("Delete this training session?", isPresented: $showingSessionRemoval, titleVisibility: .visible) {
        Button("Delete session and linked items", role: .destructive) {
          updatingCalendar = true
          Task {
            await store.removeSession(id: entry.id)
            updatingCalendar = false
            if !store.entries.contains(where: { $0.id == entry.id }) { dismiss() }
          }
        }
      }
    }.tint(RoburStyle.orange)
  }

  private var calendarFitSection: some View {
    Section("Calendar fit") {
      if !overlaps.isEmpty {
        TrainingOverlapPreview(entry: entry, conflicts: overlaps)
        let minutes = Int(TrainingCalendar.overlappingMinutes(for: entry, events: sessionEvents, plans: store.entries).rounded(.up))
        Label("\(minutes) min overlaps · you can still save and add", systemImage: "exclamationmark.triangle.fill")
          .font(.callout).foregroundStyle(RoburStyle.orange)
        ForEach(overlaps) { item in
          VStack(alignment: .leading, spacing: 3) {
            Text(item.title).font(.subheadline.weight(.medium))
            Text(item.calendarTitle + " · " + (item.isAllDay ? "All day" :
              item.startDate.formatted(date: .omitted, time: .shortened) + "–" + item.endDate.formatted(date: .omitted, time: .shortened)))
              .font(.caption).foregroundStyle(.secondary)
          }
        }
      }
      if store.calendarEventsLoading { ProgressView("Checking calendar…") }
      else if let error = store.calendarEventsError { Text(error).font(.caption).foregroundStyle(.secondary) }
      else if store.calendarAccess && calendarDataCoversSession && overlaps.isEmpty {
        Label("No overlaps in the connected calendars", systemImage: "checkmark.circle").foregroundStyle(.secondary)
      }
      if !store.calendarAccess {
        Button("Connect Calendar to see existing events") {
          Task { await store.requestCalendarAccess(); await store.loadCalendarEvents(in: calendarSearchWindow) }
        }
      }
      Text("Calendar conflicts are advisory. Saving a session or adding it to Calendar is always allowed.")
        .font(.caption).foregroundStyle(.secondary)
    }
  }

  private var muscleFocusFields: some View {
    VStack(alignment: .leading, spacing: 12) {
      ViewThatFits(in: .horizontal) {
        HStack { musclePresets }
        VStack(alignment: .leading) { musclePresets }
      }
      LazyVGrid(columns: [GridItem(.adaptive(minimum: 95))], spacing: 8) {
        ForEach(MuscleGroup.allCases) { muscle in
          let selected = entry.muscles.contains(muscle)
          Button {
            if selected { entry.muscles.remove(muscle) } else { entry.muscles.insert(muscle) }
            validationMessage = nil
          } label: {
            HStack(spacing: 4) {
              Image(systemName: selected ? "checkmark.circle.fill" : "circle")
              Text(muscle.rawValue)
            }
            .font(.subheadline).frame(maxWidth: .infinity).padding(.vertical, 9)
            .foregroundStyle(selected ? RoburStyle.orange : RoburStyle.ink)
            .background(selected ? RoburStyle.orange.opacity(0.12) : RoburStyle.background, in: Capsule())
          }.buttonStyle(.plain).accessibilityAddTraits(selected ? .isSelected : [])
        }
      }
    }
  }

  @ViewBuilder private var musclePresets: some View {
    Button("Full body") { entry.muscles = Set(MuscleGroup.allCases); validationMessage = nil }
    Button("Upper body") { entry.muscles = [.chest, .back, .shoulders, .arms, .core]; validationMessage = nil }
    Button("Lower body") { entry.muscles = [.quads, .hamstrings, .glutes, .calves, .core]; validationMessage = nil }
  }

  private func moveDraft(days: Int) {
    if let date = Calendar.current.date(byAdding: .day, value: days, to: entry.startDate) { entry.startDate = date }
  }

  private func persist() async -> UUID? {
    guard entry.activity.category != .strength || !entry.muscles.isEmpty else {
      validationMessage = "Select at least one muscle group or choose a focus preset."
      return nil
    }
    validationMessage = nil
    if isUnsaved {
      guard let id = store.create(activity: entry.activity, startDate: entry.startDate, durationMinutes: entry.durationMinutes,
                                  muscles: entry.muscles, state: entry.state) else { return nil }
      entry.id = id
      hasCreatedEntry = true
      return id
    }
    let saved = await store.update(id: entry.id, startDate: entry.startDate, durationMinutes: entry.durationMinutes,
      activity: entry.activity, muscles: entry.muscles, state: entry.state)
    return saved ? entry.id : nil
  }

  @ViewBuilder private func calendarAddControls(allowReExport: Bool) -> some View {
    if store.calendarAccess {
      Picker("Calendar", selection: Binding(get: { store.selectedCalendarID ?? "" }, set: { store.chooseCalendar($0) })) {
        Text("Choose a calendar").tag("")
        ForEach(store.calendars, id: \.calendarIdentifier) { Text($0.title).tag($0.calendarIdentifier) }
      }
    }
    Button(allowReExport ? "Add again to Calendar" : "Save & add to Calendar", systemImage: "calendar.badge.plus") {
      updatingCalendar = true
      Task {
        defer { updatingCalendar = false }
        guard let id = await persist() else { return }
        if !store.calendarAccess { await store.requestCalendarAccess() }
        guard store.calendarAccess else { return }
        await store.exportPlaceholders(ids: [id], allowReExport: allowReExport)
        if store.entries.first(where: { $0.id == id })?.calendarEventID != nil { dismiss() }
      }
    }
    Text("Saves locally first, then adds only this session. Calendar access is requested if needed.")
      .font(.caption).foregroundStyle(.secondary)
  }
}

private struct TrainingOverlapPreview: View {
  let entry: PlanEntry
  let conflicts: [TrainingCalendarConflict]
  private var bounds: ClosedRange<Date> {
    entry.startDate.addingTimeInterval(-900)...entry.endDate.addingTimeInterval(900)
  }
  var body: some View {
    Chart {
      BarMark(xStart: .value("Start", entry.startDate), xEnd: .value("End", entry.endDate), y: .value("Source", "Robur"))
        .foregroundStyle(RoburStyle.orange)
      ForEach(conflicts) { item in
        BarMark(xStart: .value("Start", max(bounds.lowerBound, item.startDate)),
          xEnd: .value("End", min(bounds.upperBound, item.endDate)), y: .value("Source", "Calendar / plan"))
          .foregroundStyle(Color.red.opacity(0.7))
      }
    }
    .chartXScale(domain: bounds)
    .chartXAxis { AxisMarks(values: .automatic(desiredCount: 4)) { AxisValueLabel(format: .dateTime.hour().minute()) } }
    .frame(height: 100)
    .accessibilityLabel("Your workout overlaps the calendar or planned sessions shown below")
  }
}
