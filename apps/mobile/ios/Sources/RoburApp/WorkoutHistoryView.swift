import SwiftUI

struct WorkoutHistoryView: View {
  @EnvironmentObject private var healthKit: HealthKitClient
  @EnvironmentObject private var journal: WorkoutJournal
  @State private var search = ""
  @State private var muscle: MuscleGroup?
  @State private var gymID: UUID?
  @State private var selected: WorkoutRecord?

  private var filtered: [WorkoutRecord] {
    healthKit.workouts.filter { workout in
      let annotation = journal.annotations[workout.id] ?? WorkoutAnnotation()
      let text = [workout.title, annotation.notes, journal.gymName(annotation.gymID) ?? "",
                  annotation.muscles.map(\.rawValue).joined(separator: " ")].joined(separator: " ")
      return (search.isEmpty || text.localizedCaseInsensitiveContains(search)) &&
        (muscle == nil || annotation.muscles.contains(muscle!)) &&
        (gymID == nil || annotation.gymID == gymID)
    }
  }

  var body: some View {
    NavigationStack {
      ScrollView {
        LazyVStack(alignment: .leading, spacing: 16) {
          VStack(alignment: .leading, spacing: 6) {
            Text("MAKE EVERY SESSION COUNT").font(.caption.weight(.bold)).foregroundStyle(RoburStyle.teal)
            Text("Your training journal").font(.largeTitle.bold())
            Text("Add what you trained, how it felt, and where you showed up.").foregroundStyle(.secondary)
          }
          HistoryRangePicker()
          HStack {
            Menu {
              Button("All muscles") { muscle = nil }
              ForEach(MuscleGroup.allCases) { group in Button(group.rawValue) { muscle = group } }
            } label: { Label(muscle?.rawValue ?? "All muscles", systemImage: "line.3.horizontal.decrease.circle") }
            Spacer()
            Menu {
              Button("All places") { gymID = nil }
              ForEach(journal.gyms) { gym in Button(gym.name) { gymID = gym.id } }
            } label: { Label(journal.gymName(gymID) ?? "All places", systemImage: "mappin") }
          }.font(.subheadline)
          Text("\(filtered.count) workouts · \(Int(filtered.reduce(0) { $0 + $1.minutes })) min")
            .font(.headline).monospacedDigit()
          if filtered.isEmpty && !healthKit.isLoadingHistory {
            ContentUnavailableView("No workouts to show", systemImage: "figure.run",
              description: Text("Choose a wider history, clear filters, or share workouts in Apple Health. Workouts recorded with Apple Watch and other Health apps appear here after a refresh."))
          }
          ForEach(filtered) { workout in
            Button { selected = workout } label: {
              WorkoutRow(workout: workout, annotation: journal.annotations[workout.id] ?? WorkoutAnnotation(),
                         gymName: journal.gymName(journal.annotations[workout.id]?.gymID))
            }.buttonStyle(.plain)
          }
          HistoryPermissionView()
        }.padding()
      }
      .background(RoburStyle.background)
      .navigationTitle("Workouts").navigationBarTitleDisplayMode(.inline)
      .searchable(text: $search, prompt: "Workout, muscle, place or notes")
      .refreshable { await healthKit.loadHistory(range: healthKit.historyRange) }
      .sheet(item: $selected) { WorkoutDetailView(workout: $0) }
    }
  }
}

struct WorkoutRow: View {
  let workout: WorkoutRecord
  let annotation: WorkoutAnnotation
  let gymName: String?
  var body: some View {
    VStack(alignment: .leading, spacing: 14) {
      HStack(alignment: .top, spacing: 14) {
        Image(systemName: workout.symbol).font(.title2).foregroundStyle(RoburStyle.teal)
          .frame(width: 48, height: 48).background(RoburStyle.teal.opacity(0.10), in: RoundedRectangle(cornerRadius: 16))
        VStack(alignment: .leading, spacing: 4) {
          Text(workout.title).font(.headline)
          Text(workout.start.formatted(date: .abbreviated, time: .shortened)).font(.caption).foregroundStyle(.secondary)
        }
        Spacer(minLength: 0)
        Image(systemName: "chevron.right").font(.caption).foregroundStyle(.secondary)
      }
      ViewThatFits(in: .horizontal) {
        HStack(spacing: 16) { metrics }
        VStack(alignment: .leading, spacing: 6) { metrics }
      }
      if !annotation.muscles.isEmpty {
        Text(annotation.muscles.map(\.rawValue).sorted().joined(separator: " · "))
          .font(.caption.weight(.medium)).foregroundStyle(RoburStyle.teal)
      }
      if let gymName { Label(gymName, systemImage: "mappin.and.ellipse").font(.caption).foregroundStyle(.secondary) }
    }.roburCard()
    .accessibilityElement(children: .combine)
  }
  @ViewBuilder private var metrics: some View {
    Label("\(Int(workout.minutes)) min", systemImage: "clock")
    if let hr = workout.averageHeartRate { Label("\(Int(hr)) bpm", systemImage: "heart") }
    Text(annotation.effort.map { "Effort \($0)/10" } ?? "Rate effort")
      .foregroundStyle(RoburStyle.amber)
  }
}

struct WorkoutDetailView: View {
  let workout: WorkoutRecord
  @EnvironmentObject private var journal: WorkoutJournal
  @Environment(\.dismiss) private var dismiss
  @State private var draft = WorkoutAnnotation()
  @State private var loaded = false

  var body: some View {
    NavigationStack {
      Form {
        if let error = journal.storageError { Text(error).foregroundStyle(.red) }
        Section {
          Label(workout.title, systemImage: workout.symbol).font(.title2.bold())
          Text(workout.start.formatted(date: .complete, time: .shortened))
          LabeledContent("Duration", value: "\(Int(workout.minutes)) min")
          if let distance = workout.distanceKm, distance > 0 {
            LabeledContent("Distance", value: String(format: "%.2f km", distance))
          }
          if let energy = workout.energyKcal { LabeledContent("Active energy", value: "\(Int(energy)) kcal") }
          if let heart = workout.averageHeartRate { LabeledContent("Average heart rate", value: "\(Int(heart)) bpm") }
          LabeledContent("Recorded by", value: workout.source)
        }
        Section {
          Picker("Perceived effort", selection: $draft.effort) {
            Text("Not rated").tag(Int?.none)
            ForEach(1...10, id: \.self) { value in Text("\(value) / 10").tag(Optional(value)) }
          }
          Text("1–2 easy · 3–4 moderate · 5–6 hard · 7–8 very hard · 9–10 maximal")
            .font(.caption).foregroundStyle(.secondary)
          if let effort = draft.effort {
            LabeledContent("Session load", value: "\(Int(workout.minutes * Double(effort))) AU")
          }
        } header: { Text("How did it feel?") }
        footer: { Text("Your own effort rating. Session load = minutes × effort, in arbitrary units (AU). It is a training estimate, not a medical measurement.") }
        Section("Muscles trained") {
          ForEach(MuscleGroup.allCases) { group in
            Toggle(group.rawValue, isOn: Binding(get: { draft.muscles.contains(group) }, set: { value in
              if value { draft.muscles.insert(group) } else { draft.muscles.remove(group) }
            }))
          }
        }
        Section("Place & notes") {
          Picker("Fitness centre", selection: $draft.gymID) {
            Text("No place").tag(UUID?.none)
            ForEach(journal.gyms) { gym in Text(gym.name).tag(Optional(gym.id)) }
          }
          TextField("Exercises, sets, progress, how you felt…", text: $draft.notes, axis: .vertical)
            .lineLimit(3...8)
        }
        Section {
          Text("These details are saved in Robur on this device. The original Apple Health workout is unchanged. Add fitness centres in Places.")
            .font(.footnote).foregroundStyle(.secondary)
        }
      }
      .navigationTitle("Workout details").navigationBarTitleDisplayMode(.inline)
      .toolbar {
        ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
        ToolbarItem(placement: .confirmationAction) {
          Button("Save") { if journal.save(draft, for: workout) { dismiss() } }.bold()
        }
      }
      .onAppear {
        guard !loaded else { return }
        draft = journal.annotations[workout.id] ?? WorkoutAnnotation(gymID: journal.suggestedGym(for: workout))
        loaded = true
      }
    }
  }
}
