import Foundation

struct AnalyticsPlotPoint: Identifiable, Sendable {
  var id: String { "\(metric.rawValue)-\(date.timeIntervalSince1970)" }
  let metric: AnalyticsMetric
  let date: Date
  let value: Double
  let segment: Int
}
struct AnalyticsContribution: Identifiable, Sendable {
  var id: String { title }
  let title: String
  let value: Double
}
struct AnalyticsScorePlot: Identifiable, Sendable {
  var id: Date { date }
  let date: Date
  let score: Double
  let parts: [AnalyticsContribution]
}
struct AnalyticsChartData: Sendable {
  var points: [AnalyticsPlotPoint] = []
  var scores: [AnalyticsScorePlot] = []
  var pairs: [AnalyticsPair] = []
  var correlation: Double? = nil
}

extension TrainingAnalysisWorker {
  /// Prepare geometry only when inputs/settings change, never while scrubbing.
  func charts(series: [AnalyticsMetric: [AnalyticsReading]], history: [RecoveryHistoryPoint],
              metrics: [AnalyticsMetric], scale: AnalyticsScale, start: Date, grain: Calendar.Component?,
              fitness: Bool, x: AnalyticsMetric, y: AnalyticsMetric, lag: Int,
              calendar: Calendar = .current) throws -> AnalyticsChartData {
    try Task.checkCancellation()
    var result = AnalyticsChartData()
    for metric in metrics {
      try Task.checkCancellation()
      let values = MetricAnalytics.compare(series[metric] ?? [], scale: scale, calendar: calendar).filter { $0.date >= start }
      var grouped: [AnalyticsReading] = []
      if let grain {
        let buckets = Dictionary(grouping: values) { calendar.dateInterval(of: grain, for: $0.date)?.start ?? $0.date }
        for date in buckets.keys.sorted() {
          let bucket = buckets[date]!
          grouped.append(.init(date: date, value: bucket.reduce(0) { $0 + $1.value } / Double(bucket.count)))
        }
      } else { grouped = values.map { .init(date: $0.date, value: $0.value) } }
      var segment = 0, previous: Date?
      let maxGap = grain == .month ? 40 : grain == .weekOfYear ? 9 : 2
      for point in grouped {
        if let previous, (calendar.dateComponents([.day], from: previous, to: point.date).day ?? 0) > maxGap { segment += 1 }
        result.points.append(.init(metric: metric, date: point.date, value: point.value, segment: segment))
        previous = point.date
      }
    }
    let eligible = history.filter { $0.date >= start && (fitness ? $0.fitness : $0.recovery) != nil }
    let buckets = Dictionary(grouping: eligible) { point in grain.flatMap { calendar.dateInterval(of: $0, for: point.date)?.start } ?? point.date }
    result.scores = buckets.keys.sorted().map { date in
      let bucket = buckets[date]!, count = Double(bucket.count)
      var values: [String: Double] = [:], total = 0.0
      for point in bucket {
        total += Double((fitness ? point.fitness : point.recovery) ?? 0)
        for part in fitness ? point.fitnessComponents : point.recoveryComponents { values[part.title, default: 0] += part.contribution }
      }
      return AnalyticsScorePlot(date: date, score: total / count,
        parts: values.keys.sorted().map { AnalyticsContribution(title: $0, value: values[$0]! / count) })
    }
    result.pairs = MetricAnalytics.paired(series[x] ?? [], series[y] ?? [], lagDays: lag, calendar: calendar).filter { $0.date >= start }
    result.correlation = MetricAnalytics.correlation(result.pairs)
    try Task.checkCancellation()
    return result
  }
}
