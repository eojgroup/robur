import XCTest
@testable import Robur

final class MetricAnalyticsTests: XCTestCase {
  private var calendar: Calendar { var value = Calendar(identifier: .gregorian); value.timeZone = TimeZone(secondsFromGMT: 0)!; return value }
  private func date(_ day: Int) -> Date { calendar.date(byAdding: .day, value: day, to: Date(timeIntervalSince1970: 1_767_225_600))! }
  private func readings(_ count: Int, _ value: (Int) -> Double) -> [AnalyticsReading] {
    (0..<count).map { .init(date: date($0), value: value($0)) }
  }
  func testComparisonUsesOnlyPriorDistinctDatesAndPreservesRawReadings() {
    let source = readings(9) { $0 < 7 ? 10 : $0 == 7 ? 20 : 1000 }
    let compared = MetricAnalytics.compare(source + [source[0]], scale: .percent, calendar: calendar)
    XCTAssertEqual(compared.count, 2)
    XCTAssertEqual(compared[0].baseline, 10)
    XCTAssertEqual(compared[0].value, 100)
    XCTAssertEqual(compared[0].observations, 7)
    XCTAssertEqual(compared[1].baseline, 11.25)
    XCTAssertEqual(MetricAnalytics.compare(source, scale: .raw, calendar: calendar).map(\.value), source.map(\.value))
  }
  func testCalendarWindowAndFlatBaselinesDoNotInventObservations() {
    let source = readings(40) { $0 == 39 ? 20 : 10 }
    XCTAssertEqual(MetricAnalytics.compare(source, scale: .percent, calendar: calendar).last?.observations, 30)
    XCTAssertTrue(MetricAnalytics.compare(readings(8) { _ in 0 }, scale: .percent, calendar: calendar).isEmpty)
    XCTAssertEqual(MetricAnalytics.compare(readings(8) { _ in 10 }, scale: .zScore, calendar: calendar).first?.value, 0)
    XCTAssertTrue(MetricAnalytics.compare(readings(8) { $0 == 7 ? 20 : 10 }, scale: .zScore, calendar: calendar).isEmpty)
    XCTAssertTrue(MetricAnalytics.compare(readings(8) { $0 == 0 ? .nan : 10 }, scale: .percent, calendar: calendar).isEmpty)
  }
  func testLaggedCorrelationPairsDatesRatherThanPositions() {
    let a = readings(20) { Double($0) }, b = readings(20) { Double(($0 - 1) * 2) }
    let pairs = MetricAnalytics.paired(a + [a[0]], b, lagDays: 1, calendar: calendar)
    XCTAssertEqual(pairs.count, 19)
    XCTAssertEqual(MetricAnalytics.correlation(pairs), 1)
    XCTAssertNil(MetricAnalytics.correlation(Array(pairs.prefix(13))))
    XCTAssertNil(MetricAnalytics.correlation(MetricAnalytics.paired(a, readings(20) { _ in 2 }, lagDays: 0, calendar: calendar)))
    XCTAssertTrue(MetricAnalytics.paired(a, b, lagDays: 31, calendar: calendar).isEmpty)
  }
  func testAppleEffortUsesCompletionDayAndMissingSignalsDoNotProduceFlags() {
    let now = date(3)
    let workout = WorkoutRecord(id: "overnight", start: date(0).addingTimeInterval(23 * 3600), end: date(1).addingTimeInterval(3600),
      title: "Run", symbol: "figure.run", minutes: 120, distanceKm: 15, energyKcal: nil, averageHeartRate: nil,
      source: "Apple", appleEffort: 8, activityType: .running)
    let analysis = RecoveryInsights.make(days: [], workouts: [workout], annotations: [:], maxHR: 190, now: now, calendar: calendar)
    let series = MetricAnalytics.series(days: [], workouts: [workout, workout], analysis: analysis, now: now, calendar: calendar)
    XCTAssertEqual(series[.appleLoad], [.init(date: date(1), value: 960)])
    let flags = MetricAnalytics.highlights(series: series, workouts: [workout], analysis: analysis, now: now, calendar: calendar)
    XCTAssertEqual(flags.filter { $0.kind == .effort }.count, 1)
    XCTAssertFalse(flags.contains { $0.kind == .signals || $0.kind == .recovery })
    XCTAssertNil(analysis.score)
  }
}
