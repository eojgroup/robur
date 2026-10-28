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
  private var suppressedGyms: Set<UUID> = []

  private struct Archive: Codable {
    var annotations: [String: WorkoutAnnotation]
    var gyms: [GymLocation]
    var visits: [GymVisit]
    var suppressedGyms: Set<UUID>? = nil
  }

  init(url: URL? = nil) {
    self.url = url ?? URL.applicationSupportDirectory.appending(path: "Robur/workout-journal.json")
    do {
      let data = try Data(contentsOf: self.url)
      let archive = try JSONDecoder().decode(Archive.self, from: data)
      annotations = archive.annotations
      gyms = archive.gyms
      visits = archive.visits
      suppressedGyms = archive.suppressedGyms ?? []
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

  func updateGymPosition(id: UUID, latitude: Double, longitude: Double) {
    guard latitude.isFinite, longitude.isFinite, (-90...90).contains(latitude), (-180...180).contains(longitude),
          let index = gyms.firstIndex(where: { $0.id == id }) else { return }
    let previous = archive
    gyms[index].latitude = latitude
    gyms[index].longitude = longitude
    suppressedGyms.remove(id)
    if let visitIndex = visits.lastIndex(where: { $0.gymID == id && $0.end == nil && $0.automatic == true }) {
      visits[visitIndex].end = Date()
    }
    if !persist() { restore(previous) }
  }

  func deleteGym(_ gym: GymLocation) {
    let previous = archive
    gyms.removeAll { $0.id == gym.id }
    for id in Array(annotations.keys) where annotations[id]?.gymID == gym.id {
      annotations[id]?.gymID = nil
    }
    visits.removeAll { $0.gymID == gym.id }
    suppressedGyms.remove(gym.id)
    if !persist() {
      annotations = previous.annotations
      gyms = previous.gyms
      visits = previous.visits
      suppressedGyms = previous.suppressedGyms ?? []
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
      let previous = archive
      suppressedGyms.insert(visits[index].gymID)
      visits[index].end = max(now, visits[index].start)
      if !persist() { restore(previous) }
    }
  }

  func suggestedGym(for workout: WorkoutRecord) -> UUID? {
    visits.last { visit in
      visit.start <= workout.end && (visit.end ?? Date()) >= workout.start
    }?.gymID
  }

  func automaticArrival(gymID: UUID, now: Date = Date()) {
    guard gyms.contains(where: { $0.id == gymID }), !suppressedGyms.contains(gymID) else { return }
    if let active = activeVisit {
      guard active.gymID != gymID && active.automatic == true else { return }
    }
    let previous = archive
    if let index = visits.lastIndex(where: { $0.end == nil }) { visits[index].end = max(now, visits[index].start) }
    visits.append(GymVisit(gymID: gymID, start: now, automatic: true))
    if !persist() { restore(previous) }
  }

  func automaticDeparture(gymID: UUID, now: Date = Date()) {
    let previous = archive
    suppressedGyms.remove(gymID)
    if let index = visits.lastIndex(where: { $0.end == nil && $0.gymID == gymID && $0.automatic == true }) {
      visits[index].end = max(now, visits[index].start)
    }
    if !persist() { restore(previous) }
  }

  func endAutomaticVisit(now: Date = Date()) {
    guard activeVisit?.automatic == true else { return }
    checkOut(now: now)
  }

  func deleteVisit(_ visit: GymVisit) {
    let previous = archive
    if visit.end == nil { suppressedGyms.insert(visit.gymID) }
    visits.removeAll { $0.id == visit.id }
    if !persist() { restore(previous) }
  }

  private var archive: Archive {
    Archive(annotations: annotations, gyms: gyms, visits: visits, suppressedGyms: suppressedGyms)
  }

  private func restore(_ archive: Archive) {
    annotations = archive.annotations
    gyms = archive.gyms
    visits = archive.visits
    suppressedGyms = archive.suppressedGyms ?? []
  }

  @discardableResult
  private func persist() -> Bool {
    guard !unreadableArchive else {
      storageError = "The saved journal could not be opened. Your existing file has been preserved."
      return false
    }
    do {
      try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
      let data = try JSONEncoder().encode(archive)
      #if os(iOS)
      try data.write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
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
