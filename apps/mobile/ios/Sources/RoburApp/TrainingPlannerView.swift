import Charts
import SwiftUI

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
  private var visible: [PlanEntry] {
    guard let selectedDay else { return weekEntries }
    return weekEntries.filter { Calendar.current.isDate($0.startDate, inSameDayAs: selectedDay) }
  }
  private var coveredMuscles: Set<MuscleGroup> {
    Set(weekEntries.filter { $0.activity.category == .strength }.flatMap { $0.muscles })
  }

  var body: some View {
    NavigationStack {
      ScrollView {
        VStack(alignment: .leading, spacing: 20) {
          ViewThatFits(in: .horizontal) {
            HStack {
              planHeading.fixedSize(horizontal: true, vertical: false)
              Spacer()
              newSessionButton
            }
            VStack(alignment: .leading, spacing: 12) { planHeading; newSessionButton }
          }
          overviewCard
          Button("Find free training time", systemImage: "sparkles") { generatePlan() }
            .buttonStyle(.borderedProminent).disabled(categories.isEmpty || store.isWorking)
            .accessibilityIdentifier("generate-training-plan")
          AdaptiveCardLayout {
            trainingMixCard
            muscleCoverageCard
          }
          HStack {
            Text(selectedDay.map { $0.formatted(.dateTime.weekday(.wide).day().month()) } ?? "Sessions this week")
              .font(.title2.bold())
            Spacer()
            if selectedDay != nil { Button("Show week") { selectedDay = nil } }
          }
          if visible.isEmpty {
            ContentUnavailableView("Space for a session", systemImage: "calendar.badge.plus",
              description: Text("Add a session or find free training time."))
          }
          AdaptiveCardLayout { ForEach(visible) { entry in entryCard(entry) } }
          syncStatus
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
      .navigationTitle("Plan").navigationBarTitleDisplayMode(.inline)
      .task { await store.reconcile() }
      .onChange(of: scenePhase) { _, phase in if phase == .active { Task { await store.reconcile() } } }
      .sheet(item: Binding(get: { store.entries.first { $0.id == store.focusedEntryID } },
                           set: { if $0 == nil { store.focusedEntryID = nil } })) { entry in
        TrainingPlanEditor(entry: entry, store: store)
      }
      .sheet(item: $newEntry) { entry in TrainingPlanEditor(entry: entry, store: store, isNew: true) }
    }
  }

  private var planHeading: some View {
    Text("Your training week").font(.title.bold())
  }
  private var newSessionButton: some View {
    Button { createSession() } label: { Label("New session", systemImage: "plus") }
      .buttonStyle(.borderedProminent).accessibilityIdentifier("new-training-session")
  }

  private var overviewCard: some View {
    VStack(alignment: .leading, spacing: 16) {
      HStack {
        Button { moveWeek(-1) } label: { Image(systemName: "chevron.left") }.accessibilityLabel("Previous week")
        Spacer()
        VStack(spacing: 3) {
          Text(week.start.formatted(.dateTime.day().month()) + " – " +
            (days.last ?? week.start).formatted(.dateTime.day().month())).font(.headline)
          Text("\(weekEntries.count) sessions · \(weekEntries.reduce(0) { $0 + $1.durationMinutes }) min")
            .font(.subheadline).foregroundStyle(.secondary)
        }
        Spacer()
        Button { moveWeek(1) } label: { Image(systemName: "chevron.right") }.accessibilityLabel("Next week")
      }
      if weekOffset != 0 { Button("This week") { weekOffset = 0; selectedDay = nil }.font(.caption) }
      Chart {
        ForEach(weekEntries) { entry in
          BarMark(x: .value("Day", Calendar.current.startOfDay(for: entry.startDate), unit: .day),
                  y: .value("Minutes", entry.durationMinutes))
            .foregroundStyle(stateColor(entry.state))
            .accessibilityLabel(entry.activity.title + ", " + entry.state.title)
            .accessibilityValue("\(entry.durationMinutes) minutes")
        }
      }
      .chartXScale(domain: week.start...week.end)
      .chartXAxis { AxisMarks(values: .stride(by: .day)) { AxisValueLabel(format: .dateTime.weekday(.narrow)) } }
      .chartYAxis { AxisMarks(position: .leading) }
      .chartYAxisLabel("min")
      .frame(height: 155)
      ScrollView(.horizontal, showsIndicators: false) {
        HStack(spacing: 8) {
          ForEach(days, id: \.self) { day in dayButton(day) }
        }
      }
      HStack(spacing: 14) {
        ForEach(PlanEntryState.allCases, id: \.self) { state in
          HStack(spacing: 4) {
            Image(systemName: stateSymbol(state)).foregroundStyle(stateColor(state))
            Text("\(weekEntries.filter { $0.state == state }.count) " + state.title).foregroundStyle(.secondary)
          }
        }
      }.font(.caption2)
    }.roburCard().accessibilityIdentifier("training-week-overview")
  }

  private func dayButton(_ day: Date) -> some View {
    let entries = weekEntries.filter { Calendar.current.isDate($0.startDate, inSameDayAs: day) }
    let selected = selectedDay.map { Calendar.current.isDate($0, inSameDayAs: day) } ?? false
    return Button {
      selectedDay = selected ? nil : day
    } label: {
      VStack(alignment: .leading, spacing: 6) {
        HStack {
          Text(day.formatted(.dateTime.weekday(.abbreviated))).font(.caption.bold())
          Text(day.formatted(.dateTime.day())).font(.caption.monospacedDigit())
        }
        if entries.isEmpty {
          Text("No plan").font(.caption).foregroundStyle(.secondary)
          Text("—").font(.caption)
        } else {
          ForEach(Array(entries.prefix(2))) { entry in
            HStack(spacing: 3) {
              Image(systemName: stateSymbol(entry.state)).foregroundStyle(color(entry.activity.category))
              Text(entry.startDate.formatted(.dateTime.hour().minute()))
            }.font(.caption2)
          }
          if entries.count > 2 { Text("+\(entries.count - 2) more").font(.caption2) }
        }
      }
      .frame(minWidth: 80, minHeight: 62, alignment: .topLeading).padding(10)
      .background(selected ? RoburStyle.orange.opacity(0.16) : RoburStyle.background,
                  in: RoundedRectangle(cornerRadius: 12))
      .overlay { RoundedRectangle(cornerRadius: 12).stroke(selected ? RoburStyle.orange : .clear, lineWidth: 1.5) }
    }.buttonStyle(.plain)
    .accessibilityLabel(day.formatted(date: .complete, time: .omitted) + ", \(entries.count) planned sessions")
  }

  private var trainingMixCard: some View {
    VStack(alignment: .leading, spacing: 14) {
      Label("Weekly training mix", systemImage: "chart.bar.fill").font(.headline)
      ForEach(TrainingCategory.allCases.filter { category in categories.contains(category) || weekEntries.contains { $0.activity.category == category } }) { category in
        let matching = weekEntries.filter { $0.activity.category == category }
        HStack {
          Label(shortTitle(category), systemImage: category.symbol).foregroundStyle(color(category))
          Spacer()
          Text(matching.isEmpty ? "Not planned" : "\(matching.reduce(0) { $0 + $1.durationMinutes }) min · \(matching.count)")
            .font(.caption).foregroundStyle(.secondary)
          Image(systemName: matching.isEmpty ? "circle.dashed" : "checkmark.circle.fill")
            .foregroundStyle(matching.isEmpty ? Color.secondary : color(category))
        }.font(.subheadline)
      }
      Text("Coverage reflects your plan, including suggestions. Completed plans do not create Health workouts.")
        .font(.caption).foregroundStyle(.secondary)
    }.roburCard()
  }

  private var muscleCoverageCard: some View {
    VStack(alignment: .leading, spacing: 14) {
      Label("Planned muscle focus", systemImage: "figure.strengthtraining.traditional").font(.headline)
      LazyVGrid(columns: [GridItem(.adaptive(minimum: 84))], alignment: .leading, spacing: 8) {
        ForEach(MuscleGroup.allCases) { muscle in
          let count = weekEntries.filter { $0.activity.category == .strength && $0.muscles.contains(muscle) }.count
          HStack(spacing: 4) {
            Image(systemName: count > 0 ? "checkmark.circle.fill" : "circle.dashed")
            Text(muscle.rawValue)
          }
          .font(.caption.weight(count > 0 ? .semibold : .regular))
          .foregroundStyle(count > 0 ? RoburStyle.orange : .secondary)
          .padding(.vertical, 8).frame(maxWidth: .infinity)
          .background(count > 0 ? RoburStyle.orange.opacity(0.12) : RoburStyle.background,
            in: Capsule())
          .accessibilityLabel("\(muscle.rawValue), \(count) planned strength sessions")
        }
      }
      Text("\(coveredMuscles.count) muscle groups included this week · choose the coverage that fits your goals")
        .font(.caption).foregroundStyle(.secondary)
      let missingFocus = weekEntries.filter { $0.activity.category == .strength && $0.muscles.isEmpty }
      if !missingFocus.isEmpty {
        Button("Add muscle focus to \(missingFocus.count) strength session\(missingFocus.count == 1 ? "" : "s")") {
          store.focusedEntryID = missingFocus.first?.id
        }.font(.caption)
      }
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
        Text("Calendar gaps").tag("gaps")
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
      Text(schedulingMode == "gaps" ? "Morning, lunch and evening gaps, 07:00–21:00. " + (store.calendarAccess ? "Checks all readable calendars." : "Connect Calendar to check existing events.") : store.calendarAccess ? "Finds morning, lunch and evening gaps across your readable calendars within this window." :
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
          .disabled(store.isWorking || store.selectedCalendarID == nil ||
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

  private func entryCard(_ entry: PlanEntry) -> some View {
    VStack(alignment: .leading, spacing: 12) {
      HStack(alignment: .top) {
        Label(entry.activity.title, systemImage: entry.activity.symbol).font(.headline)
        Spacer()
        Image(systemName: stateSymbol(entry.state)).foregroundStyle(color(entry.activity.category))
          .accessibilityLabel(entry.state.title)
      }
      Text(entry.startDate.formatted(date: .abbreviated, time: .shortened)).font(.subheadline)
      HStack {
        Text("\(entry.durationMinutes) min")
        Text("· " + entry.state.title)
      }.font(.caption).foregroundStyle(.secondary)
      if entry.activity.category == .strength {
        Label(entry.muscles.isEmpty ? "Choose muscle focus" : entry.muscleSummary,
          systemImage: "figure.strengthtraining.traditional")
          .font(.subheadline.weight(.medium)).foregroundStyle(RoburStyle.orange)
      }
      if entry.calendarSyncPending == true || entry.reminderSyncPending == true {
        Label("Sync pending", systemImage: "arrow.clockwise").font(.caption).foregroundStyle(.secondary)
      } else if entry.calendarEventID != nil {
        Label("Calendar linked", systemImage: "link").font(.caption).foregroundStyle(.secondary)
      }
      if (!entry.calendarWasExported || entry.calendarEventID == nil) && entry.state != .completed && entry.endDate > Date() {
        Button(entry.calendarWasExported ? "Add again to Calendar" : "Add to Calendar", systemImage: "calendar.badge.plus") {
          Task {
            if !store.calendarAccess { await store.requestCalendarAccess() }
            if store.calendarAccess { await store.exportPlaceholders(ids: [entry.id], allowReExport: entry.calendarWasExported) }
          }
        }
        .buttonStyle(.bordered).disabled(store.isWorking)
        .accessibilityIdentifier("add-session-to-calendar-\(entry.id.uuidString)")
      }
      ViewThatFits(in: .horizontal) {
        HStack { entryActions(entry) }
        VStack(alignment: .leading) { entryActions(entry) }
      }
    }.roburCard()
  }

  @ViewBuilder private func entryActions(_ entry: PlanEntry) -> some View {
    Button("Edit") { store.focusedEntryID = entry.id }.buttonStyle(.bordered)
    Menu("More", systemImage: "ellipsis") {
      Button("Move one day later", systemImage: "calendar.badge.clock") { _ = store.reschedule(id: entry.id, days: 1) }
      Button("Move one week later", systemImage: "calendar.badge.clock") { _ = store.reschedule(id: entry.id, days: 7) }
      Button("Duplicate session", systemImage: "plus.square.on.square") {
        let date = Calendar.current.date(byAdding: .day, value: 7, to: entry.startDate) ?? entry.startDate
        if let id = store.duplicate(id: entry.id, startDate: date) { store.focusedEntryID = id }
      }
      if entry.state == .confirmed { Button("Mark completed", systemImage: "checkmark.circle") { Task { await store.complete(id: entry.id) } } }
    }
    if entry.state == .suggested {
      Button("Confirm") {
        if entry.activity.category == .strength && entry.muscles.isEmpty { store.focusedEntryID = entry.id }
        else { Task { await store.confirm(id: entry.id) } }
      }.buttonStyle(.borderedProminent)
    } else if entry.state == .confirmed {
      Button("Start", systemImage: "play.fill") {
        PhoneWorkoutRecorder.shared.queueStart(activity: entry.activity)
        if !PhoneWorkoutRecorder.shared.isActive { PhoneWorkoutRecorder.shared.muscleGroups = entry.muscles }
      }.buttonStyle(.borderedProminent)
    }
  }

  private func generatePlan() {
    Task {
      if !store.calendarAccess { await store.requestCalendarAccess() }
      await store.generateWeek(workouts: healthKit.analyticsWorkouts, categories: categories, annotations: journal.annotations,
        preferredActivities: Set(activityNames.split(separator: ",").compactMap { WorkoutActivity(rawValue: String($0)) }),
        startHour: schedulingMode == "gaps" ? 7 : startHour, endHour: schedulingMode == "gaps" ? 21 : endHour)
      weekOffset = 0; selectedDay = nil
    }
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
  @State private var hasCreatedEntry = false
  @State private var validationMessage: String?

  private var savedEntry: PlanEntry { store.entries.first { $0.id == entry.id } ?? entry }
  private var isUnsaved: Bool { isNew && !hasCreatedEntry }

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
        }.disabled(store.isWorking)
        if !isUnsaved {
          Section {
            Button("Remove from local plan", role: .destructive) {
              store.removeLocalEntry(id: entry.id)
              if !store.entries.contains(where: { $0.id == entry.id }) { dismiss() }
            }
            Text("Existing Calendar events and reminders stay in their apps. Removed Calendar placeholders are never recreated automatically.")
              .font(.caption).foregroundStyle(.secondary)
          }
        }
      }
      .navigationTitle(isUnsaved ? "New session" : "Edit session").navigationBarTitleDisplayMode(.inline)
      .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Close") { dismiss() } } }
      .confirmationDialog("Remove this session from Calendar?", isPresented: $showingCalendarRemoval, titleVisibility: .visible) {
        Button("Remove from Calendar", role: .destructive) {
          Task { await store.removeCalendarPlaceholder(id: entry.id) }
        }
      } message: {
        Text("Only this session's Robur placeholder will be deleted. Your local plan and reminders stay. Add again to Calendar is always an explicit action.")
      }
    }.tint(RoburStyle.orange)
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
      Task {
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
