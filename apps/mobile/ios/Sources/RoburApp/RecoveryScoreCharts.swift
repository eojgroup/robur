import Charts
import SwiftUI

enum RecoveryChartVariation: String, CaseIterable, Identifiable {
  case history = "Score history", components = "Contributions", load = "Load response", relationship = "Load / recovery", coverage = "Data coverage"
  var id: String { rawValue }
}

struct RecoveryScoreCharts: View {
  let analysis: RecoveryAnalysis
  let isFitness: Bool
  let range: HistoryRange
  let variation: RecoveryChartVariation
  let height: CGFloat
  @Binding var selectedDate: Date?

  private var components: [RecoveryScoreComponent] { isFitness ? analysis.fitnessComponents : analysis.recoveryComponents }
  private var points: [RecoveryHistoryPoint] {
    let start = range.startDate() ?? analysis.history.first?.date ?? Date()
    return analysis.history.filter { $0.date >= Calendar.current.startOfDay(for: start) }
  }
  private var domain: ClosedRange<Date> {
    let start = points.first?.date ?? Date().addingTimeInterval(-86_400)
    return start...max(Date(), start.addingTimeInterval(86_400))
  }
  private var sampled: [RecoveryHistoryPoint] {
    guard points.count > 400 else { return points }
    // Preserve daily minima/maxima? No: sample the last observation in each
    // weekly/monthly bucket and label that explicitly instead of fabricating means.
    let component: Calendar.Component = points.count > 1_500 ? .month : .weekOfYear
    let groups = Dictionary(grouping: points) { Calendar.current.dateInterval(of: component, for: $0.date)?.start ?? $0.date }
    return groups.values.compactMap { $0.last }.sorted { $0.date < $1.date }
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      header
      switch variation {
      case .history: scoreHistory
      case .components: contributionChart
      case .load: loadResponse
      case .relationship: relationship
      case .coverage: coverageChart
      }
      if points.count > 400 && (variation == .history || variation == .load || variation == .coverage) {
        Text(points.count > 1_500 ? "Monthly last recorded scores · underlying daily data retained" : "Weekly last recorded scores · underlying daily data retained")
          .font(.caption2).foregroundStyle(.secondary)
      }
    }
  }

  private var header: some View {
    HStack(alignment: .firstTextBaseline) {
      VStack(alignment: .leading, spacing: 3) {
        Text(isFitness ? "Fitness score" : "Recovery & readiness").font(.headline)
        Text(isFitness ? "Cardio, movement, consistency and strength participation" : "Autonomic signals, sleep and recent training demand")
          .font(.caption).foregroundStyle(.secondary)
      }
      Spacer()
      Text((isFitness ? analysis.fitnessScore : analysis.score).map { "\($0)" } ?? "—")
        .font(.system(.largeTitle, design: .rounded, weight: .bold)).foregroundStyle(MetricColors.color(isFitness ? "fitness" : "recovery"))
    }
  }

  private var scoreHistory: some View {
    let valid = sampled.filter { (isFitness ? $0.fitness : $0.recovery) != nil }
    var segment = 0
    var segments: [Date: Int] = [:]
    for point in sampled {
      if (isFitness ? point.fitness : point.recovery) == nil { segment += 1 }
      else { segments[point.date] = segment }
    }
    return Group {
      if valid.isEmpty { empty("More recorded days and independent signals are needed.") }
      else {
        Chart {
          ForEach(valid) { point in
            LineMark(x: .value("Date", point.date), y: .value("Score", isFitness ? point.fitness ?? 0 : point.recovery ?? 0),
              series: .value("Recorded segment", segments[point.date] ?? 0))
              .foregroundStyle(MetricColors.color(isFitness ? "fitness" : "recovery")).lineStyle(StrokeStyle(lineWidth: 2.5))
            PointMark(x: .value("Date", point.date), y: .value("Score", isFitness ? point.fitness ?? 0 : point.recovery ?? 0))
              .foregroundStyle(MetricColors.color(isFitness ? "fitness" : "recovery")).symbolSize(points.count > 400 ? 20 : 13)
              .accessibilityLabel(point.date.formatted(date: .abbreviated, time: .omitted))
              .accessibilityValue("\(isFitness ? point.fitness ?? 0 : point.recovery ?? 0) out of 100")
          }
          if let selectedDate { RuleMark(x: .value("Selected date", selectedDate)).foregroundStyle(.secondary) }
        }.chartXScale(domain: domain).chartYScale(domain: 0...100).chartYAxisLabel("score / 100")
          .chartXSelection(value: $selectedDate).frame(height: height)
      }
    }
  }

  private var contributionChart: some View {
    VStack(alignment: .leading, spacing: 10) {
      if components.isEmpty { empty("No eligible components yet.") }
      else {
        Chart(components) { item in
          BarMark(x: .value("Score points", item.contribution), y: .value("Component", item.title))
            .foregroundStyle(MetricColors.color(item.key).gradient).cornerRadius(3)
            .annotation(position: .trailing) { Text(String(format: "%.1f", item.contribution)).font(.caption2).monospacedDigit() }
        }.chartXAxisLabel("weighted points toward the overall score").frame(height: max(height, CGFloat(components.count) * 40))
        ForEach(components) { item in
          HStack {
            Text(item.title)
            Spacer()
            Text("\(item.score)/100 × \(Int((item.effectiveWeight * 100).rounded()))%")
          }.font(.caption).monospacedDigit()
        }
        Text("Effective weights total 100% across eligible inputs. Missing inputs are excluded; coverage shows what is missing.")
          .font(.caption2).foregroundStyle(.secondary)
      }
    }
  }

  private var loadResponse: some View {
    VStack(alignment: .leading, spacing: 8) {
      Chart(sampled) { point in
        if let acute = point.acuteLoad {
          LineMark(x: .value("Date", point.date), y: .value("Load", acute), series: .value("Smoothing", "7 days"))
            .foregroundStyle(by: .value("Smoothing", "7 days"))
        }
        if let chronic = point.chronicLoad {
          LineMark(x: .value("Date", point.date), y: .value("Load", chronic), series: .value("Smoothing", "42 days"))
            .foregroundStyle(by: .value("Smoothing", "42 days"))
        }
      }.chartXScale(domain: domain).chartForegroundStyleScale(["7 days": MetricColors.color("acuteLoad"), "42 days": MetricColors.color("chronicLoad")])
        .chartYAxisLabel("AU/day").chartXSelection(value: $selectedDate).frame(height: height * 0.6)
      scoreHistory.frame(maxHeight: height * 0.6)
      Text("Observed session demand, exponentially smoothed over 7/42 days. These are descriptive load proxies; they do not predict injury or establish safe training thresholds.")
        .font(.caption2).foregroundStyle(.secondary)
    }
  }

  private var relationship: some View {
    let valid = points.filter { $0.recovery != nil && $0.acuteLoad != nil }
    return VStack(alignment: .leading, spacing: 8) {
      if valid.isEmpty { empty("Recovery scores and established load history are both needed.") }
      else {
        Chart(valid) { point in
          PointMark(x: .value("7-day smoothed load", point.acuteLoad ?? 0), y: .value("Recovery", point.recovery ?? 0))
            .foregroundStyle(RoburStyle.orange.opacity(0.55)).symbolSize(24)
            .accessibilityLabel(point.date.formatted(date: .abbreviated, time: .omitted))
        }.chartXScale(domain: .automatic(includesZero: true)).chartYScale(domain: 0...100)
          .chartXAxisLabel("7-day smoothed observed load · AU/day").chartYAxisLabel("recovery / 100").frame(height: height)
        Text("One point per recorded date. An association between load and recovery is not proof of cause.")
          .font(.caption2).foregroundStyle(.secondary)
      }
    }
  }

  private var coverageChart: some View {
    VStack(alignment: .leading, spacing: 8) {
      Chart(sampled) { point in
        BarMark(x: .value("Date", point.date), y: .value("Coverage", point.coverage * 100))
          .foregroundStyle(RoburStyle.blue.gradient)
      }.chartXScale(domain: domain).chartYScale(domain: 0...100).chartYAxisLabel("eligible weight %")
        .chartXSelection(value: $selectedDate).frame(height: height)
      Text("\(analysis.confidence) · \(analysis.baselineDays) baseline days · \(Int((analysis.coverage * 100).rounded()))% of configured recovery inputs available. Coverage is not a statistical confidence interval.")
        .font(.caption).foregroundStyle(.secondary)
    }
  }

  private func empty(_ text: String) -> some View {
    ContentUnavailableView("Building your baseline", systemImage: "chart.xyaxis.line", description: Text(text))
      .frame(height: height)
  }
}
