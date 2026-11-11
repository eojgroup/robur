import XCTest
@testable import Robur

final class TrainingAnalysisWorkerTests: XCTestCase {
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
