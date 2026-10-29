import SwiftUI
import Charts

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
      .onChange(of: journal.gyms) { _, gyms in
        if let gymID, !gyms.contains(where: { $0.id == gymID }) { self.gymID = nil }
      }
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
    Text(workout.appleEffort.map { String(format: "Apple effort %.1f/10", $0) }
      ?? annotation.effort.map { "Personal effort \($0)/10" } ?? "Effort unavailable")
      .foregroundStyle(RoburStyle.amber)
  }
}

struct WorkoutDetailView: View {
  let workout: WorkoutRecord
  @EnvironmentObject private var healthKit: HealthKitClient
  @EnvironmentObject private var journal: WorkoutJournal
  @Environment(\.dismiss) private var dismiss
  @AppStorage("RoburMaxHeartRate") private var maxHR = 190.0
  @State private var draft = WorkoutAnnotation()
  @State private var loaded = false
  @State private var loadingDetails = false

  private var current: WorkoutRecord { healthKit.workouts.first { $0.id == workout.id } ?? workout }
  private var zones: [HeartZoneTotal] {
    TrainingInsights.heartZones(samples: current.heartRateSamples, end: current.end, maxHR: maxHR)
  }
  private var pace: Double? {
    guard let km = current.distanceKm, km > 0 else { return nil }
    return current.minutes / km
  }
  private var comparablePace: Double? {
    let similar = healthKit.workouts.filter { item in
      guard item.id != current.id, item.title == current.title, item.start < current.start,
            item.start >= current.start.addingTimeInterval(-90 * 86_400),
            let km = item.distanceKm, km > 0,
            let currentKm = current.distanceKm, currentKm > 0 else { return false }
      return abs(km - currentKm) / currentKm <= 0.25
    }.prefix(10)
    guard !similar.isEmpty else { return nil }
    return similar.reduce(0) { $0 + $1.minutes / ($1.distanceKm ?? 1) } / Double(similar.count)
  }

  var body: some View {
    NavigationStack {
      Form {
        if let error = journal.storageError { Text(error).foregroundStyle(.red) }
        overviewSection
        effortSection
        analysisSection
        if !current.heartRateSamples.isEmpty { heartRateSection }
        if !current.splits.isEmpty { splitSection }
        muscleSection
        placeSection
        Section {
          Text("Notes and muscle tags are saved in Robur on this device. Apple Fitness effort is imported from Health; Robur does not replace or write your original workout records.")
            .font(.footnote).foregroundStyle(.secondary)
        }
      }
      .navigationTitle("Workout analysis").navigationBarTitleDisplayMode(.inline)
      .toolbar {
        ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
        ToolbarItem(placement: .confirmationAction) {
          Button("Save") { if journal.save(draft, for: current) { dismiss() } }.bold()
        }
      }
      .onAppear {
        guard !loaded else { return }
        draft = journal.annotations[workout.id] ?? WorkoutAnnotation(gymID: journal.suggestedGym(for: workout))
        loaded = true
      }
      .task(id: workout.id) {
        loadingDetails = true
        await healthKit.loadWorkoutDetails(id: workout.id)
        loadingDetails = false
      }
    }
  }

  private var overviewSection: some View {
    Section {
      Label(current.title, systemImage: current.symbol).font(.title2.bold())
      Text(current.start.formatted(date: .complete, time: .shortened))
      LabeledContent("Duration", value: "\(Int(current.minutes)) min")
      if let distance = current.distanceKm, distance > 0 {
        LabeledContent("Distance", value: String(format: "%.2f km", distance))
      }
      if let energy = current.energyKcal { LabeledContent("Active energy", value: "\(Int(energy)) kcal") }
      if let heart = current.averageHeartRate { LabeledContent("Average heart rate", value: "\(Int(heart)) bpm") }
      LabeledContent("Recorded by", value: current.source)
      if loadingDetails { ProgressView("Reading workout details…") }
    }
  }

  private var effortSection: some View {
    Section {
      if let effort = current.appleEffort {
        HStack {
          Label("Apple Fitness effort", systemImage: "applewatch")
          Spacer()
          Text(String(format: "%.1f / 10", effort)).font(.title2.bold()).foregroundStyle(RoburStyle.amber)
        }
        ProgressView(value: effort, total: 10).tint(RoburStyle.amber)
      } else {
        Text("No Apple Fitness effort was recorded or shared for this workout.")
          .font(.subheadline).foregroundStyle(.secondary)
        Picker("Optional personal rating", selection: $draft.effort) {
          Text("Not rated").tag(Int?.none)
          ForEach(1...10, id: \.self) { value in Text("\(value) / 10").tag(Optional(value)) }
        }
      }
      if let load = TrainingInsights.sessionLoad(for: current, annotation: draft, maxHR: maxHR) {
        LabeledContent("Session load", value: "\(Int(load.rounded())) AU")
      }
    } header: { Text("Effort & load") }
    footer: { Text("Apple Fitness effort takes priority. When unavailable, load can use sampled heart-rate intensity or your optional personal rating. AU means arbitrary units; this is a training estimate.") }
  }

  private var analysisSection: some View {
    Section("Performance") {
      if let pace { LabeledContent("Average pace", value: paceText(pace)) }
      if let reference = comparablePace, let pace {
        LabeledContent("Recent comparable pace", value: paceText(reference))
        Text(String(format: "%.1f%% %@ than similar recent workouts", abs(pace / reference - 1) * 100,
          pace <= reference ? "faster" : "slower")).font(.caption).foregroundStyle(.secondary)
      }
      if let cadence = current.cadence {
        LabeledContent("Cadence", value: String(format: "%.0f per min", cadence))
      }
      if current.distanceKm == nil && current.cadence == nil {
        Text("Pace, splits and cadence appear when the recording includes usable distance and movement samples.")
          .font(.caption).foregroundStyle(.secondary)
      }
    }
  }

  private var heartRateSection: some View {
    Section {
      Chart(current.heartRateSamples, id: \.date) { sample in
        LineMark(x: .value("Time", sample.date), y: .value("Heart rate", sample.bpm))
          .foregroundStyle(RoburStyle.amber).lineStyle(StrokeStyle(lineWidth: 2))
      }.chartYAxisLabel("bpm").frame(height: 160)
      Chart(zones, id: \.zone) { zone in
        BarMark(x: .value("Minutes", zone.minutes), y: .value("Zone", "Zone \(zone.zone)"))
          .foregroundStyle(zoneColor(zone.zone)).cornerRadius(3)
          .annotation(position: .trailing) { Text("\(Int(zone.minutes))m").font(.caption) }
      }.frame(height: 160)
    } header: { Text("Heart-rate zones") }
    footer: { Text("Based on your configured maximum of \(Int(maxHR)) bpm. Time without usable samples is excluded. Change maximum HR in Settings.") }
  }

  private var splitSection: some View {
    Section("Recorded distance splits") {
      Chart(current.splits) { split in
        BarMark(x: .value("Split", "\(split.index)"), y: .value("Minutes", split.minutes))
          .foregroundStyle(RoburStyle.teal.gradient).cornerRadius(4)
      }.frame(height: 150)
      ForEach(current.splits) { split in
        LabeledContent("Split \(split.index) · \(String(format: "%.2f", split.distanceKm)) km", value: paceText(split.minutes / max(split.distanceKm, 0.01)))
      }
      Text("Derived from recorded distance samples; recording gaps can limit split accuracy.")
        .font(.caption).foregroundStyle(.secondary)
    }
  }

  private var muscleSection: some View {
    Section("Muscles trained") {
      ForEach(MuscleGroup.allCases) { group in
        Toggle(group.rawValue, isOn: Binding(get: { draft.muscles.contains(group) }, set: { value in
          if value { draft.muscles.insert(group) } else { draft.muscles.remove(group) }
        }))
      }
    }
  }

  private var placeSection: some View {
    Section("Place & notes") {
      Picker("Fitness centre", selection: $draft.gymID) {
        Text("No place").tag(UUID?.none)
        ForEach(journal.gyms) { gym in Text(gym.name).tag(Optional(gym.id)) }
      }
      TextField("Exercises, sets, progress, how you felt…", text: $draft.notes, axis: .vertical).lineLimit(3...8)
    }
  }

  private func paceText(_ value: Double) -> String {
    let seconds = max(0, Int((value * 60).rounded()))
    return String(format: "%d:%02d min/km", seconds / 60, seconds % 60)
  }
}
