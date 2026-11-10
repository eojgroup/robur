import Foundation
import Combine

@MainActor
final class WorkoutJournal: ObservableObject {
  @Published private(set) var annotations: [String: WorkoutAnnotation] = [:]
  @Published var storageError: String?
  private let url: URL
  private var unreadableArchive = false
  private let reviewStore: WorkoutReviewStore
  private var appliedReviewDates: [String: Date] = [:]
  private var pendingReviewDates: [String: Date] = [:]
  private var synchronizingReviews = false

  private struct Archive: Codable, Equatable {
    var annotations: [String: WorkoutAnnotation]
    var appliedReviewDates: [String: Date]? = nil
    var pendingReviewDates: [String: Date]? = nil
  }

  init(url: URL? = nil, reviewStore: WorkoutReviewStore? = nil) {
    self.url = url ?? URL.applicationSupportDirectory.appending(path: "Robur/workout-journal.json")
    self.reviewStore = reviewStore ?? .shared
    do {
      let data = try Data(contentsOf: self.url)
      let archive = try JSONDecoder().decode(Archive.self, from: data)
      restore(archive)
      // Ignore removed fields while decoding, then atomically discard saved
      // places/visits. A failed cleanup keeps all reviews loaded and leaves the
      // original file intact; the next successful journal save retries cleanup.
      if let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] {
        let oldAnnotations = object["annotations"] as? [String: [String: Any]] ?? [:]
        if ["gyms", "visits", "suppressedGyms"].contains(where: { object[$0] != nil }) ||
            oldAnnotations.values.contains(where: { $0["gymID"] != nil }) {
          persist()
        }
      }
    } catch let error as CocoaError where error.code == .fileReadNoSuchFile {
      // A new journal starts empty.
    } catch {
      unreadableArchive = true
      storageError = "Unable to open your workout journal: \(error.localizedDescription)"
    }
  }

  @discardableResult
  func save(_ annotation: WorkoutAnnotation, for workout: WorkoutRecord) -> Bool {
    let previous = archive
    var validated = annotation
    if let effort = validated.effort, !(1...10).contains(effort) { validated.effort = nil }
    annotations[workout.id] = validated
    if let id = WorkoutReviewRules.canonicalID(workout.id), let review = WorkoutReviewRules.normalized(validated) {
      for key in annotationKeys(for: id) where key != workout.id {
        annotations[key]?.muscles = review.muscles
        annotations[key]?.notes = review.notes
        annotations[key]?.quickReview = review.quickReview
      }
      if let shared = reviewStore.reviews[id], shared.annotation == review {
        appliedReviewDates[id] = shared.updatedAt
        pendingReviewDates.removeValue(forKey: id)
      } else {
        let latest = max(appliedReviewDates[id] ?? .distantPast,
                         pendingReviewDates[id] ?? .distantPast,
                         reviewStore.reviews[id]?.updatedAt ?? .distantPast)
        pendingReviewDates[id] = max(Date(), latest.addingTimeInterval(0.001))
      }
    }
    guard persist() else { restore(previous); return false }
    // The phone journal is already durable. If the shared review file is
    // unavailable, retain this local edit and retry without losing the save.
    synchronizeReviews()
    return true
  }

  func synchronizeReviews() {
    guard !unreadableArchive, !synchronizingReviews else { return }
    synchronizingReviews = true
    defer { synchronizingReviews = false }
    let previous = archive
    var forwardingError: String?

    for id in pendingReviewDates.keys.sorted() {
      guard let date = pendingReviewDates[id], let key = annotationKeys(for: id).first,
            let annotation = annotations[key], let review = WorkoutReviewRules.normalized(annotation) else { continue }
      let local = WorkoutReviewEntry(annotation: review, updatedAt: date)
      if let shared = reviewStore.reviews[id], WorkoutReviewRules.shouldReplace(local, with: shared) {
        pendingReviewDates.removeValue(forKey: id)
      } else if reviewStore.save(annotation: review, forID: id, updatedAt: date), let shared = reviewStore.reviews[id] {
        appliedReviewDates[id] = shared.updatedAt
        pendingReviewDates.removeValue(forKey: id)
      } else {
        forwardingError = reviewStore.lastError
      }
    }

    for (id, entry) in reviewStore.reviews.sorted(by: { $0.key < $1.key }) {
      guard pendingReviewDates[id] == nil, entry.updatedAt >= (appliedReviewDates[id] ?? .distantPast) else { continue }
      let keys = annotationKeys(for: id)
      for key in keys.isEmpty ? [id] : keys {
        var annotation = annotations[key] ?? WorkoutAnnotation()
        annotation.muscles = entry.annotation.muscles
        annotation.notes = entry.annotation.notes
        annotation.quickReview = entry.annotation.quickReview
        if annotations[key] != annotation { annotations[key] = annotation }
      }
      appliedReviewDates[id] = entry.updatedAt
    }

    // Old journals did not record edit dates. A stable, oldest-possible date
    // imports their nonempty reviews without making them newer than Watch edits.
    for key in annotations.keys.sorted() {
      guard let id = WorkoutReviewRules.canonicalID(key), reviewStore.reviews[id] == nil,
            appliedReviewDates[id] == nil, pendingReviewDates[id] == nil,
            let annotation = annotations[key], let review = WorkoutReviewRules.normalized(annotation),
            !review.muscles.isEmpty || !review.notes.isEmpty || review.quickReview?.isEmpty == false else { continue }
      let entry = WorkoutReviewEntry(annotation: review, updatedAt: Date(timeIntervalSince1970: 0))
      if reviewStore.mergeRemote(entry: entry, forID: id) { appliedReviewDates[id] = entry.updatedAt }
      else { forwardingError = reviewStore.lastError }
    }

    if archive != previous, !persist() { restore(previous); return }
    if let forwardingError { storageError = "Review saved on this iPhone; sync will retry. \(forwardingError)" }
  }

  private func annotationKeys(for id: String) -> [String] {
    annotations.keys.filter { WorkoutReviewRules.canonicalID($0) == id }.sorted {
      if ($0 == id) != ($1 == id) { return $0 == id }
      return $0 < $1
    }
  }

  private var archive: Archive {
    Archive(annotations: annotations,
            appliedReviewDates: appliedReviewDates, pendingReviewDates: pendingReviewDates)
  }

  private func restore(_ archive: Archive) {
    annotations = archive.annotations
    appliedReviewDates = archive.appliedReviewDates ?? [:]
    pendingReviewDates = archive.pendingReviewDates ?? [:]
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
