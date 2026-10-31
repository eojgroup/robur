import Foundation
import Combine

struct WorkoutReviewEntry: Codable, Equatable {
  let annotation: WorkoutAnnotation
  let updatedAt: Date
}

struct WorkoutReviewPayload: Codable, Equatable {
  let version: Int
  let workoutID: String
  let entry: WorkoutReviewEntry
}

enum WorkoutReviewRules {
  static let maximumNotes = 2_000
  static let maximumPayloadBytes = 16_384

  static func canonicalID(_ value: String) -> String? { UUID(uuidString: value)?.uuidString }

  static func normalized(_ annotation: WorkoutAnnotation) -> WorkoutAnnotation? {
    guard annotation.notes.count <= maximumNotes, annotation.notes.utf8.count <= 8_000,
          annotation.muscles.count <= MuscleGroup.allCases.count,
          annotation.quickReview?.isValid != false else { return nil }
    // Gym identity and personal effort remain phone-local; only the review is synced.
    return WorkoutAnnotation(muscles: annotation.muscles, notes: annotation.notes, quickReview: annotation.quickReview?.isEmpty == false ? annotation.quickReview : nil)
  }

  static func valid(_ entry: WorkoutReviewEntry, now: Date = Date()) -> Bool {
    let timestamp = entry.updatedAt.timeIntervalSince1970
    return timestamp.isFinite && timestamp >= 0 && entry.updatedAt <= now.addingTimeInterval(86_400) &&
      normalized(entry.annotation) == entry.annotation
  }

  static func shouldReplace(_ current: WorkoutReviewEntry?, with incoming: WorkoutReviewEntry) -> Bool {
    guard let current else { return true }
    if incoming.updatedAt != current.updatedAt { return incoming.updatedAt > current.updatedAt }
    // Equal-time conflicts converge on both devices without inventing an edit order.
    func key(_ entry: WorkoutReviewEntry) -> String {
      entry.annotation.muscles.map(\.rawValue).sorted().joined(separator: ",") + "\u{0}" + entry.annotation.notes + "\u{0}" + (entry.annotation.quickReview?.conflictKey ?? "")
    }
    return key(incoming) > key(current)
  }

  static func encode(workoutID: String, entry: WorkoutReviewEntry) throws -> Data {
    guard let id = canonicalID(workoutID), valid(entry) else { throw ReviewError.invalidPayload }
    let result = try JSONEncoder().encode(WorkoutReviewPayload(version: 1, workoutID: id, entry: entry))
    guard result.count <= maximumPayloadBytes else { throw ReviewError.invalidPayload }
    return result
  }

  static func decode(_ data: Data) throws -> WorkoutReviewPayload {
    guard data.count <= maximumPayloadBytes else { throw ReviewError.invalidPayload }
    let payload = try JSONDecoder().decode(WorkoutReviewPayload.self, from: data)
    guard payload.version == 1, canonicalID(payload.workoutID) == payload.workoutID, valid(payload.entry) else {
      throw ReviewError.invalidPayload
    }
    return payload
  }

  enum ReviewError: Error { case invalidPayload }
}

@MainActor
final class WorkoutReviewStore: ObservableObject {
  static let shared = WorkoutReviewStore()
  @Published private(set) var reviews: [String: WorkoutReviewEntry] = [:]
  @Published private(set) var pendingReviewedIDs: Set<String> = []
  @Published private(set) var lastError: String?
  var onLocalChange: ((String, WorkoutReviewEntry) -> Void)?
  private let url: URL
  private var unreadableArchive = false

  private struct Archive: Codable {
    var version = 1
    var reviews: [String: WorkoutReviewEntry]
    var pending: Set<String>
  }

  init(url: URL? = nil) {
    self.url = url ?? URL.applicationSupportDirectory.appending(path: "Robur/workout-reviews.json")
    do {
      let data = try Data(contentsOf: self.url)
      let archive = try JSONDecoder().decode(Archive.self, from: data)
      guard archive.version == 1, archive.reviews.allSatisfy({ WorkoutReviewRules.canonicalID($0.key) == $0.key && WorkoutReviewRules.valid($0.value) }),
            archive.pending.isSubset(of: Set(archive.reviews.keys)) else { throw WorkoutReviewRules.ReviewError.invalidPayload }
      reviews = archive.reviews
      pendingReviewedIDs = archive.pending
    } catch let error as CocoaError where error.code == .fileReadNoSuchFile {
      // A new device starts with an empty review journal.
    } catch {
      unreadableArchive = true
      lastError = "Could not open saved workout reviews. The existing file has been preserved."
    }
  }

  func annotation(for workoutID: String) -> WorkoutAnnotation? {
    guard let id = WorkoutReviewRules.canonicalID(workoutID) else { return nil }
    return reviews[id]?.annotation
  }

  @discardableResult
  func save(annotation: WorkoutAnnotation, forID workoutID: String, updatedAt: Date = Date()) -> Bool {
    guard let id = WorkoutReviewRules.canonicalID(workoutID), let normalized = WorkoutReviewRules.normalized(annotation) else {
      lastError = "Unable to save this review. Use a valid workout and at most \(WorkoutReviewRules.maximumNotes) note characters."
      return false
    }
    guard updatedAt.timeIntervalSince1970.isFinite, updatedAt.timeIntervalSince1970 >= 0,
          updatedAt <= Date().addingTimeInterval(86_400) else {
      lastError = "The review date is invalid."
      return false
    }
    if reviews[id]?.annotation == normalized { lastError = nil; return true }
    let timestamp = max(updatedAt, reviews[id]?.updatedAt.addingTimeInterval(0.001) ?? updatedAt)
    let entry = WorkoutReviewEntry(annotation: normalized, updatedAt: timestamp)
    guard WorkoutReviewRules.valid(entry) else { lastError = "The review date is invalid."; return false }
    var next = reviews
    next[id] = entry
    var pending = pendingReviewedIDs
    pending.insert(id)
    guard persist(next, pending: pending) else { return false }
    onLocalChange?(id, entry)
    return true
  }

  @discardableResult
  func mergeRemote(entry: WorkoutReviewEntry, forID workoutID: String) -> Bool {
    guard let id = WorkoutReviewRules.canonicalID(workoutID), WorkoutReviewRules.valid(entry) else { return false }
    guard WorkoutReviewRules.shouldReplace(reviews[id], with: entry) else { return true }
    var next = reviews
    next[id] = entry
    var pending = pendingReviewedIDs
    pending.remove(id)
    // Remote updates are never forwarded back, preventing a sync echo loop.
    return persist(next, pending: pending)
  }

  func markSynced(forID workoutID: String, updatedAt: Date) {
    guard let id = WorkoutReviewRules.canonicalID(workoutID), reviews[id]?.updatedAt == updatedAt,
          pendingReviewedIDs.contains(id) else { return }
    var pending = pendingReviewedIDs
    pending.remove(id)
    _ = persist(reviews, pending: pending)
  }

  /// Clear only the exact revision the other device confirmed it saved. A late
  /// receipt must never remove a newer edit from the durable outbox.
  func markSynced(forID workoutID: String, entry: WorkoutReviewEntry) {
    guard let id = WorkoutReviewRules.canonicalID(workoutID), reviews[id] == entry else { return }
    markSynced(forID: id, updatedAt: entry.updatedAt)
  }

  private func persist(_ next: [String: WorkoutReviewEntry], pending: Set<String>) -> Bool {
    guard !unreadableArchive else { lastError = "Saved reviews could not be opened; the existing file has not been overwritten."; return false }
    do {
      try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
      let data = try JSONEncoder().encode(Archive(reviews: next, pending: pending))
      #if os(iOS) || os(watchOS)
      try data.write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
      #else
      try data.write(to: url, options: .atomic)
      #endif
      pendingReviewedIDs = pending
      reviews = next
      lastError = nil
      return true
    } catch {
      lastError = "Could not save workout review: \(error.localizedDescription)"
      return false
    }
  }
}
