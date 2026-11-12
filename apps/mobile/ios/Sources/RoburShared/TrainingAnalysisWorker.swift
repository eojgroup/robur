import Foundation

struct TrainingAnalysisRequest: Equatable, Sendable {
  let days: [DailyHealthMetrics]
  let workouts: [WorkoutRecord]
  let annotations: [String: WorkoutAnnotation]
  let maxHR: Double
  var stepsGoal = 8_000.0
  var exerciseGoal = 30.0
  var historyStart: Date? = nil
  var fitnessReference: FitnessReference? = nil
}
struct TrainingAnalyticsSnapshot: Sendable {
  let analysis: RecoveryAnalysis
  let readings: [AnalyticsMetric: [AnalyticsReading]]
  let highlights: [AnalyticsHighlight]
  let readingsByDate: [AnalyticsMetric: [Date: Double]]
  let scoresByDate: [Date: RecoveryHistoryPoint]
}

/// Serializes expensive history work off the UI actor. Neighbouring screens
/// share the same snapshot instead of recomputing it for each published field.
actor TrainingAnalysisWorker {
  static let shared = TrainingAnalysisWorker()
  private var cachedRequest: TrainingAnalysisRequest?
  private var cachedSummary: InsightsSummary?
  private var calculatedAt: Date?

  func make(_ request: TrainingAnalysisRequest, now: Date = Date()) throws -> InsightsSummary {
    try Task.checkCancellation()
    if cachedRequest == request, let cachedSummary, let calculatedAt,
       now >= calculatedAt, now.timeIntervalSince(calculatedAt) < 30,
       Calendar.current.isDate(now, inSameDayAs: calculatedAt) {
      return cachedSummary
    }
    let result = TrainingInsights.make(days: request.days, workouts: request.workouts, annotations: request.annotations,
      maxHR: request.maxHR, now: now, stepsGoal: request.stepsGoal, exerciseGoal: request.exerciseGoal,
      historyStart: request.historyStart, fitnessReference: request.fitnessReference)
    try Task.checkCancellation()
    cachedRequest = request; cachedSummary = result; calculatedAt = now
    return result
  }

  func analytics(_ request: TrainingAnalysisRequest, now: Date = Date()) throws -> TrainingAnalyticsSnapshot {
    let analysis = try make(request, now: now).recoveryAnalysis
    let series = MetricAnalytics.series(days: request.days, workouts: request.workouts, analysis: analysis, now: now)
    let highlights = MetricAnalytics.highlights(series: series, workouts: request.workouts, analysis: analysis, now: now)
    try Task.checkCancellation()
    return .init(analysis: analysis, readings: series, highlights: highlights,
      readingsByDate: series.mapValues { Dictionary($0.map { ($0.date, $0.value) }, uniquingKeysWith: { _, latest in latest }) },
      scoresByDate: Dictionary(analysis.history.map { ($0.date, $0) }, uniquingKeysWith: { _, latest in latest }))
  }
}
