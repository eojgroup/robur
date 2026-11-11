import SwiftUI
import WidgetKit

struct RoburWidgetEntry: TimelineEntry {
  let date: Date
  let summary: WidgetHealthSummary
}
struct RoburHealthProvider: TimelineProvider {
  func placeholder(in context: Context) -> RoburWidgetEntry { RoburWidgetEntry(date: Date(), summary: WidgetHealthSummary(refreshedAt: Date())) }
  func getSnapshot(in context: Context, completion: @escaping (RoburWidgetEntry) -> Void) {
    if context.isPreview { completion(placeholder(in: context)); return }
    Task { let data = await WidgetHealthReader().read(); completion(RoburWidgetEntry(date: Date(), summary: data)) }
  }
  func getTimeline(in context: Context, completion: @escaping (Timeline<RoburWidgetEntry>) -> Void) {
    Task {
      let data = await WidgetHealthReader().read()
      let now = Date()
      // A later entry hides expired values even if the system delays the next refresh.
      let expired = now.addingTimeInterval(3_601)
      completion(Timeline(entries: [RoburWidgetEntry(date: now, summary: data), RoburWidgetEntry(date: expired, summary: data)],
        policy: .after(now.addingTimeInterval(900))))
    }
  }
}

private enum WidgetMetric: Equatable { case recovery, training, cardio }
private struct RoburHealthWidgetView: View {
  let entry: RoburWidgetEntry
  let metric: WidgetMetric
  @Environment(\.widgetFamily) private var family
  private var orange: Color { MetricColors.color(metric == .recovery ? "recovery" : metric == .training ? "acuteLoad" : "cardio", scheme: .dark) }
  private var title: String { switch metric { case .recovery: return "Recovery signals"; case .training: return "Training · 7 days"; case .cardio: return "Cardio fitness" } }
  private var symbol: String { switch metric { case .recovery: return "heart.circle"; case .training: return "figure.run"; case .cardio: return "waveform.path.ecg" } }
  private var stale: Bool { entry.summary.isStale(at: entry.date) }
  private var value: String {
    guard !stale else { return "—" }
    switch metric {
    case .recovery: return entry.summary.recovery.map(String.init) ?? "—"
    case .training: return entry.summary.trainingMinutes.map { $0.formatted(.number.precision(.fractionLength(0))) } ?? "—"
    case .cardio: return entry.summary.cardioFitness.map { $0.formatted(.number.precision(.fractionLength(1))) } ?? "—"
    }
  }
  private var unit: String { switch metric { case .recovery: return "/ 100 estimate"; case .training: return "minutes"; case .cardio: return "mL/kg/min" } }
  var body: some View {
    content
      .privacySensitive()
      .containerBackground(for: .widget) { Color(red: 0.055, green: 0.10, blue: 0.18) }
      .widgetURL(URL(string: metric == .training ? "robur://progress" : "robur://today"))
  }
  @ViewBuilder private var content: some View {
    switch family {
    case .accessoryInline:
      Label("\(title): \(value)", systemImage: symbol)
    case .accessoryCircular:
      if metric == .recovery, let score = entry.summary.recovery, !stale {
        Gauge(value: Double(score), in: 0...100) { Image(systemName: symbol) } currentValueLabel: { Text(value) }
          .gaugeStyle(.accessoryCircular).tint(orange)
      } else { VStack { Image(systemName: symbol); Text(value).font(.headline) } }
    case .accessoryRectangular:
      VStack(alignment: .leading) {
        Label(title, systemImage: symbol).font(.caption)
        Text("\(value) \(unit)").font(.headline)
        Text(stale ? "Open Robur to refresh" : entry.summary.refreshedAt.formatted(date: .omitted, time: .shortened)).font(.caption2)
      }
    default:
      VStack(alignment: .leading, spacing: 8) {
        Label(title, systemImage: symbol).font(.caption.weight(.semibold)).foregroundStyle(orange)
        HStack(alignment: .firstTextBaseline) {
          Text(value).font(.system(size: 36, weight: .bold, design: .rounded)).minimumScaleFactor(0.6)
          Text(unit).font(.caption).foregroundStyle(.secondary)
        }
        if !entry.summary.hasData || stale {
          Text(stale ? "Open Robur to refresh" : "Open Robur for Health data").font(.caption)
        } else {
          if metric == .recovery, let sleep = entry.summary.sleepMinutes {
            Text("Sleep \(sleep / 60, specifier: "%.1f") h").font(.caption)
          }
          if metric == .training, let count = entry.summary.workoutCount {
            Text("\(count) sessions").font(.caption)
          }
          if metric == .cardio, let date = entry.summary.cardioDate {
            Text(date, style: .date).font(.caption)
          }
          #if os(iOS)
          if family == .systemMedium || family == .systemLarge {
            HStack {
              if let steps = entry.summary.steps { Label("\(steps.formatted(.number.precision(.fractionLength(0)))) steps", systemImage: "figure.walk") }
              if metric != .recovery, let score = entry.summary.recovery { Label("\(score) recovery", systemImage: "heart") }
            }.font(.caption)
          }
          #endif
          Text("Updated \(entry.summary.refreshedAt.formatted(date: .omitted, time: .shortened))").font(.caption2).foregroundStyle(.secondary)
        }
      }.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        .foregroundStyle(Color(red: 0.96, green: 0.92, blue: 0.84))
    }
  }
}

private var roburWidgetFamilies: [WidgetFamily] {
  #if os(watchOS)
  [.accessoryCircular, .accessoryRectangular, .accessoryInline]
  #else
  [.systemSmall, .systemMedium, .systemLarge, .accessoryCircular, .accessoryRectangular, .accessoryInline]
  #endif
}
struct RoburRecoveryWidget: Widget {
  let kind = "RoburRecovery"
  var body: some WidgetConfiguration {
    StaticConfiguration(kind: kind, provider: RoburHealthProvider()) { RoburHealthWidgetView(entry: $0, metric: .recovery) }
      .configurationDisplayName("Recovery").description("Sleep and heart signals relative to your personal baseline.")
      .supportedFamilies(roburWidgetFamilies)
  }
}
struct RoburTrainingWidget: Widget {
  let kind = "RoburTraining"
  var body: some WidgetConfiguration {
    StaticConfiguration(kind: kind, provider: RoburHealthProvider()) { RoburHealthWidgetView(entry: $0, metric: .training) }
      .configurationDisplayName("Training week").description("Recent training minutes and current recovery context.")
      .supportedFamilies(roburWidgetFamilies)
  }
}
struct RoburFitnessWidget: Widget {
  let kind = "RoburFitness"
  var body: some WidgetConfiguration {
    StaticConfiguration(kind: kind, provider: RoburHealthProvider()) { RoburHealthWidgetView(entry: $0, metric: .cardio) }
      .configurationDisplayName("Cardio fitness").description("Your latest recorded cardio fitness and activity.")
      .supportedFamilies(roburWidgetFamilies)
  }
}
@main struct RoburWidgetBundle: WidgetBundle {
  var body: some Widget { RoburRecoveryWidget(); RoburTrainingWidget(); RoburFitnessWidget() }
}
