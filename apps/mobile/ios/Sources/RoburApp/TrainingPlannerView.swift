import SwiftUI

@MainActor
struct TrainingPlannerView: View {
  @StateObject private var store = TrainingPlannerStore.shared
  @EnvironmentObject private var healthKit: HealthKitClient
  @Environment(\.scenePhase) private var scenePhase
  @AppStorage("RoburTrainingBalanceCategories") private var categoryNames = "endurance,strength,mobility"
  @AppStorage("RoburTrainingBalanceActivities") private var activityNames = ""
  @AppStorage("RoburPlanStartHour") private var startHour = 17
  @AppStorage("RoburPlanEndHour") private var endHour = 20

  private var categories: Set<TrainingCategory> {
    Set(categoryNames.split(separator: ",").compactMap { TrainingCategory(rawValue: String($0)) })
  }
  private var visible: [PlanEntry] {
    let cutoff = Calendar.current.date(byAdding: .day, value: -7, to: Date()) ?? Date()
    return store.entries.filter { $0.endDate >= cutoff }.sorted { $0.startDate < $1.startDate }
  }

  var body: some View {
    NavigationStack {
      ScrollView {
        VStack(alignment: .leading, spacing: 20) {
          VStack(alignment: .leading, spacing: 8) {
            Text("MAKE ROOM FOR TRAINING").font(.caption.bold()).foregroundStyle(RoburStyle.orange)
            Text("Your week, with a plan").font(.largeTitle.bold())
            Text("A few editable suggestions from your recent training mix. Choose what fits your time and how you feel.")
              .foregroundStyle(.secondary)
          }
          AdaptiveCardLayout {
            summaryCard
            preferencesCard
            calendarCard
          }
          if let error = store.lastError { Text(error).font(.callout).foregroundStyle(.red) }
          Text(store.status).font(.callout).foregroundStyle(.secondary).accessibilityIdentifier("plan-status")
          if store.isWorking { ProgressView("Updating plan…") }
          if visible.isEmpty {
            ContentUnavailableView("Start with a few suggestions", systemImage: "calendar.badge.plus",
              description: Text("Choose your training categories and time window, then generate the next seven days."))
          }
          AdaptiveCardLayout {
            ForEach(visible) { entry in entryCard(entry) }
          }
          Text("Suggestions use recorded workout labels, leave space between strength days, and favor selected categories with less recent training. They are planning ideas, not medical advice or a measure of recovery. Fewer slots may fit a busy calendar.")
            .font(.caption).foregroundStyle(.secondary)
        }
        .frame(maxWidth: RoburStyle.contentWidth)
        .padding().frame(maxWidth: .infinity)
      }
      .background(RoburStyle.background)
      .navigationTitle("Plan").navigationBarTitleDisplayMode(.inline)
      .task { await store.reconcile() }
      .onChange(of: scenePhase) { _, phase in if phase == .active { Task { await store.reconcile() } } }
      .sheet(item: Binding(get: { store.entries.first { $0.id == store.focusedEntryID } },
                           set: { if $0 == nil { store.focusedEntryID = nil } })) { entry in
        TrainingPlanEditor(entry: entry, store: store)
      }
    }
  }

  private var summaryCard: some View {
    let summary = TrainingPlanner.summary(entries: store.entries)
    return VStack(alignment: .leading, spacing: 14) {
      Label("This calendar week", systemImage: "calendar").font(.headline)
      Text("\(summary.minutes) planned min").font(.title2.bold()).monospacedDigit()
      Text("\(summary.suggested) suggested · \(summary.confirmed) confirmed · \(summary.completed) completed")
        .font(.subheadline).foregroundStyle(.secondary)
      Text("Completed plans are marked by you; Calendar time passing does not count as a workout.")
        .font(.caption).foregroundStyle(.secondary)
    }.roburCard()
  }

  private var preferencesCard: some View {
    VStack(alignment: .leading, spacing: 14) {
      Label("Make space", systemImage: "clock").font(.headline)
      ForEach(TrainingCategory.allCases) { category in
        Toggle(category.title, isOn: Binding(get: { categories.contains(category) }, set: { enabled in
          var chosen = categories
          if enabled { chosen.insert(category) } else { chosen.remove(category) }
          categoryNames = chosen.map(\.rawValue).sorted().joined(separator: ",")
        }))
      }
      HStack {
        Picker("From", selection: $startHour) {
          ForEach(0..<24, id: \.self) { Text(hourLabel($0)).tag($0) }
        }
        Picker("Until", selection: $endHour) {
          ForEach(1...24, id: \.self) { Text(hourLabel($0)).tag($0) }
        }
      }
      .onChange(of: startHour) { _, hour in if endHour <= hour { endHour = hour + 1 } }
      .onChange(of: endHour) { _, hour in if startHour >= hour { startHour = hour - 1 } }
      Text("Times use your current time zone. Generating replaces local drafts and keeps exported or confirmed plans.")
        .font(.caption).foregroundStyle(.secondary)
      Button("Generate next 7 days", systemImage: "sparkles") {
        Task {
          await store.reconcile()
          store.generateWeek(workouts: healthKit.analyticsWorkouts, categories: categories,
            preferredActivities: Set(activityNames.split(separator: ",").compactMap { WorkoutActivity(rawValue: String($0)) }),
            startHour: startHour, endHour: endHour)
        }
      }
      .buttonStyle(.borderedProminent).disabled(store.isWorking || categories.isEmpty)
      .accessibilityIdentifier("generate-training-plan")
    }.roburCard()
  }

  private var calendarCard: some View {
    VStack(alignment: .leading, spacing: 14) {
      Label("Calendar & optional reminders", systemImage: "calendar.badge.clock").font(.headline)
      if store.calendarAccess {
        Picker("Calendar", selection: Binding(get: { store.selectedCalendarID ?? "" }, set: { store.chooseCalendar($0) })) {
          Text("Choose a calendar").tag("")
          ForEach(store.calendars, id: \.calendarIdentifier) { Text($0.title).tag($0.calendarIdentifier) }
        }
        Text("Add sessions individually below, or add all reviewed suggestions with this button. Existing events are kept.")
          .font(.caption).foregroundStyle(.secondary)
        Button("Add tentative placeholders", systemImage: "calendar.badge.plus") { Task { await store.exportPlaceholders() } }
          .buttonStyle(.borderedProminent)
          .disabled(store.isWorking || store.selectedCalendarID == nil ||
            !store.entries.contains { !$0.calendarWasExported && $0.state != .completed && $0.endDate > Date() })
          .accessibilityIdentifier("export-training-placeholders")
        Text("Confirm in Robur, or remove [Suggested] from a Calendar title. On calendars supporting tentative availability, changing it to Busy also confirms. Calendar edits sync when you return.")
          .font(.caption).foregroundStyle(.secondary)
      } else {
        Text("Full Calendar access checks for conflicts and lets you add reviewed placeholders. Your local plan works without it.")
          .font(.subheadline).foregroundStyle(.secondary)
        Button("Connect Calendar", systemImage: "calendar") { Task { await store.requestCalendarAccess() } }
          .buttonStyle(.bordered).disabled(store.isWorking)
      }
      Divider()
      Toggle("Reminders for confirmed plans", isOn: Binding(get: { store.remindersEnabled }, set: { enabled in
        Task { await store.setRemindersEnabled(enabled) }
      })).disabled(store.isWorking)
      if store.remindersEnabled {
        if store.reminderAccess {
          Picker("Reminders list", selection: Binding(get: { store.selectedReminderListID ?? "" }, set: { store.chooseReminderList($0) })) {
            Text("Choose a list").tag("")
            ForEach(store.reminderLists, id: \.calendarIdentifier) { Text($0.title).tag($0.calendarIdentifier) }
          }
          Toggle("Sync completion with Reminders", isOn: Binding(get: { store.syncReminderCompletion }, set: { store.setReminderCompletion($0) }))
        } else { Text("Reminders access is off. Enable it in Settings to sync.").font(.caption) }
      }
      Text("Reminders asks for separate access. It creates one item per confirmed plan, follows time changes, and keeps deleted items deleted. Turning this off keeps existing reminders.")
        .font(.caption).foregroundStyle(.secondary)
      Link("Open app settings", destination: URL(string: UIApplication.openSettingsURLString)!).font(.caption)
    }.roburCard()
  }

  private func entryCard(_ entry: PlanEntry) -> some View {
    VStack(alignment: .leading, spacing: 12) {
      HStack(alignment: .top) {
        Label(entry.activity.title, systemImage: entry.activity.symbol).font(.headline)
        Spacer()
        Text(entry.state.title).font(.caption.weight(.semibold)).foregroundStyle(RoburStyle.orange)
      }
      Text(entry.startDate.formatted(date: .abbreviated, time: .shortened)).font(.subheadline)
      Text("\(entry.durationMinutes) min\(entry.muscles.isEmpty ? "" : " · " + entry.muscles.map(\.rawValue).sorted().joined(separator: ", "))")
        .font(.caption).foregroundStyle(.secondary)
      if entry.calendarWasExported {
        Label(entry.calendarEventID == nil ? "Calendar unlinked" : "Linked to Calendar",
          systemImage: entry.calendarEventID == nil ? "link.badge.plus" : "link").font(.caption).foregroundStyle(.secondary)
      } else {
        Label("Only in your local plan", systemImage: "iphone").font(.caption).foregroundStyle(.secondary)
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
    Button("Review / edit") { store.focusedEntryID = entry.id }.buttonStyle(.bordered)
    if entry.state == .suggested {
      Button("Confirm") { Task { await store.confirm(id: entry.id) } }.buttonStyle(.borderedProminent).disabled(store.isWorking)
    } else if entry.state == .confirmed {
      Button("Start in Robur", systemImage: "play.fill") {
        PhoneWorkoutRecorder.shared.queueStart(activity: entry.activity)
        if !PhoneWorkoutRecorder.shared.isActive { PhoneWorkoutRecorder.shared.muscleGroups = entry.muscles }
      }.buttonStyle(.borderedProminent)
    }
  }

  private func hourLabel(_ hour: Int) -> String {
    hour == 24 ? "24:00" : String(format: "%02d:00", hour)
  }
}

@MainActor
private struct TrainingPlanEditor: View {
  @State var entry: PlanEntry
  @ObservedObject var store: TrainingPlannerStore
  @Environment(\.dismiss) private var dismiss
  @State private var showingCalendarRemoval = false

  private var savedEntry: PlanEntry { store.entries.first { $0.id == entry.id } ?? entry }

  var body: some View {
    NavigationStack {
      Form {
        Section(entry.activity.title) {
          Text(entry.state.title).foregroundStyle(.secondary)
          Picker("Activity", selection: $entry.activity) {
            ForEach(WorkoutActivity.allCases) { Text($0.title).tag($0) }
          }
          DatePicker("Start", selection: $entry.startDate, displayedComponents: [.date, .hourAndMinute])
          Stepper("Duration: \(entry.durationMinutes) min", value: $entry.durationMinutes, in: 1...1_440, step: 5)
          if entry.activity.category == .strength {
            ForEach(MuscleGroup.allCases) { muscle in
              Toggle(muscle.rawValue, isOn: Binding(get: { entry.muscles.contains(muscle) }, set: { selected in
                if selected { entry.muscles.insert(muscle) } else { entry.muscles.remove(muscle) }
              }))
            }
          }
        }
        if let error = store.lastError { Section { Text(error).foregroundStyle(.red) } }
        Section {
          Button("Save changes") { save(state: nil) }
          if entry.state == .suggested { Button("Confirm plan") { save(state: .confirmed) } }
          if entry.state == .confirmed { Button("Mark completed") { save(state: .completed) } }
        }.disabled(store.isWorking)
        Section("Calendar") {
          if savedEntry.calendarWasExported {
            if savedEntry.calendarEventID != nil {
              Label("Linked to Calendar", systemImage: "link")
              Text("Saving changes updates this session's Calendar event.")
                .font(.caption).foregroundStyle(.secondary)
              Button("Remove from Calendar", role: .destructive) { showingCalendarRemoval = true }
            } else {
              Label("Calendar unlinked", systemImage: "link.badge.plus")
              Text("This session stays in your local plan. Add it again below if you want a new Calendar placeholder.")
                .font(.caption).foregroundStyle(.secondary)
              if entry.state != .completed && entry.endDate > Date() { calendarAddControls(allowReExport: true) }
            }
          } else if entry.state != .completed && entry.endDate > Date() {
            calendarAddControls(allowReExport: false)
          } else {
            Text("Only in your local plan").foregroundStyle(.secondary)
          }
        }.disabled(store.isWorking)
        Section {
          Button("Remove from local plan", role: .destructive) {
            store.removeLocalEntry(id: entry.id)
            if !store.entries.contains(where: { $0.id == entry.id }) { dismiss() }
          }
          Text("Any existing Calendar event or reminder stays in its app. Deleted Calendar links are never recreated automatically.")
            .font(.caption).foregroundStyle(.secondary)
        }.disabled(store.isWorking)
      }
      .navigationTitle("Review plan").navigationBarTitleDisplayMode(.inline)
      .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Close") { dismiss() } } }
      .confirmationDialog("Remove this session from Calendar?", isPresented: $showingCalendarRemoval, titleVisibility: .visible) {
        Button("Remove from Calendar", role: .destructive) {
          Task { await store.removeCalendarPlaceholder(id: entry.id) }
        }
      } message: {
        Text("Only this session's Robur placeholder will be deleted. Your local plan and reminders stay. A new placeholder is added only if you choose Add again to Calendar.")
      }
    }.tint(RoburStyle.orange)
  }

  private func save(state: PlanEntryState?) {
    Task {
      if await store.update(id: entry.id, startDate: entry.startDate, durationMinutes: entry.durationMinutes,
                            activity: entry.activity, muscles: entry.muscles, state: state) { dismiss() }
    }
  }

  @ViewBuilder private func calendarAddControls(allowReExport: Bool) -> some View {
    if store.calendarAccess {
      Picker("Calendar", selection: Binding(get: { store.selectedCalendarID ?? "" }, set: { store.chooseCalendar($0) })) {
        Text("Choose a calendar").tag("")
        ForEach(store.calendars, id: \.calendarIdentifier) { Text($0.title).tag($0.calendarIdentifier) }
      }
    }
    Button(allowReExport ? "Add again to Calendar" : "Save & add to Calendar", systemImage: "calendar.badge.plus") {
      saveAndAddToCalendar(allowReExport: allowReExport)
    }
    Text("Saves the activity, date and duration above, then adds only this session. Calendar access is requested if needed.")
      .font(.caption).foregroundStyle(.secondary)
  }

  private func saveAndAddToCalendar(allowReExport: Bool) {
    Task {
      guard await store.update(id: entry.id, startDate: entry.startDate, durationMinutes: entry.durationMinutes,
                               activity: entry.activity, muscles: entry.muscles) else { return }
      if !store.calendarAccess { await store.requestCalendarAccess() }
      guard store.calendarAccess else { return }
      await store.exportPlaceholders(ids: [entry.id], allowReExport: allowReExport)
      if store.entries.first(where: { $0.id == entry.id })?.calendarEventID != nil { dismiss() }
    }
  }
}
