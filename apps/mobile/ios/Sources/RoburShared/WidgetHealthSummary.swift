import Foundation

struct WidgetHealthSummary: Equatable {
  let refreshedAt: Date
  var recovery: Int? = nil
  var sleepMinutes: Double? = nil
  var steps: Double? = nil
  var trainingMinutes: Double? = nil
  var workoutCount: Int? = nil
  var cardioFitness: Double? = nil
  var cardioDate: Date? = nil
  var sleepDate: Date? = nil
  var hasData: Bool { recovery != nil || sleepMinutes != nil || steps != nil || trainingMinutes != nil || cardioFitness != nil }
  func isStale(at now: Date) -> Bool { now.timeIntervalSince(refreshedAt) > 3_600 || refreshedAt > now.addingTimeInterval(60) }

  static func make(days: [DailyHealthMetrics], workouts: [WorkoutRecord], now: Date = Date(), calendar: Calendar = .current) -> Self {
    let today = calendar.startOfDay(for: now)
    let recent = days.filter { $0.date <= now && $0.date >= calendar.date(byAdding: .day, value: -2, to: today)! }.sorted { $0.date < $1.date }
    let sleep = recent.last { ($0.sleepMinutes ?? 0).isFinite && ($0.sleepMinutes ?? 0) > 0 }
    let cardio = days.filter { $0.date <= now && ($0.vo2Max ?? 0).isFinite && ($0.vo2Max ?? 0) > 0 }.max { $0.date < $1.date }
    let start = calendar.date(byAdding: .day, value: -6, to: today)!
    var ids = Set<String>()
    let sessions = workouts.filter { $0.start >= start && $0.start <= now && $0.minutes.isFinite && $0.minutes > 0 && ids.insert($0.id).inserted }
    // Recovery signals exclude workout effort and configured heart-rate zones.
    let summary = TrainingInsights.make(days: days, workouts: [], annotations: [:], maxHR: 190, now: now, calendar: calendar)
    let steps = days.first { calendar.isDate($0.date, inSameDayAs: today) }?.steps
    return Self(refreshedAt: now, recovery: summary.readiness, sleepMinutes: sleep?.sleepMinutes,
      steps: steps.flatMap { $0.isFinite && $0 >= 0 ? $0 : nil },
      trainingMinutes: sessions.isEmpty ? nil : sessions.reduce(0) { $0 + $1.minutes },
      workoutCount: sessions.isEmpty ? nil : sessions.count, cardioFitness: cardio?.vo2Max,
      cardioDate: cardio?.date, sleepDate: sleep?.date)
  }
}
