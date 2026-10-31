import XCTest
@testable import Robur

final class WorkoutRecordingTests: XCTestCase {
  func testClockExcludesMultiplePausesAndSurvivesRecovery() throws {
    let start = Date(timeIntervalSince1970: 1_000)
    var clock = WorkoutRecordingClock(startedAt: start)
    clock.pause(at: start.addingTimeInterval(60))
    clock.pause(at: start.addingTimeInterval(70))
    XCTAssertEqual(clock.elapsed(asOf: start.addingTimeInterval(120)), 60)
    clock.resume(at: start.addingTimeInterval(120))
    clock.pause(at: start.addingTimeInterval(180))
    let recovered = try JSONDecoder().decode(WorkoutRecordingClock.self, from: JSONEncoder().encode(clock))
    XCTAssertEqual(recovered.elapsed(asOf: start.addingTimeInterval(500)), 120)
    clock.resume(at: start.addingTimeInterval(240))
    XCTAssertEqual(clock.elapsed(asOf: start.addingTimeInterval(300)), 180)
    XCTAssertEqual(clock.elapsed(asOf: start.addingTimeInterval(-10)), 0)
  }

  func testMotionRequiresSustainedActivityAndRespectsCooldown() {
    let start = Date(timeIntervalSince1970: 1_000)
    var gate = WorkoutSuggestionGate()
    gate.observe(.running, at: start)
    XCTAssertNil(gate.suggestion(at: start.addingTimeInterval(59)))
    XCTAssertEqual(gate.suggestion(at: start.addingTimeInterval(60)), .running)
    XCTAssertNil(gate.suggestion(at: start.addingTimeInterval(120)))
    gate.resetObservation()
    gate.observe(.cycling, at: start.addingTimeInterval(120))
    XCTAssertNil(gate.suggestion(at: start.addingTimeInterval(181)))
    XCTAssertEqual(gate.suggestion(at: start.addingTimeInterval(1860)), .cycling)
  }

  func testInterruptedMotionDoesNotCountAsContinuousAndUnsupportedTypesNeverSuggest() {
    let start = Date(timeIntervalSince1970: 1_000)
    var gate = WorkoutSuggestionGate()
    gate.observe(.running, at: start)
    gate.observe(nil, at: start.addingTimeInterval(30))
    gate.observe(.running, at: start.addingTimeInterval(50))
    XCTAssertNil(gate.suggestion(at: start.addingTimeInterval(70)))
    gate.observe(.functionalStrength, at: start.addingTimeInterval(80))
    XCTAssertNil(gate.suggestion(at: start.addingTimeInterval(500)))
  }

  func testReviewQueueExcludesOldFutureTaggedAndExplicitlyReviewedSessions() {
    let now = Date(timeIntervalSince1970: 2_000_000)
    func workout(_ id: String, ago: TimeInterval) -> WorkoutRecord {
      let end = now.addingTimeInterval(-ago)
      return WorkoutRecord(id: id, start: end.addingTimeInterval(-1800), end: end,
        title: "Run", symbol: "figure.run", minutes: 30, distanceKm: nil, energyKcal: nil,
        averageHeartRate: nil, source: "Test")
    }
    let records = [workout("old", ago: 8 * 86400), workout("future", ago: -3600),
      workout("tagged", ago: 300), workout("reviewed", ago: 200), workout("pending", ago: 100)]
    let annotations = ["tagged": WorkoutAnnotation(muscles: [.back])]
    XCTAssertEqual(WorkoutReviewPolicy.pending(workouts: records, annotations: annotations,
      reviewedIDs: ["reviewed"], now: now).map(\.id), ["pending"])
  }

  func testRecordingMetadataUsesHealthKitSupportedStringValuesAndRoundTripsTags() {
    let metadata = WorkoutRecordingMetadata.dictionary(muscles: [.back, .glutes], notes: "  Good session  ")
    XCTAssertTrue(metadata.values.allSatisfy { $0 is String })
    XCTAssertEqual(WorkoutRecordingMetadata.muscles(in: metadata), [.back, .glutes])
    XCTAssertEqual(WorkoutRecordingMetadata.notes(in: metadata), "Good session")
  }
}
