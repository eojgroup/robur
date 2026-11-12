import XCTest
@testable import Robur

final class TrainingAnalysisWorkerTests: XCTestCase {
  func testDecadeChartPreparationPreservesRawHistoryAndBoundsRenderedPoints() async throws {
    var calendar = Calendar(identifier: .gregorian); calendar.timeZone = TimeZone(secondsFromGMT: 0)!
    let now = Date(timeIntervalSince1970: 1_800_000_000)
    let readings = (0..<3650).map { index in AnalyticsReading(date: calendar.date(byAdding: .day, value: -index, to: now)!, value: 420 + Double(index % 30)) }
    let start = calendar.date(byAdding: .day, value: -3650, to: now)!
    let prepared = try await TrainingAnalysisWorker().charts(series: [.sleep: readings], history: [], metrics: [.sleep],
      scale: .percent, start: start, grain: .month, fitness: false, x: .sleep, y: .sleep, lag: 0, calendar: calendar)
    XCTAssertEqual(readings.count, 3650)
    XCTAssertLessThanOrEqual(prepared.points.count, 121)
    XCTAssertEqual(Set(prepared.points.map(\.id)).count, prepared.points.count)
    XCTAssertTrue(prepared.points.allSatisfy { $0.value.isFinite })
    XCTAssertEqual(prepared.pairs.count, 3650)
    XCTAssertEqual(prepared.correlation ?? 0, 1, accuracy: 0.000000001)
  }
  func testBackgroundAnalysisPreservesScoresAndDoesNotReuseAnotherDaysSnapshot() async throws {
    let calendar = Calendar.current
    let today = calendar.startOfDay(for: Date())
    let now = today.addingTimeInterval(-10)
    let days = (1...800).map { DailyHealthMetrics(date: calendar.date(byAdding: .day, value: -$0, to: today)!,
      sleepMinutes: 460, steps: 8500, exerciseMinutes: 35, restingHR: 55, hrv: 60, vo2Max: 45) }
    let request = TrainingAnalysisRequest(days: days, workouts: [], annotations: [:], maxHR: 190)
    let worker = TrainingAnalysisWorker()
    let first = try await worker.make(request, now: now)
    let direct = TrainingInsights.make(days: days, workouts: [], annotations: [:], maxHR: 190, now: now)
    XCTAssertEqual(first.recoveryAnalysis, direct.recoveryAnalysis)
    let nextDay = try await worker.make(request, now: today.addingTimeInterval(5))
    XCTAssertEqual(nextDay.recoveryAnalysis.date, today)
    XCTAssertNotEqual(first.recoveryAnalysis.date, nextDay.recoveryAnalysis.date)
    let analytics = try await worker.analytics(request, now: today.addingTimeInterval(5))
    XCTAssertEqual(analytics.analysis, nextDay.recoveryAnalysis)
    XCTAssertEqual(analytics.readings[.sleep]?.count, 800)
  }
}
