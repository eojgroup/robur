import XCTest
@testable import Robur

final class WorkoutHistoryTests: XCTestCase {
  private var calendar: Calendar {
    var calendar = Calendar(identifier: .iso8601)
    calendar.timeZone = TimeZone(secondsFromGMT: 0)!
    return calendar
  }
  private func date(_ value: String) -> Date { ISO8601DateFormatter().date(from: value)! }
  private func workout(_ id: String, _ start: String, minutes: Double = 40) -> WorkoutRecord {
    let start = date(start)
    return WorkoutRecord(id: id, start: start, end: start.addingTimeInterval(minutes * 60), title: "Strength",
      symbol: "dumbbell.fill", minutes: minutes, distanceKm: nil, energyKcal: nil, averageHeartRate: nil, source: "Test")
  }

  func testAllHistoryHasNoArtificialStartLimit() {
    XCTAssertNil(HistoryRange.all.startDate())
    let now = date("2026-10-28T12:00:00Z")
    XCTAssertEqual(HistoryRange.month.startDate(now: now, calendar: calendar), date("2026-09-28T12:00:00Z"))
  }

  func testWeeklyBucketsDoNotConflateWeeksAcrossYears() {
    let workouts = [workout("old", "2025-01-08T12:00:00Z"), workout("new", "2026-01-07T12:00:00Z")]
    let buckets = WorkoutAnalytics.buckets(workouts: workouts, annotations: [:], calendar: calendar)
    XCTAssertEqual(buckets.count, 2)
    XCTAssertEqual(buckets.map(\.workouts), [1, 1])
  }

  func testLoadOnlyUsesRatedWorkoutsAndPreservesUnratedDuration() {
    let workouts = [workout("a", "2026-10-26T12:00:00Z", minutes: 30),
                    workout("b", "2026-10-27T12:00:00Z", minutes: 60)]
    let result = WorkoutAnalytics.buckets(workouts: workouts,
      annotations: ["a": WorkoutAnnotation(effort: 7)], calendar: calendar)
    XCTAssertEqual(result.count, 1)
    XCTAssertEqual(result[0].minutes, 90)
    XCTAssertEqual(result[0].load, 210)
    XCTAssertEqual(result[0].workouts, 2)
    XCTAssertEqual(result[0].ratedWorkouts, 1)
  }

  func testMonthlyMeansKeepMetricsSeparateAndExcludeInvalidValues() {
    let readings = [
      FitnessReading(id: "1", date: date("2026-01-01T12:00:00Z"), value: 40, metric: .cardio),
      FitnessReading(id: "2", date: date("2026-01-20T12:00:00Z"), value: 44, metric: .cardio),
      FitnessReading(id: "3", date: date("2026-01-20T12:00:00Z"), value: 60, metric: .restingHR),
      FitnessReading(id: "4", date: date("2026-01-21T12:00:00Z"), value: .nan, metric: .cardio)
    ]
    let result = WorkoutAnalytics.trend(readings: readings, metric: .cardio, calendar: calendar, monthly: true)
    XCTAssertEqual(result.count, 1)
    XCTAssertEqual(result[0].value, 42)
    XCTAssertEqual(result[0].date, date("2026-01-01T00:00:00Z"))
  }

  @MainActor
  func testJournalRoundTripPreservesWorkoutReview() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let url = directory.appendingPathComponent("journal.json")
    let store = WorkoutReviewStore(url: directory.appendingPathComponent("reviews.json"))
    let journal = WorkoutJournal(url: url, reviewStore: store)
    let session = workout("session", "2026-10-28T10:30:00Z")
    let annotation = WorkoutAnnotation(muscles: [.back, .glutes], effort: 8, notes: "Deadlifts",
      quickReview: WorkoutQuickReview(bodyFeeling: .loose))
    XCTAssertTrue(journal.save(annotation, for: session))
    XCTAssertEqual(WorkoutJournal(url: url, reviewStore: store).annotations[session.id], annotation)
  }

  @MainActor
  func testLegacyLocationArchiveIsPurgedWithoutLosingReviewsOrSyncDates() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let url = directory.appendingPathComponent("journal.json")
    let id = UUID().uuidString
    let original = WorkoutAnnotation(muscles: [.back, .core], effort: 7, notes: "Keep this review",
      quickReview: WorkoutQuickReview(pace: .steady, feltEffort: 6))
    let annotationData = try JSONEncoder().encode(original)
    var legacyAnnotation = try XCTUnwrap(JSONSerialization.jsonObject(with: annotationData) as? [String: Any])
    legacyAnnotation["gymID"] = UUID().uuidString
    let legacy: [String: Any] = [
      "annotations": [id: legacyAnnotation],
      "gyms": [["id": UUID().uuidString, "name": "Old gym", "latitude": 52, "longitude": 13]],
      "visits": [["id": UUID().uuidString, "gymID": UUID().uuidString, "start": 100]],
      "suppressedGyms": [UUID().uuidString],
      "appliedReviewDates": [id: 12], "pendingReviewDates": [id: 34]
    ]
    try JSONSerialization.data(withJSONObject: legacy).write(to: url)
    let store = WorkoutReviewStore(url: directory.appendingPathComponent("reviews.json"))
    let journal = WorkoutJournal(url: url, reviewStore: store)
    XCTAssertNil(journal.storageError)
    XCTAssertEqual(journal.annotations[id], original)
    let cleaned = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
    XCTAssertNil(cleaned["gyms"])
    XCTAssertNil(cleaned["visits"])
    XCTAssertNil(cleaned["suppressedGyms"])
    let savedAnnotations = try XCTUnwrap(cleaned["annotations"] as? [String: [String: Any]])
    XCTAssertNil(savedAnnotations[id]?["gymID"])
    XCTAssertEqual(cleaned["appliedReviewDates"] as? [String: Double], [id: 12])
    XCTAssertEqual(cleaned["pendingReviewDates"] as? [String: Double], [id: 34])
    let saved = try Data(contentsOf: url)
    XCTAssertEqual(WorkoutJournal(url: url, reviewStore: store).annotations[id], original)
    XCTAssertEqual(try Data(contentsOf: url), saved, "Migration should not rewrite an already-clean journal")
  }

  @MainActor
  func testCorruptJournalIsPreserved() async throws {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: url) }
    let original = Data("invalid journal".utf8)
    try original.write(to: url)
    let journal = WorkoutJournal(url: url)
    XCTAssertNotNil(journal.storageError)
    XCTAssertFalse(journal.save(WorkoutAnnotation(notes: "Do not overwrite"), for: workout("session", "2026-10-28T10:30:00Z")))
    XCTAssertTrue(journal.annotations.isEmpty)
    XCTAssertEqual(try Data(contentsOf: url), original)
  }

  @MainActor
  func testFailedSaveKeepsLoadedReview() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let url = directory.appendingPathComponent("journal.json")
    let store = WorkoutReviewStore(url: directory.appendingPathComponent("reviews.json"))
    let journal = WorkoutJournal(url: url, reviewStore: store)
    let session = workout("session", "2026-10-28T10:30:00Z")
    let original = WorkoutAnnotation(muscles: [.back], effort: 8, notes: "Preserve")
    XCTAssertTrue(journal.save(original, for: session))
    try FileManager.default.removeItem(at: url)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false)
    XCTAssertFalse(journal.save(WorkoutAnnotation(notes: "Could not save"), for: session))
    XCTAssertEqual(journal.annotations[session.id], original)
    XCTAssertNotNil(journal.storageError)
  }

  @MainActor
  func testCanReadJournalWrittenBeforeAutomaticDetectionWasAdded() async throws {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: url) }
    try Data(#"{"annotations":{},"gyms":[],"visits":[]}"#.utf8).write(to: url)
    let journal = WorkoutJournal(url: url)
    XCTAssertNil(journal.storageError)
    XCTAssertTrue(journal.annotations.isEmpty)
    let cleaned = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
    XCTAssertNil(cleaned["gyms"])
    XCTAssertNil(cleaned["visits"])
  }
}
