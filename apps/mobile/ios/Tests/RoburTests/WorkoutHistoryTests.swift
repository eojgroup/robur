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
  func testJournalRoundTripAndVisitSuggestion() throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let url = directory.appendingPathComponent("journal.json")
    let journal = WorkoutJournal(url: url)
    XCTAssertTrue(journal.addGym(name: "  My gym  ", latitude: 52, longitude: 13))
    let gym = try XCTUnwrap(journal.gyms.first)
    journal.checkIn(gym, now: date("2026-10-28T10:00:00Z"))
    journal.checkOut(now: date("2026-10-28T12:00:00Z"))
    let session = workout("session", "2026-10-28T10:30:00Z")
    XCTAssertEqual(journal.suggestedGym(for: session), gym.id)
    XCTAssertNil(journal.suggestedGym(for: workout("other", "2026-10-27T10:30:00Z")))
    let annotation = WorkoutAnnotation(muscles: [.back, .glutes], effort: 8, gymID: gym.id, notes: "Deadlifts")
    XCTAssertTrue(journal.save(annotation, for: session))
    let reloaded = WorkoutJournal(url: url)
    XCTAssertEqual(reloaded.annotations[session.id], annotation)
    XCTAssertEqual(reloaded.gyms.first?.name, "My gym")
    XCTAssertEqual(reloaded.visits.count, 1)
    reloaded.deleteGym(gym)
    XCTAssertNil(reloaded.annotations[session.id]?.gymID)
    XCTAssertEqual(reloaded.annotations[session.id]?.effort, 8)
    XCTAssertTrue(reloaded.visits.isEmpty)
  }

  @MainActor
  func testCorruptJournalIsPreserved() throws {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: url) }
    let original = Data("invalid journal".utf8)
    try original.write(to: url)
    let journal = WorkoutJournal(url: url)
    XCTAssertNotNil(journal.storageError)
    XCTAssertFalse(journal.addGym(name: "Do not overwrite"))
    XCTAssertTrue(journal.gyms.isEmpty)
    XCTAssertEqual(try Data(contentsOf: url), original)
  }
}
