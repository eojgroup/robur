import XCTest
@testable import Robur

final class HealthSyncTests: XCTestCase {
  private let now = Date(timeIntervalSince1970: 1_800_000_000)

  func testExportPreservesMissingValuesAndRequiresSeparateDetailedConsent() throws {
    let day = DailyHealthMetrics(date: now, steps: 9000, restingHR: .nan, hrv: 60)
    let workout = WorkoutRecord(id: "workout", start: now.addingTimeInterval(-3600), end: now,
      title: "Run", symbol: "figure.run", minutes: 60, distanceKm: 10, energyKcal: nil,
      averageHeartRate: 145, source: "Health", heartRateSamples: [.init(date: now, bpm: 145)], activityType: .running)
    let analysis = RecoveryInsights.make(days: [day], workouts: [workout], annotations: [:], maxHR: 190, now: now)
    let reviews = ["workout": WorkoutAnnotation(muscles: [.core], notes: "Private note")]
    let basic = try HealthSyncExport.make(days: [day], workouts: [workout], readings: [], annotations: reviews,
      analysis: analysis, includeReviews: false, includeDetails: false, now: now)
    let daily = try XCTUnwrap(basic.first { $0.kind == "daily" })
    XCTAssertNil(daily.data["sleepMinutes"])
    XCTAssertNil(daily.data["restingHR"])
    XCTAssertEqual(daily.data["steps"], .number(9000))
    XCTAssertNil(basic.first { $0.kind == "workout" }?.data["review"])
    XCTAssertFalse(basic.contains { $0.kind == "quantity" })
    let detailed = try HealthSyncExport.make(days: [day], workouts: [workout], readings: [], annotations: reviews,
      analysis: analysis, includeReviews: true, includeDetails: true, now: now)
    XCTAssertNotNil(detailed.first { $0.kind == "workout" }?.data["review"])
    XCTAssertEqual(detailed.filter { $0.kind == "quantity" }.count, 1)
    XCTAssertEqual(basic.first { $0.kind == "score" }?.data["methodologyVersion"], .string(RecoveryAnalysis.version))
    XCTAssertNoThrow(try HealthSyncBatch.encoder().encode(HealthSyncBatch(sourceDeviceId: "device", capturedAt: now, records: detailed)))
  }

  func testBatchesBoundCountAndEncodedBytesWithoutDroppingRecords() throws {
    let records = (0..<1001).map { HealthSyncRecord(kind: "fitness", id: "sample-\($0)", observedAt: now, data: ["value": .number(Double($0))]) }
    let batches = try HealthSyncBatch.split(records, sourceDeviceId: "device", now: now)
    XCTAssertEqual(batches.map { $0.records.count }, [500, 500, 1])
    XCTAssertEqual(batches.flatMap(\.records), records)
    let smaller = try HealthSyncBatch.split(records, sourceDeviceId: "device", now: now, maxBytes: 5000)
    XCTAssertTrue(try smaller.allSatisfy { try HealthSyncBatch.encoder().encode($0).count <= 5000 })
    XCTAssertTrue(try HealthSyncBatch.split([], sourceDeviceId: "device").isEmpty)
  }

  @MainActor
  func testSyncOriginRejectsCleartextCredentialsPathsAndQueries() {
    for address in ["http://robur.fit", "https://", "https://user:password@robur.fit", "https://robur.fit/api", "https://robur.fit?token=secret"] {
      XCTAssertThrowsError(try CloudHealthSync.origin(address))
    }
    XCTAssertNoThrow(try CloudHealthSync.origin("https://robur.fit"))
  }
}
