import Charts
import SwiftUI

/// Calendar contents stay transient. A linked Robur event is represented by its
/// editable plan once, and warnings describe real time intersections only.
@MainActor
struct TrainingCalendarView: View {
  let week: DateInterval
  let events: [TrainingCalendarEvent]
  let entries: [PlanEntry]
  let isLoading: Bool
  let error: String?
  let calendarAccess: Bool
  let onEdit: (UUID) -> Void
  let onConnect: () -> Void
  var onSelectDay: ((Date) -> Void)? = nil
  var selection: Binding<Date?>? = nil
  @State private var selectedDay: Date?
  @Environment(\.dynamicTypeSize) private var dynamicType
  @ScaledMetric(relativeTo: .caption) private var bandHeight = 36.0
  @ScaledMetric(relativeTo: .caption) private var headerHeight = 40.0

  private var days: [Date] {
    (0..<7).compactMap { Calendar.current.date(byAdding: .day, value: $0, to: week.start) }
  }
  private var day: Date {
    let chosen = selection.map { $0.wrappedValue } ?? selectedDay
    if let chosen, chosen >= week.start && chosen < week.end { return chosen }
    let today = Calendar.current.startOfDay(for: Date())
    return today >= week.start && today < week.end ? today : week.start
  }
  private var dayInterval: DateInterval {
    Calendar.current.dateInterval(of: .day, for: day) ?? DateInterval(start: day, duration: 86_400)
  }
  private var weekPlans: [PlanEntry] {
    entries.filter { $0.isValid && intersects($0.startDate, $0.endDate, week) }
  }
  private var externalEvents: [TrainingCalendarEvent] {
    let represented = Set(weekPlans.map(\.id))
    return events.filter { event in
      event.isValid && intersects(event.startDate, event.endDate, week) &&
        !(event.linkedPlanID.map { represented.contains($0) } ?? false)
    }
  }
  private var dayPlans: [PlanEntry] { weekPlans.filter { intersects($0.startDate, $0.endDate, dayInterval) } }
  private var dayEvents: [TrainingCalendarEvent] { externalEvents.filter { intersects($0.startDate, $0.endDate, dayInterval) } }
  private var overlapPlans: [PlanEntry] {
    dayPlans.filter { entryOverlaps($0, in: dayInterval) }
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 16) {
      HStack {
        Label("Calendar & training", systemImage: "calendar").font(.headline)
        Spacer()
        if isLoading { ProgressView().accessibilityLabel("Reading Calendar") }
      }
      if !calendarAccess {
        Text("Connect Calendar to see existing events beside your training.").font(.callout).foregroundStyle(.secondary)
        Button("Connect Calendar", action: onConnect).buttonStyle(.bordered)
      }
      if let error { Text(error).font(.callout).foregroundStyle(.red) }
      weekGrid
      legend
      Divider()
      Text(day.formatted(.dateTime.weekday(.wide).day().month())).font(.headline)
      if !overlapPlans.isEmpty {
        Label("\(overlapPlans.count) training session\(overlapPlans.count == 1 ? " overlaps" : "s overlap"). You can still save and add to Calendar.",
          systemImage: "exclamationmark.triangle.fill")
          .font(.callout).foregroundStyle(RoburStyle.orange)
      }
      if !dayEvents.filter(\.isAllDay).isEmpty { allDayEvents }
      dayTimeline
      dayAgenda
    }
    .roburCard()
    .accessibilityIdentifier("calendar-training-overview")
    .onChange(of: week.start) { _, _ in selectedDay = nil }
  }

  private var weekGrid: some View {
    GeometryReader { geometry in
      ScrollView(.horizontal, showsIndicators: true) {
        VStack(spacing: 6) {
          HStack(spacing: 5) {
            Color.clear.frame(width: 44, height: headerHeight)
            ForEach(days, id: \.self) { date in dayHeader(date) }
          }
          ForEach(0..<4) { band in
            HStack(spacing: 5) {
              Text(String(format: "%02d–%02d", band * 6, (band + 1) * 6))
                .font(.caption2.monospacedDigit()).foregroundStyle(.secondary).frame(width: 44)
              ForEach(days, id: \.self) { date in occupancyCell(day: date, band: band) }
            }.frame(height: bandHeight)
          }
        }
        .frame(width: max(geometry.size.width, dynamicType.isAccessibilitySize ? 530 : 300))
      }
    }
    .frame(height: headerHeight + 4 * bandHeight + 4 * 6)
  }

  private func dayHeader(_ date: Date) -> some View {
    Button { select(date) } label: {
      VStack(spacing: 2) {
        Text(date.formatted(.dateTime.weekday(.narrow)))
        Text(date.formatted(.dateTime.day())).fontWeight(.semibold)
      }
      .font(.caption).frame(maxWidth: .infinity).frame(height: headerHeight)
      .background(Calendar.current.isDate(date, inSameDayAs: day) ? RoburStyle.orange.opacity(0.15) : .clear,
        in: RoundedRectangle(cornerRadius: 9))
    }
    .buttonStyle(.plain)
    .accessibilityLabel(date.formatted(date: .complete, time: .omitted))
    .accessibilityAddTraits(Calendar.current.isDate(date, inSameDayAs: day) ? .isSelected : [])
  }

  private func occupancyCell(day date: Date, band: Int) -> some View {
    let interval = bandInterval(on: date, band: band)
    let busy = externalEvents.filter { $0.blocksTime && intersects($0.startDate, $0.endDate, interval) }.count
    let planned = weekPlans.filter { intersects($0.startDate, $0.endDate, interval) }.count
    let overlap = hasOverlap(in: interval)
    return Button { select(date) } label: {
      VStack(spacing: 4) {
        Capsule().fill(busy > 0 ? RoburStyle.blue.opacity(0.7) : .clear).frame(height: 6)
        Capsule().fill(planned > 0 ? RoburStyle.orange : .clear).frame(height: 6)
      }
      .padding(.horizontal, 5).frame(maxWidth: .infinity).frame(height: bandHeight)
      .background(overlap ? Color.red.opacity(0.10) : RoburStyle.background, in: RoundedRectangle(cornerRadius: 7))
      .overlay(alignment: .topTrailing) {
        if overlap { Image(systemName: "exclamationmark.triangle.fill").font(.system(size: 9)).foregroundStyle(.red).padding(2) }
      }
    }
    .buttonStyle(.plain)
    .accessibilityLabel(date.formatted(.dateTime.weekday(.wide)) + ", \(band * 6) to \((band + 1) * 6) hours, \(busy) busy Calendar items, \(planned) Robur sessions" + (overlap ? ", overlap" : ""))
  }

  private var legend: some View {
    ViewThatFits(in: .horizontal) {
      HStack(spacing: 15) { legendItems }
      VStack(alignment: .leading, spacing: 7) { legendItems }
    }.font(.caption).foregroundStyle(.secondary)
  }
  @ViewBuilder private var legendItems: some View {
    Label { Text(calendarAccess ? "Calendar" : "Calendar unavailable") } icon: { Capsule().fill(RoburStyle.blue).frame(width: 13, height: 6) }
    Label { Text("Robur") } icon: { Capsule().fill(RoburStyle.orange).frame(width: 13, height: 6) }
    Label("Overlap", systemImage: "exclamationmark.triangle.fill").foregroundStyle(.red)
  }

  private var allDayEvents: some View {
    VStack(alignment: .leading, spacing: 5) {
      ForEach(dayEvents.filter(\.isAllDay)) { event in
        Label("All day · \(event.title) · \(event.calendarTitle)\(event.blocksTime ? "" : " · Free")", systemImage: "calendar")
          .font(.caption).foregroundStyle(.secondary)
      }
    }
  }

  private var dayTimeline: some View {
    Chart {
      ForEach(dayEvents.filter { !$0.isAllDay }) { event in
        BarMark(xStart: .value("Start", max(event.startDate, dayInterval.start)),
                xEnd: .value("End", min(event.endDate, dayInterval.end)), y: .value("Source", "Calendar"))
          .foregroundStyle(RoburStyle.blue.opacity(event.blocksTime ? 0.75 : 0.2))
          .cornerRadius(3)
          .accessibilityLabel(event.title)
          .accessibilityValue(timeLabel(start: event.startDate, end: event.endDate))
      }
      ForEach(dayPlans) { entry in
        BarMark(xStart: .value("Start", max(entry.startDate, dayInterval.start)),
                xEnd: .value("End", min(entry.endDate, dayInterval.end)), y: .value("Source", "Robur"))
          .foregroundStyle(RoburStyle.orange).cornerRadius(3)
          .accessibilityLabel(entry.activity.title)
          .accessibilityValue(timeLabel(start: entry.startDate, end: entry.endDate))
      }
      ForEach(overlapSegments) { segment in
        BarMark(xStart: .value("Overlap start", segment.start), xEnd: .value("Overlap end", segment.end),
          y: .value("Source", "Robur"))
          .foregroundStyle(Color.red).cornerRadius(3)
          .accessibilityLabel("Overlapping training time")
      }
    }
    .chartXScale(domain: dayInterval.start...dayInterval.end)
    .chartYScale(domain: ["Robur", "Calendar"])
    .chartXAxis { AxisMarks(values: .stride(by: .hour, count: 6)) { AxisValueLabel(format: .dateTime.hour()) } }
    .chartYAxis { AxisMarks(position: .leading) { AxisValueLabel() } }
    .frame(height: 105)
    .accessibilityIdentifier("calendar-day-timeline")
  }

  private var dayAgenda: some View {
    VStack(alignment: .leading, spacing: 12) {
      if dayPlans.isEmpty && dayEvents.isEmpty {
        Text(calendarAccess && error == nil && !isLoading ? "No Calendar events or training sessions on this day." : "No Robur sessions on this day.")
          .font(.callout).foregroundStyle(.secondary)
      }
      ForEach(agendaItems) { item in agendaRow(item) }
    }
  }

  private func agendaRow(_ item: AgendaItem) -> some View {
    HStack(alignment: .top, spacing: 10) {
      Image(systemName: item.planID == nil ? "calendar" : "figure.mixed.cardio")
        .foregroundStyle(item.planID == nil ? RoburStyle.blue : RoburStyle.orange).frame(width: 22)
      VStack(alignment: .leading, spacing: 3) {
        Text(item.title).font(.subheadline.weight(.semibold))
        Text(item.isAllDay ? "All day · \(item.source)" : timeLabel(start: item.start, end: item.end) + " · " + item.source)
          .font(.caption).foregroundStyle(.secondary)
        if item.overlaps { Label("Overlaps another item", systemImage: "exclamationmark.triangle.fill").font(.caption).foregroundStyle(.red) }
      }
      Spacer(minLength: 4)
      if let id = item.planID { Button("Edit") { onEdit(id) }.font(.caption).buttonStyle(.bordered) }
    }
  }

  private struct AgendaItem: Identifiable {
    let id: String
    let title: String
    let source: String
    let start: Date
    let end: Date
    let isAllDay: Bool
    let planID: UUID?
    let overlaps: Bool
  }
  private var agendaItems: [AgendaItem] {
    let plans = dayPlans.map { entry in
      AgendaItem(id: "plan:\(entry.id)", title: entry.activity.title + (entry.muscles.isEmpty ? "" : " · " + entry.muscleSummary),
        source: "Robur · \(entry.state.title)", start: entry.startDate, end: entry.endDate, isAllDay: false,
        planID: entry.id, overlaps: entryOverlaps(entry, in: dayInterval))
    }
    let calendarItems = dayEvents.filter { !$0.isAllDay }.map { event in
      let overlap = event.blocksTime && dayPlans.contains {
        max(event.startDate, $0.startDate, dayInterval.start) < min(event.endDate, $0.endDate, dayInterval.end)
      }
      return AgendaItem(id: "calendar:\(event.id)", title: event.title, source: event.calendarTitle + (event.blocksTime ? "" : " · Free"),
        start: event.startDate, end: event.endDate, isAllDay: false, planID: nil, overlaps: overlap)
    }
    return (plans + calendarItems).sorted { $0.start == $1.start ? $0.id < $1.id : $0.start < $1.start }
  }
  private struct OverlapSegment: Identifiable {
    let id: String
    let start: Date
    let end: Date
  }
  private var overlapSegments: [OverlapSegment] {
    dayPlans.flatMap { entry in
      TrainingCalendar.conflicts(for: entry, events: externalEvents, plans: entries).compactMap { conflict in
        let start = max(entry.startDate, conflict.startDate, dayInterval.start)
        let end = min(entry.endDate, conflict.endDate, dayInterval.end)
        guard start < end else { return nil }
        return OverlapSegment(id: "\(entry.id):\(conflict.id)", start: start, end: end)
      }
    }
  }

  private func hasOverlap(in interval: DateInterval) -> Bool {
    weekPlans.contains { entryOverlaps($0, in: interval) }
  }
  private func entryOverlaps(_ entry: PlanEntry, in interval: DateInterval) -> Bool {
    TrainingCalendar.conflicts(for: entry, events: externalEvents, plans: entries).contains { conflict in
      max(entry.startDate, conflict.startDate, interval.start) < min(entry.endDate, conflict.endDate, interval.end)
    }
  }
  private func bandInterval(on date: Date, band: Int) -> DateInterval {
    let calendar = Calendar.current
    let start = calendar.date(bySettingHour: band * 6, minute: 0, second: 0, of: date) ?? date
    let end = band == 3 ? calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: date)) :
      calendar.date(bySettingHour: (band + 1) * 6, minute: 0, second: 0, of: date)
    return DateInterval(start: start, end: max(start, end ?? start))
  }
  private func intersects(_ start: Date, _ end: Date, _ interval: DateInterval) -> Bool {
    start < interval.end && interval.start < end
  }
  private func select(_ date: Date) {
    selectedDay = date
    selection?.wrappedValue = date
    onSelectDay?(date)
  }
  private func timeLabel(start: Date, end: Date) -> String {
    let from = start < dayInterval.start ? "Continues" : start.formatted(date: .omitted, time: .shortened)
    let to = end > dayInterval.end ? "continues" : end.formatted(date: .omitted, time: .shortened)
    return from + "–" + to
  }
}
