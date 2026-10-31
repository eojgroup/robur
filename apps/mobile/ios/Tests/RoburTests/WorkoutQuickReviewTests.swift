import Foundation
import XCTest
@testable import Robur

final class WorkoutQuickReviewTests: XCTestCase {
  private let workoutID = "8ADE1684-A130-4AA5-B401-C2A643B1A840"
  private let date = Date(timeIntervalSince1970: 1_700_000_000)

  private var fullQuickReview: WorkoutQuickReview {
    WorkoutQuickReview(pace: .steady, feltEffort: 6, sportFocus: [.technique, .footwork, .skills],
      execution: .consistent, bodyFeeling: .comfortable)
  }

  private func temporaryURL() -> URL {
    FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
      .appendingPathComponent("reviews.json")
  }

  func testAnnotationDecodesArchiveWrittenBeforeQuickReview() throws {
    let data = Data(#"{"muscles":["Core"],"effort":7,"gymID":"4109357A-8C51-423B-89C3-04645AA12F4A","notes":"Legacy review"}"#.utf8)
    let annotation = try JSONDecoder().decode(WorkoutAnnotation.self, from: data)
    XCTAssertEqual(annotation, WorkoutAnnotation(muscles: [.core], effort: 7,
      gymID: UUID(uuidString: "4109357A-8C51-423B-89C3-04645AA12F4A"), notes: "Legacy review"))
    XCTAssertNil(annotation.quickReview)
  }

  @MainActor
  func testStructuredReviewSurvivesNormalizedSyncAndArchiveRoundTrip() async throws {
    let url = temporaryURL()
    defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
    let store = WorkoutReviewStore(url: url)
    let phone = WorkoutAnnotation(muscles: [.back, .core], effort: 9, gymID: UUID(), notes: "Controlled pace",
      quickReview: fullQuickReview)
    XCTAssertTrue(store.save(annotation: phone, forID: workoutID, updatedAt: date))
    let entry = try XCTUnwrap(store.reviews[workoutID])
    XCTAssertNil(entry.annotation.effort)
    XCTAssertNil(entry.annotation.gymID)
    XCTAssertEqual(entry.annotation.quickReview, fullQuickReview)
    XCTAssertEqual(entry.annotation.muscles, phone.muscles)
    XCTAssertEqual(entry.annotation.notes, phone.notes)
    let data = try WorkoutReviewRules.encode(workoutID: workoutID, entry: entry)
    XCTAssertEqual(try WorkoutReviewRules.decode(data).entry, entry)
    XCTAssertEqual(WorkoutReviewStore(url: url).reviews[workoutID], entry)
  }

  @MainActor
  func testInvalidFeltEffortIsRejectedByLocalAndRemoteReviewValidation() async throws {
    let url = temporaryURL()
    defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
    let store = WorkoutReviewStore(url: url)
    for effort in [0, 11] {
      let annotation = WorkoutAnnotation(quickReview: WorkoutQuickReview(feltEffort: effort))
      let entry = WorkoutReviewEntry(annotation: annotation, updatedAt: date)
      XCTAssertNil(WorkoutReviewRules.normalized(annotation))
      XCTAssertFalse(store.save(annotation: annotation, forID: workoutID, updatedAt: date))
      XCTAssertFalse(store.mergeRemote(entry: entry, forID: workoutID))
      XCTAssertThrowsError(try WorkoutReviewRules.encode(workoutID: workoutID, entry: entry))
      let data = try JSONEncoder().encode(WorkoutReviewPayload(version: 1, workoutID: workoutID, entry: entry))
      XCTAssertThrowsError(try WorkoutReviewRules.decode(data))
    }
    for effort in [1, 10] {
      XCTAssertNotNil(WorkoutReviewRules.normalized(WorkoutAnnotation(quickReview: WorkoutQuickReview(feltEffort: effort))))
    }
    XCTAssertTrue(store.reviews.isEmpty)
    XCTAssertTrue(store.pendingReviewedIDs.isEmpty)
  }

  @MainActor
  func testEqualTimestampConflictsConvergeForEveryQuickReviewField() async {
    let firstURL = temporaryURL(), secondURL = temporaryURL()
    defer {
      try? FileManager.default.removeItem(at: firstURL.deletingLastPathComponent())
      try? FileManager.default.removeItem(at: secondURL.deletingLastPathComponent())
    }
    let first = WorkoutReviewStore(url: firstURL), second = WorkoutReviewStore(url: secondURL)
    var variants: [WorkoutQuickReview] = []
    var changed = fullQuickReview; changed.pace = .fast; variants.append(changed)
    changed = fullQuickReview; changed.feltEffort = 8; variants.append(changed)
    changed = fullQuickReview; changed.sportFocus = [.tactics]; variants.append(changed)
    changed = fullQuickReview; changed.execution = .sharp; variants.append(changed)
    changed = fullQuickReview; changed.bodyFeeling = .loose; variants.append(changed)
    for quick in variants {
      let id = UUID().uuidString
      let baseline = WorkoutReviewEntry(annotation: WorkoutAnnotation(quickReview: fullQuickReview), updatedAt: date)
      let variant = WorkoutReviewEntry(annotation: WorkoutAnnotation(quickReview: quick), updatedAt: date)
      XCTAssertTrue(first.mergeRemote(entry: baseline, forID: id))
      XCTAssertTrue(first.mergeRemote(entry: variant, forID: id))
      XCTAssertTrue(second.mergeRemote(entry: variant, forID: id))
      XCTAssertTrue(second.mergeRemote(entry: baseline, forID: id))
      XCTAssertEqual(first.reviews[id], second.reviews[id])
    }
    XCTAssertTrue(first.pendingReviewedIDs.isEmpty)
    XCTAssertTrue(second.pendingReviewedIDs.isEmpty)
  }

  @MainActor
  func testIncomingStructuredReviewPreservesPhoneGymAndLegacyEffortWithoutEcho() async throws {
    let url = temporaryURL()
    defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
    let store = WorkoutReviewStore(url: url.appendingPathExtension("reviews"))
    let journal = WorkoutJournal(url: url, reviewStore: store)
    let gymID = UUID()
    let workout = WorkoutRecord(id: workoutID, start: date, end: date.addingTimeInterval(1_800), title: "Tennis",
      symbol: "tennis.racket", minutes: 30, distanceKm: nil, energyKcal: nil, averageHeartRate: nil, source: "Test")
    XCTAssertTrue(journal.save(WorkoutAnnotation(muscles: [.core], effort: 7, gymID: gymID, notes: "Phone",
      quickReview: WorkoutQuickReview(execution: .learning)), for: workout))
    let local = try XCTUnwrap(store.reviews[workoutID])
    store.markSynced(forID: workoutID, entry: local)
    var forwarded = 0
    store.onLocalChange = { _, _ in forwarded += 1 }
    let remote = WorkoutReviewEntry(annotation: WorkoutAnnotation(notes: "Watch", quickReview: fullQuickReview),
      updatedAt: local.updatedAt.addingTimeInterval(1))
    XCTAssertTrue(store.mergeRemote(entry: remote, forID: workoutID))
    journal.synchronizeReviews()
    let expected = WorkoutAnnotation(effort: 7, gymID: gymID, notes: "Watch", quickReview: fullQuickReview)
    XCTAssertEqual(journal.annotations[workoutID], expected)
    XCTAssertEqual(WorkoutJournal(url: url, reviewStore: store).annotations[workoutID], expected)
    XCTAssertTrue(store.pendingReviewedIDs.isEmpty)
    XCTAssertEqual(forwarded, 0)
  }
}
