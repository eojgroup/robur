import Foundation
import XCTest
@testable import Robur

final class WorkoutReviewTests: XCTestCase {
  private let workoutID = "3D65ACD6-EE6E-49C4-A5A4-F098D61681A8"
  private let date = Date(timeIntervalSince1970: 1_700_000_000)

  private func temporaryURL() -> URL {
    FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
      .appendingPathComponent("reviews.json")
  }

  private func workout() -> WorkoutRecord {
    WorkoutRecord(id: workoutID, start: date, end: date.addingTimeInterval(1_800), title: "Strength",
      symbol: "dumbbell.fill", minutes: 30, distanceKm: nil, energyKcal: nil, averageHeartRate: nil, source: "Test")
  }

  @MainActor
  func testPhoneJournalAppliesWatchReviewWithoutChangingEffortOrEchoing() async throws {
    let url = temporaryURL()
    defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
    let store = WorkoutReviewStore(url: url.appendingPathExtension("reviews"))
    let journal = WorkoutJournal(url: url, reviewStore: store)
    XCTAssertTrue(journal.save(WorkoutAnnotation(muscles: [.core], effort: 7, notes: "Phone"), for: workout()))
    let local = try XCTUnwrap(store.reviews[workoutID])
    store.markSynced(forID: workoutID, entry: local)
    var forwarded = 0
    store.onLocalChange = { _, _ in forwarded += 1 }
    let watch = WorkoutReviewEntry(annotation: WorkoutAnnotation(muscles: [.back], notes: "Watch"), updatedAt: local.updatedAt.addingTimeInterval(1))
    XCTAssertTrue(store.mergeRemote(entry: watch, forID: workoutID))
    journal.synchronizeReviews()
    XCTAssertEqual(journal.annotations[workoutID], WorkoutAnnotation(muscles: [.back], effort: 7, notes: "Watch"))
    XCTAssertTrue(store.pendingReviewedIDs.isEmpty)
    XCTAssertEqual(forwarded, 0)
    let archive = try Data(contentsOf: url)
    let reloaded = WorkoutJournal(url: url, reviewStore: store)
    reloaded.synchronizeReviews()
    XCTAssertEqual(try Data(contentsOf: url), archive)
    XCTAssertEqual(reloaded.annotations[workoutID], journal.annotations[workoutID])
  }

  @MainActor
  func testLegacyJournalSeedsOnlyNonemptyUUIDReviewsOnceWithoutQueuing() async throws {
    struct Legacy: Encodable {
      let annotations: [String: WorkoutAnnotation]
      let gyms: [String] = []
      let visits: [String] = []
    }
    let url = temporaryURL()
    defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
    try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    let emptyID = UUID().uuidString
    try JSONEncoder().encode(Legacy(annotations: [
      workoutID: WorkoutAnnotation(muscles: [.quads], effort: 8, notes: "Legacy"),
      emptyID: WorkoutAnnotation(effort: 5), "not-a-uuid": WorkoutAnnotation(notes: "Local fixture")
    ])).write(to: url)
    let store = WorkoutReviewStore(url: url.appendingPathExtension("reviews"))
    let journal = WorkoutJournal(url: url, reviewStore: store)
    journal.synchronizeReviews()
    XCTAssertEqual(Set(store.reviews.keys), [workoutID])
    XCTAssertEqual(store.reviews[workoutID]?.updatedAt, Date(timeIntervalSince1970: 0))
    XCTAssertEqual(store.annotation(for: workoutID), WorkoutAnnotation(muscles: [.quads], notes: "Legacy"))
    XCTAssertTrue(store.pendingReviewedIDs.isEmpty)
    let archive = try Data(contentsOf: url)
    journal.synchronizeReviews()
    XCTAssertEqual(try Data(contentsOf: url), archive)
  }

  @MainActor
  func testPhoneSaveRemainsDurableWhenSharedStoreFailsAndRetriesAfterRelaunch() async throws {
    let url = temporaryURL()
    defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
    try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    let brokenURL = url.appendingPathExtension("broken")
    try Data("unreadable".utf8).write(to: brokenURL)
    let broken = WorkoutReviewStore(url: brokenURL)
    let journal = WorkoutJournal(url: url, reviewStore: broken)
    let annotation = WorkoutAnnotation(muscles: [.arms], effort: 6, notes: "Saved despite unavailable sync")
    XCTAssertTrue(journal.save(annotation, for: workout()))
    XCTAssertEqual(journal.annotations[workoutID], annotation)
    XCTAssertTrue(broken.reviews.isEmpty)
    let repaired = WorkoutReviewStore(url: url.appendingPathExtension("repaired"))
    let reloaded = WorkoutJournal(url: url, reviewStore: repaired)
    reloaded.synchronizeReviews()
    XCTAssertEqual(reloaded.annotations[workoutID], annotation)
    XCTAssertEqual(repaired.annotation(for: workoutID), WorkoutAnnotation(muscles: [.arms], notes: annotation.notes))
    XCTAssertEqual(repaired.pendingReviewedIDs, [workoutID])
  }

  @MainActor
  func testJournalFailedIncomingPersistenceRollsBackAndRetriesWithoutEcho() async throws {
    let url = temporaryURL()
    defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
    let store = WorkoutReviewStore(url: url.appendingPathExtension("reviews"))
    let journal = WorkoutJournal(url: url, reviewStore: store)
    let original = WorkoutAnnotation(muscles: [.core], effort: 4, notes: "Original")
    XCTAssertTrue(journal.save(original, for: workout()))
    let local = try XCTUnwrap(store.reviews[workoutID])
    let remote = WorkoutReviewEntry(annotation: WorkoutAnnotation(muscles: [.back], notes: "Remote"), updatedAt: local.updatedAt.addingTimeInterval(1))
    XCTAssertTrue(store.mergeRemote(entry: remote, forID: workoutID))
    try FileManager.default.removeItem(at: url)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false)
    journal.synchronizeReviews()
    XCTAssertEqual(journal.annotations[workoutID], original)
    XCTAssertNotNil(journal.storageError)
    try FileManager.default.removeItem(at: url)
    journal.synchronizeReviews()
    XCTAssertEqual(journal.annotations[workoutID], WorkoutAnnotation(muscles: [.back], effort: 4, notes: "Remote"))
    XCTAssertTrue(store.pendingReviewedIDs.isEmpty)
  }

  @MainActor
  func testInvalidIDsDatesAndOversizedNotesDoNotCreateReviews() async {
    let url = temporaryURL()
    defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
    let store = WorkoutReviewStore(url: url)
    XCTAssertFalse(store.save(annotation: WorkoutAnnotation(notes: "note"), forID: "not-a-workout"))
    XCTAssertFalse(store.save(annotation: WorkoutAnnotation(), forID: workoutID, updatedAt: Date(timeIntervalSince1970: -.infinity)))
    XCTAssertFalse(store.save(annotation: WorkoutAnnotation(), forID: workoutID, updatedAt: Date().addingTimeInterval(172_800)))
    XCTAssertFalse(store.save(annotation: WorkoutAnnotation(notes: String(repeating: "a", count: 2_001)), forID: workoutID))
    XCTAssertTrue(store.reviews.isEmpty)
    XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
  }

  @MainActor
  func testEmptyReviewStillMarksWorkoutReviewedAndCanonicalizesUUID() async {
    let url = temporaryURL()
    defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
    let store = WorkoutReviewStore(url: url)
    XCTAssertTrue(store.save(annotation: WorkoutAnnotation(), forID: workoutID.lowercased(), updatedAt: date))
    XCTAssertEqual(store.annotation(for: workoutID), WorkoutAnnotation())
    XCTAssertEqual(Set(store.reviews.keys), [workoutID])
    XCTAssertEqual(store.pendingReviewedIDs, [workoutID])
  }

  @MainActor
  func testRemoteMergesKeepLatestRevisionWithoutQueuingAnEcho() async {
    let url = temporaryURL()
    defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
    let store = WorkoutReviewStore(url: url)
    let newer = WorkoutReviewEntry(annotation: WorkoutAnnotation(muscles: [.back], notes: "New"), updatedAt: date.addingTimeInterval(10))
    let older = WorkoutReviewEntry(annotation: WorkoutAnnotation(notes: "Old"), updatedAt: date)
    var callbacks = 0
    store.onLocalChange = { _, _ in callbacks += 1 }
    XCTAssertTrue(store.mergeRemote(entry: newer, forID: workoutID))
    XCTAssertTrue(store.mergeRemote(entry: older, forID: workoutID))
    XCTAssertTrue(store.mergeRemote(entry: newer, forID: workoutID))
    XCTAssertFalse(store.mergeRemote(entry: newer, forID: "invalid"))
    XCTAssertEqual(store.reviews[workoutID], newer)
    XCTAssertTrue(store.pendingReviewedIDs.isEmpty)
    XCTAssertEqual(callbacks, 0)
    XCTAssertEqual(WorkoutReviewStore(url: url).reviews[workoutID], newer)
  }

  @MainActor
  func testEqualTimestampConflictsConvergeRegardlessOfDeliveryOrder() async {
    let firstURL = temporaryURL(), secondURL = temporaryURL()
    defer {
      try? FileManager.default.removeItem(at: firstURL.deletingLastPathComponent())
      try? FileManager.default.removeItem(at: secondURL.deletingLastPathComponent())
    }
    let first = WorkoutReviewStore(url: firstURL), second = WorkoutReviewStore(url: secondURL)
    let a = WorkoutReviewEntry(annotation: WorkoutAnnotation(notes: "A"), updatedAt: date)
    let z = WorkoutReviewEntry(annotation: WorkoutAnnotation(notes: "Z"), updatedAt: date)
    XCTAssertTrue(first.mergeRemote(entry: a, forID: workoutID))
    XCTAssertTrue(first.mergeRemote(entry: z, forID: workoutID))
    XCTAssertTrue(second.mergeRemote(entry: z, forID: workoutID))
    XCTAssertTrue(second.mergeRemote(entry: a, forID: workoutID))
    XCTAssertEqual(first.reviews, second.reviews)
  }

  @MainActor
  func testCanonicalNoOpDoesNotResendOrReplaceTimestamp() async throws {
    let url = temporaryURL()
    defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
    let store = WorkoutReviewStore(url: url)
    var callbacks = 0
    store.onLocalChange = { _, _ in callbacks += 1 }
    let annotation = WorkoutAnnotation(muscles: [.core], effort: 7, notes: "Planks")
    XCTAssertTrue(store.save(annotation: annotation, forID: workoutID, updatedAt: date))
    let entry = try XCTUnwrap(store.reviews[workoutID])
    XCTAssertNil(entry.annotation.effort)
    store.markSynced(forID: workoutID, entry: entry)
    let archive = try Data(contentsOf: url)
    var changedPhoneFields = annotation
    changedPhoneFields.effort = 3
    XCTAssertTrue(store.save(annotation: changedPhoneFields, forID: workoutID, updatedAt: date.addingTimeInterval(20)))
    XCTAssertEqual(store.reviews[workoutID], entry)
    XCTAssertTrue(store.pendingReviewedIDs.isEmpty)
    XCTAssertEqual(callbacks, 1)
    XCTAssertEqual(try Data(contentsOf: url), archive)
  }

  @MainActor
  func testOutboxSurvivesRelaunchUntilExactReceiptAndDoesNotResendAfterReceipt() async throws {
    let url = temporaryURL()
    defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
    let store = WorkoutReviewStore(url: url)
    XCTAssertTrue(store.save(annotation: WorkoutAnnotation(notes: "One"), forID: workoutID, updatedAt: date))
    let first = try XCTUnwrap(store.reviews[workoutID])
    XCTAssertTrue(store.save(annotation: WorkoutAnnotation(notes: "Two"), forID: workoutID, updatedAt: date.addingTimeInterval(1)))
    let reloaded = WorkoutReviewStore(url: url)
    XCTAssertEqual(reloaded.pendingReviewedIDs, [workoutID])
    reloaded.markSynced(forID: workoutID, entry: first)
    XCTAssertEqual(reloaded.pendingReviewedIDs, [workoutID])
    let current = try XCTUnwrap(reloaded.reviews[workoutID])
    reloaded.markSynced(forID: workoutID, entry: current)
    let acknowledged = WorkoutReviewStore(url: url)
    XCTAssertTrue(acknowledged.pendingReviewedIDs.isEmpty)
    XCTAssertEqual(acknowledged.reviews[workoutID], current)
    XCTAssertTrue(acknowledged.save(annotation: current.annotation, forID: workoutID))
    XCTAssertTrue(acknowledged.pendingReviewedIDs.isEmpty)
  }

  func testPayloadRoundTripEnforcesSizeVersionUUIDAndPrivateFields() throws {
    let entry = WorkoutReviewEntry(annotation: WorkoutAnnotation(muscles: [.arms, .shoulders], notes: String(repeating: "x", count: 2_000)), updatedAt: date)
    let data = try WorkoutReviewRules.encode(workoutID: workoutID.lowercased(), entry: entry)
    XCTAssertLessThanOrEqual(data.count, WorkoutReviewRules.maximumPayloadBytes)
    XCTAssertEqual(try WorkoutReviewRules.decode(data), WorkoutReviewPayload(version: 1, workoutID: workoutID, entry: entry))
    XCTAssertThrowsError(try WorkoutReviewRules.decode(Data(repeating: 0, count: WorkoutReviewRules.maximumPayloadBytes + 1)))
    XCTAssertThrowsError(try WorkoutReviewRules.decode(JSONEncoder().encode(WorkoutReviewPayload(version: 2, workoutID: workoutID, entry: entry))))
    XCTAssertThrowsError(try WorkoutReviewRules.decode(JSONEncoder().encode(WorkoutReviewPayload(version: 1, workoutID: "arbitrary", entry: entry))))
    let privateEntry = WorkoutReviewEntry(annotation: WorkoutAnnotation(effort: 7), updatedAt: date)
    XCTAssertThrowsError(try WorkoutReviewRules.encode(workoutID: workoutID, entry: privateEntry))
    let oversized = WorkoutReviewEntry(annotation: WorkoutAnnotation(notes: String(repeating: "a", count: 2_001)), updatedAt: date)
    XCTAssertThrowsError(try WorkoutReviewRules.encode(workoutID: workoutID, entry: oversized))
  }

  @MainActor
  func testUnreadableArchiveIsPreserved() async throws {
    let url = temporaryURL()
    defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
    try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    let original = Data("invalid archive".utf8)
    try original.write(to: url)
    let store = WorkoutReviewStore(url: url)
    XCTAssertNotNil(store.lastError)
    XCTAssertFalse(store.save(annotation: WorkoutAnnotation(), forID: workoutID))
    XCTAssertEqual(try Data(contentsOf: url), original)
    XCTAssertTrue(store.reviews.isEmpty)
  }
}
