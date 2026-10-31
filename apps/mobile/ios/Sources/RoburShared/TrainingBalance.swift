import Foundation

enum TrainingCategory: String, CaseIterable, Identifiable, Codable, Hashable {
  case endurance, strength, mobility, sport, other
  var id: String { rawValue }
  var title: String {
    switch self {
    case .endurance: return "Endurance & conditioning"
    case .strength: return "Strength"
    case .mobility: return "Mobility & flexibility"
    case .sport: return "Sport"
    case .other: return "Other"
    }
  }
  var symbol: String {
    switch self {
    case .endurance: return "heart.circle"
    case .strength: return "dumbbell"
    case .mobility: return "figure.flexibility"
    case .sport: return "sportscourt"
    case .other: return "figure.mixed.cardio"
    }
  }
}

enum WorkoutActivity: String, CaseIterable, Identifiable, Codable, Hashable {
  case running, cycling, walking, swimming, tennis, racketSports
  case traditionalStrength, functionalStrength, hiit, mobility, hiking, rowing, other
  var id: String { rawValue }
  var title: String {
    switch self {
    case .running: return "Running"
    case .cycling: return "Cycling"
    case .walking: return "Walking"
    case .swimming: return "Swimming"
    case .tennis: return "Tennis"
    case .racketSports: return "Racket sports"
    case .traditionalStrength: return "Traditional strength"
    case .functionalStrength: return "Functional strength"
    case .hiit: return "HIIT"
    case .mobility: return "Mobility"
    case .hiking: return "Hiking"
    case .rowing: return "Rowing"
    case .other: return "Other workouts"
    }
  }
  var symbol: String {
    switch self {
    case .running: return "figure.run"
    case .cycling: return "figure.outdoor.cycle"
    case .walking: return "figure.walk"
    case .swimming: return "figure.pool.swim"
    case .tennis: return "figure.tennis"
    case .racketSports: return "figure.racquetball"
    case .traditionalStrength: return "dumbbell.fill"
    case .functionalStrength: return "figure.strengthtraining.functional"
    case .hiit: return "bolt.heart.fill"
    case .mobility: return "figure.flexibility"
    case .hiking: return "figure.hiking"
    case .rowing: return "figure.rower"
    case .other: return "figure.mixed.cardio"
    }
  }
  var category: TrainingCategory {
    switch self {
    case .running, .cycling, .walking, .swimming, .hiit, .hiking, .rowing: return .endurance
    case .traditionalStrength, .functionalStrength: return .strength
    case .mobility: return .mobility
    case .tennis, .racketSports: return .sport
    case .other: return .other
    }
  }
}

struct ActivityBreakdown: Identifiable {
  var id: WorkoutActivity { activity }
  let activity: WorkoutActivity
  let minutes: Double
  let sessions: Int
}

struct CategoryBreakdown: Identifiable {
  var id: TrainingCategory { category }
  let category: TrainingCategory
  let minutes: Double
  let sessions: Int
}

struct TrainingBalanceSummary {
  let totalMinutes: Double
  let sessions: Int
  let breakdown: [ActivityBreakdown]
  let categories: [CategoryBreakdown]
  let missing: [TrainingCategory]
  let missingActivities: [WorkoutActivity]
}

enum TrainingBalance {
  /// Describes recorded workout labels only. It cannot infer muscles, exercise outside
  /// HealthKit, or whether a particular sport is necessary for someone's goals.
  static func make(workouts: [WorkoutRecord], now: Date = Date(), days: Int = 28,
                   expected: Set<TrainingCategory> = [.endurance, .strength, .mobility],
                   expectedActivities: Set<WorkoutActivity> = [], calendar: Calendar = .current) -> TrainingBalanceSummary {
    let today = calendar.startOfDay(for: now)
    let start = calendar.date(byAdding: .day, value: -(max(1, days) - 1), to: today) ?? today
    // UUID identity wins over repeated imports; differently sourced workouts remain separate.
    var seen: Set<String> = []
    let sessions = workouts.filter {
      $0.start >= start && $0.start <= now && $0.minutes.isFinite && $0.minutes > 0 && seen.insert($0.id).inserted
    }
    let byActivity = Dictionary(grouping: sessions, by: \.activityType)
    let breakdown = WorkoutActivity.allCases.compactMap { activity -> ActivityBreakdown? in
      guard let records = byActivity[activity], !records.isEmpty else { return nil }
      return ActivityBreakdown(activity: activity, minutes: records.reduce(0) { $0 + $1.minutes }, sessions: records.count)
    }.sorted { $0.minutes == $1.minutes ? $0.activity.rawValue < $1.activity.rawValue : $0.minutes > $1.minutes }
    let categories = TrainingCategory.allCases.compactMap { category -> CategoryBreakdown? in
      let records = sessions.filter { $0.activityType.category == category }
      guard !records.isEmpty else { return nil }
      return CategoryBreakdown(category: category, minutes: records.reduce(0) { $0 + $1.minutes }, sessions: records.count)
    }
    let recordedCategories = Set(categories.map(\.category))
    return TrainingBalanceSummary(totalMinutes: sessions.reduce(0) { $0 + $1.minutes }, sessions: sessions.count,
      breakdown: breakdown, categories: categories,
      missing: TrainingCategory.allCases.filter { expected.contains($0) && !recordedCategories.contains($0) },
      missingActivities: WorkoutActivity.allCases.filter { expectedActivities.contains($0) && byActivity[$0] == nil })
  }
}

struct TrainingLoadPoint: Identifiable {
  var id: Date { date }
  let date: Date
  let dailyLoad: Double?
  let acute7: Double?
  let baseline28: Double?
  let changePercent: Double?
}

struct TrainingLoadSummary {
  let points: [TrainingLoadPoint]
  let recent7Mean: Double?
  let baseline28Mean: Double?
  let changePercent: Double?
  let classification: String
  let ratedSessions: Int
  let totalSessions: Int
  let reportedSessions: Int
  let estimatedSessions: Int
}

enum TrainingLoadComparison {
  /// A Robur comparison inspired by Fitness's 7/28-day view. Arithmetic daily means
  /// and the explicit +/-10%, +/-50% bands are ours, not Apple's proprietary weighting.
  /// Only imported Apple effort ratings contribute; Robur HR/manual estimates do not.
  static func make(workouts: [WorkoutRecord], now: Date = Date(), historyStart: Date? = nil,
                   displayDays: Int = 30, activity: WorkoutActivity? = nil,
                   calendar: Calendar = .current) -> TrainingLoadSummary {
    let today = calendar.startOfDay(for: now)
    func date(_ day: Date, minus days: Int) -> Date { calendar.date(byAdding: .day, value: -days, to: day) ?? day }
    var seen: Set<String> = []
    let sessions = workouts.filter {
      $0.start <= now && $0.minutes.isFinite && $0.minutes > 0 &&
        (activity == nil || $0.activityType == activity) && seen.insert($0.id).inserted
    }
    let earliest = historyStart ?? sessions.map(\.start).min()
    let firstCovered: Date? = earliest.map { start in
      let midnight = calendar.startOfDay(for: start)
      return start == midnight ? midnight : (calendar.date(byAdding: .day, value: 1, to: midnight) ?? midnight)
    }
    let byDay = Dictionary(grouping: sessions) { calendar.startOfDay(for: $0.start) }
    func importedLoad(_ workout: WorkoutRecord) -> Double? {
      guard let effort = workout.appleEffort, effort.isFinite, (1...10).contains(effort) else { return nil }
      let load = workout.minutes * effort
      return load.isFinite ? load : nil
    }
    func stats(start: Date, through end: Date) -> (load: Double, rated: Int, total: Int) {
      var load = 0.0, rated = 0, total = 0
      var cursor = start
      while cursor <= end {
        for workout in byDay[cursor] ?? [] {
          total += 1
          if let value = importedLoad(workout) { load += value; rated += 1 }
        }
        guard let next = calendar.date(byAdding: .day, value: 1, to: cursor), next > cursor else { break }
        cursor = next
      }
      return (load, rated, total)
    }
    let hasAnyImportedEffort = sessions.contains { importedLoad($0) != nil }
    func point(_ day: Date) -> TrainingLoadPoint {
      let week = stats(start: date(day, minus: 6), through: day)
      let month = stats(start: date(day, minus: 27), through: day)
      let daily = stats(start: day, through: day)
      let hasWeekCoverage = firstCovered.map { $0 <= date(day, minus: 6) } ?? false
      let hasMonthCoverage = firstCovered.map { $0 <= date(day, minus: 27) } ?? false
      // A rest week can have zero load. A week containing only unrated sessions is unknown.
      let acute: Double? = hasWeekCoverage && (week.rated > 0 || (week.total == 0 && month.rated > 0)) ? week.load / 7 : nil
      let chronic: Double? = hasMonthCoverage && month.rated > 0 ? month.load / 28 : nil
      let percentage: Double? = acute.flatMap { a in chronic.flatMap { $0 > 0 ? (a / $0 - 1) * 100 : nil } }
      let dailyValue: Double? = daily.rated > 0 || (daily.total == 0 && hasAnyImportedEffort) ? daily.load : nil
      return TrainingLoadPoint(date: day, dailyLoad: dailyValue, acute7: acute, baseline28: chronic, changePercent: percentage)
    }
    let current = point(today)
    let monthStart = date(today, minus: 27)
    let currentSessions = sessions.filter { $0.start >= monthStart }
    let included = currentSessions.filter { importedLoad($0) != nil }
    var points: [TrainingLoadPoint] = []
    let limit = min(max(displayDays, 1), 3660)
    for index in (0..<limit).reversed() {
      let day = date(today, minus: index)
      guard firstCovered.map({ day >= $0 }) == true else { continue }
      points.append(point(day))
    }
    return TrainingLoadSummary(points: points, recent7Mean: current.acute7, baseline28Mean: current.baseline28,
      changePercent: current.changePercent, classification: classification(changePercent: current.changePercent),
      ratedSessions: included.count, totalSessions: currentSessions.count,
      reportedSessions: included.filter { $0.effortSource == .reported }.count,
      estimatedSessions: included.filter { $0.effortSource == .estimated }.count)
  }

  static func classification(changePercent: Double?) -> String {
    guard let changePercent, changePercent.isFinite else { return "Insufficient effort history" }
    if changePercent < -50 { return "Well below" }
    if changePercent < -10 { return "Below" }
    if changePercent <= 10 { return "Steady" }
    if changePercent <= 50 { return "Above" }
    return "Well above"
  }
}
