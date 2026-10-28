import Foundation
import Combine

@MainActor
final class WorkoutJournal: ObservableObject {
  @Published private(set) var annotations: [String: WorkoutAnnotation] = [:]
  @Published private(set) var gyms: [GymLocation] = []
  @Published private(set) var visits: [GymVisit] = []
  @Published var storageError: String?
  private let url: URL
  private var unreadableArchive = false

  private struct Archive: Codable {
    var annotations: [String: WorkoutAnnotation]
    var gyms: [GymLocation]
    var visits: [GymVisit]
  }

  init(url: URL? = nil) {
    self.url = url ?? URL.applicationSupportDirectory.appending(path: "Robur/workout-journal.json")
    do {
      let data = try Data(contentsOf: self.url)
      let archive = try JSONDecoder().decode(Archive.self, from: data)
      annotations = archive.annotations
      gyms = archive.gyms
      visits = archive.visits
    } catch let error as CocoaError where error.code == .fileReadNoSuchFile {
      // A new journal starts empty.
    } catch {
      unreadableArchive = true
      storageError = "Unable to open your workout journal: \(error.localizedDescription)"
    }
  }

  @discardableResult
  func save(_ annotation: WorkoutAnnotation, for workout: WorkoutRecord) -> Bool {
    let previous = annotations[workout.id]
    var validated = annotation
    if let effort = validated.effort, !(1...10).contains(effort) { validated.effort = nil }
    annotations[workout.id] = validated
    if persist() { return true }
    annotations[workout.id] = previous
    return false
  }

  @discardableResult
  func addGym(name: String, latitude: Double? = nil, longitude: Double? = nil) -> Bool {
    let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return false }
    gyms.append(GymLocation(name: trimmed, latitude: latitude, longitude: longitude))
    if persist() { return true }
    gyms.removeLast()
    return false
  }

  func deleteGym(_ gym: GymLocation) {
    let previous = Archive(annotations: annotations, gyms: gyms, visits: visits)
    gyms.removeAll { $0.id == gym.id }
    for id in Array(annotations.keys) where annotations[id]?.gymID == gym.id {
      annotations[id]?.gymID = nil
    }
    visits.removeAll { $0.gymID == gym.id }
    if !persist() {
      annotations = previous.annotations
      gyms = previous.gyms
      visits = previous.visits
    }
  }

  var activeVisit: GymVisit? { visits.last { $0.end == nil } }
  func gymName(_ id: UUID?) -> String? { gyms.first { $0.id == id }?.name }

  func checkIn(_ gym: GymLocation, now: Date = Date()) {
    guard gyms.contains(where: { $0.id == gym.id }) else { return }
    let previous = visits
    if let index = visits.lastIndex(where: { $0.end == nil }) { visits[index].end = now }
    visits.append(GymVisit(gymID: gym.id, start: now))
    if !persist() { visits = previous }
  }

  func checkOut(now: Date = Date()) {
    if let index = visits.lastIndex(where: { $0.end == nil }) {
      let previous = visits
      visits[index].end = max(now, visits[index].start)
      if !persist() { visits = previous }
    }
  }

  func suggestedGym(for workout: WorkoutRecord) -> UUID? {
    visits.last { visit in
      visit.start <= workout.end && (visit.end ?? Date()) >= workout.start
    }?.gymID
  }

  @discardableResult
  private func persist() -> Bool {
    guard !unreadableArchive else {
      storageError = "The saved journal could not be opened. Your existing file has been preserved."
      return false
    }
    do {
      try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
      let data = try JSONEncoder().encode(Archive(annotations: annotations, gyms: gyms, visits: visits))
      #if os(iOS)
      try data.write(to: url, options: [.atomic, .completeFileProtection])
      #else
      try data.write(to: url, options: .atomic)
      #endif
      storageError = nil
      return true
    } catch {
      storageError = "Your changes could not be saved: \(error.localizedDescription)"
      return false
    }
  }
}
