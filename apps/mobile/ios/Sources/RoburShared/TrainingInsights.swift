import Foundation

struct InsightScore: Identifiable {
  var id: String { title }
  let title: String
  let value: Int
  let explanation: String
}

struct DailyLoadPoint: Identifiable {
  var id: Date { date }
  let date: Date
  let load: Double
}

struct HealthTrend: Identifiable {
  var id: String { title }
  let title: String
  let unit: String
  let current: Double
  let baseline: Double?
  let changePercent: Double?
  let direction: String
  let mean7: Double?
  let mean30: Double?
  let mean90: Double?
}

struct PersonalRecord: Identifiable {
  var id: String { title }
  let title: String
  let value: String
  let date: Date
}

struct HeartZoneTotal: Identifiable, Equatable {
  var id: Int { zone }
  let zone: Int
  let minutes: Double
}

struct AdaptiveGoalSuggestion {
  let current: Double
  let proposed: Double
  let reason: String
}

struct InsightsSummary {
  let readiness: Int?
  let fitness: Int?
  let scores: [InsightScore]
  let readinessComponents: [InsightScore]
  let load7: Double
  let load28: Double
  let loadRatio: Double?
  let loadStatus: String
  let dailyLoad: [DailyLoadPoint]
  let trends: [HealthTrend]
  let records: [PersonalRecord]
  let weeklyReport: [String]
  let zones: [HeartZoneTotal]
  let currentStreak: Int
  let activeDays: Int
}

/// Transparent fitness heuristics, not validated clinical or injury-risk scores.
/// Missing measurements are excluded; no average or zone is synthesized from missing data.
enum TrainingInsights {
  static func make(days: [DailyHealthMetrics], workouts: [WorkoutRecord], annotations: [String: WorkoutAnnotation],
                   maxHR: Double, now: Date = Date(), stepsGoal: Double = 8_000,
                   exerciseGoal: Double = 30, calendar: Calendar = .current) -> InsightsSummary {
    let today = calendar.startOfDay(for: now)
    func since(_ offset: Int) -> Date { calendar.date(byAdding: .day, value: -offset, to: today) ?? today }
    let validDays = days.filter { $0.date <= now }.sorted { $0.date < $1.date }
    let recent = validDays.filter { $0.date >= since(6) }
    let previous = validDays.filter { $0.date >= since(13) && $0.date < since(6) }
    let baseline = validDays.filter { $0.date >= since(30) && $0.date < today }
    let monthly = validDays.filter { $0.date >= since(29) }
    let sessions = workouts.filter { $0.start <= now && $0.minutes.isFinite && $0.minutes > 0 }
    let loaded = sessions.compactMap { workout -> (WorkoutRecord, Double)? in
      guard let load = sessionLoad(for: workout, annotation: annotations[workout.id], maxHR: maxHR) else { return nil }
      return (workout, load)
    }
    let load7 = loaded.filter { $0.0.start >= since(6) }.reduce(0) { $0 + $1.1 }
    let load28 = loaded.filter { $0.0.start >= since(27) }.reduce(0) { $0 + $1.1 }
    let hasPriorLoad = loaded.contains { $0.0.start >= since(27) && $0.0.start < since(6) }
    let ratio = hasPriorLoad && load28 > 0 ? load7 / (load28 / 4) : nil
    let loadStatus = ratio.map { $0 < 0.8 ? "Low" : ($0 > 1.3 ? "High" : "Optimal") } ?? "Building baseline"

    var readinessParts: [(InsightScore, Double)] = []
    func addReadiness(_ title: String, key: KeyPath<DailyHealthMetrics, Double?>,
                      weight: Double, inverse: Bool = false) {
      guard let observation = validDays.last(where: { $0.date >= since(1) && positive($0[keyPath: key]) != nil }),
            let current = positive(observation[keyPath: key]) else { return }
      let observationDay = calendar.startOfDay(for: observation.date)
      let baselineStart = calendar.date(byAdding: .day, value: -30, to: observationDay) ?? observationDay
      let values = validDays.filter { $0.date >= baselineStart && $0.date < observationDay }
        .compactMap { positive($0[keyPath: key]) }
      guard values.count >= 7, let base = mean(values) else { return }
      let deviation = inverse ? 1 - current / base : current / base - 1
      let value = score(70 + deviation * (inverse ? 200 : 100))
      let part = InsightScore(title: title, value: value,
        explanation: "\(Int(weight * 100))% readiness weight; latest value \(number(current)) vs your prior 30-day average \(number(base)) (\(values.count) recorded days). Baseline maps to 70/100; \(inverse ? "lower" : "higher") relative values score higher.")
      readinessParts.append((part, weight))
    }
    addReadiness("Sleep", key: \.sleepMinutes, weight: 0.35)
    addReadiness("HRV", key: \.hrv, weight: 0.30)
    addReadiness("Resting HR", key: \.restingHR, weight: 0.20, inverse: true)
    // Activity contributes only after at least two direct recovery signals are available.
    if readinessParts.count >= 2 {
      let activityBase = baseline.compactMap { nonnegative($0.exerciseMinutes) }
      let activityRecent = validDays.filter { $0.date >= since(2) }.compactMap { nonnegative($0.exerciseMinutes) }
      if activityBase.count >= 7, let average = mean(activityBase), average > 0, !activityRecent.isEmpty {
        let activityRatio = (mean(activityRecent) ?? 0) / average
        let value = score(70 - max(0, activityRatio - 1) * 30)
        readinessParts.append((InsightScore(title: "Recent activity", value: value,
          explanation: "10% readiness weight; recent exercise minutes vs your prior 30-day daily average. Above-baseline activity reduces this recovery component."), 0.10))
      }
      if let ratio {
        readinessParts.append((InsightScore(title: "Recent workouts", value: score(70 - max(0, ratio - 1.1) * 40),
          explanation: "5% readiness weight; 7-day load vs the weekly average of the last 28 days. A relative increase reduces this recovery component."), 0.05))
      }
    }
    let readiness = readinessParts.count >= 2 ? weighted(readinessParts) : nil

    let goalDates = Set(validDays.filter {
      ($0.steps ?? -1) >= stepsGoal || ($0.exerciseMinutes ?? -1) >= exerciseGoal
    }.map { calendar.startOfDay(for: $0.date) })
    let activeDates = Set(goalDates.filter { $0 >= since(29) })
    let trainingDates = Set(sessions.filter { $0.start >= since(29) && $0.minutes >= 10 }
      .map { calendar.startOfDay(for: $0.start) })
    let activeDays = activeDates.union(trainingDates).count
    var fitnessParts: [(InsightScore, Double)] = []
    let cardio = monthly.compactMap { positive($0.vo2Max) }
    if let current = cardio.last, let base = mean(baseline.compactMap { positive($0.vo2Max) }), cardio.count >= 2 {
      fitnessParts.append((InsightScore(title: "Cardio", value: score(70 + (current / base - 1) * 100),
        explanation: "25% fitness weight. Latest VO₂ max relative to your own prior 30-day average; baseline maps to 70. This is a progress score, not an age-adjusted VO₂ max percentile."), 0.25))
    }
    let activity = monthly.compactMap { day -> Double? in
      var fractions: [Double] = []
      if let steps = nonnegative(day.steps), stepsGoal > 0 { fractions.append(min(steps / stepsGoal, 1)) }
      if let exercise = nonnegative(day.exerciseMinutes), exerciseGoal > 0 { fractions.append(min(exercise / exerciseGoal, 1)) }
      return mean(fractions)
    }
    if activity.count >= 7, let average = mean(activity) {
      fitnessParts.append((InsightScore(title: "Activity", value: score(average * 100),
        explanation: "25% fitness weight. Mean daily completion of your step and exercise goals over recorded days in the last 30 days (\(activity.count) days)."), 0.25))
    }
    if let readiness {
      fitnessParts.append((InsightScore(title: "Recovery", value: readiness,
        explanation: "20% fitness weight. Your available personal-baseline readiness components; missing components are excluded."), 0.20))
    }
    let observedDates = Set(monthly.map { calendar.startOfDay(for: $0.date) }).union(trainingDates)
    if observedDates.count >= 14 {
      fitnessParts.append((InsightScore(title: "Consistency", value: score(Double(activeDays) / 20 * 100),
        explanation: "20% fitness weight. Goal: 20 active days in the last 30, where an active day meets a step/exercise target or includes at least 10 workout minutes."), 0.20))
    }
    let monthlySessions = sessions.filter { $0.start >= since(29) }
    if !monthlySessions.isEmpty {
      let strength = monthlySessions.filter {
        $0.activityType == .traditionalStrength || $0.activityType == .functionalStrength ||
          ($0.activityType == .other && $0.title.localizedCaseInsensitiveContains("strength"))
      }.count
      fitnessParts.append((InsightScore(title: "Strength", value: score(Double(strength) / 8 * 100),
        explanation: "10% fitness weight. Eight recorded strength sessions per 30 days maps to 100; it measures participation, not strength or muscle size."), 0.10))
    }
    let fitness = observedDates.count >= 14 && fitnessParts.count >= 3 ? weighted(fitnessParts) : nil

    var daily: [Date: Double] = [:]
    for (workout, load) in loaded { daily[calendar.startOfDay(for: workout.start), default: 0] += load }
    let dailyLoad = daily.keys.sorted().map { DailyLoadPoint(date: $0, load: daily[$0] ?? 0) }
    let trendSpecs: [(String, String, KeyPath<DailyHealthMetrics, Double?>)] = [
      ("HRV", "ms", \.hrv), ("Resting HR", "bpm", \.restingHR), ("Cardio fitness", "mL/kg/min", \.vo2Max),
      ("Sleep", "min", \.sleepMinutes), ("Steps", "steps", \.steps), ("Exercise", "min", \.exerciseMinutes),
      ("Stand time", "min", \.standMinutes), ("Active energy", "kcal", \.activeEnergyKcal), ("Weight", "kg", \.weightKg)
    ]
    let trends = trendSpecs.compactMap { title, unit, key -> HealthTrend? in
      func values(_ lower: Date) -> [Double] {
        validDays.filter { $0.date >= lower && $0.date <= now }.compactMap { nonnegative($0[keyPath: key]) }
      }
      let week = values(since(6))
      guard let current = mean(week) else { return nil }
      let old = validDays.filter { $0.date >= since(36) && $0.date < since(6) }.compactMap { nonnegative($0[keyPath: key]) }
      let base = old.count >= 7 ? mean(old) : nil
      let percent = base.flatMap { $0 > 0 ? (current / $0 - 1) * 100 : nil }
      var direction = "Building baseline"
      if let base {
        if week.count < 5 { direction = "More readings needed" }
        else if week.filter({ $0 > base * 1.03 }).count >= 5 { direction = "Sustained increase" }
        else if week.filter({ $0 < base * 0.97 }).count >= 5 { direction = "Sustained decrease" }
        else { direction = "Stable / mixed" }
      }
      return HealthTrend(title: title, unit: unit, current: current, baseline: base, changePercent: percent,
        direction: direction, mean7: current, mean30: mean(values(since(29))), mean90: mean(values(since(89))))
    }
    var zoneMinutes = Array(repeating: 0.0, count: 5)
    for workout in sessions where workout.start >= since(6) {
      for zone in heartZones(samples: workout.heartRateSamples, end: min(workout.end, now), maxHR: maxHR) {
        zoneMinutes[zone.zone - 1] += zone.minutes
      }
    }
    let zones = (1...5).map { HeartZoneTotal(zone: $0, minutes: zoneMinutes[$0 - 1]) }
    var streak = 0
    var cursor = goalDates.contains(today) ? today : since(1)
    while goalDates.contains(cursor) {
      streak += 1
      guard let prior = calendar.date(byAdding: .day, value: -1, to: cursor) else { break }
      cursor = prior
    }
    var report: [String] = []
    for (name, key) in [("Steps", \DailyHealthMetrics.steps), ("Exercise minutes", \DailyHealthMetrics.exerciseMinutes),
                        ("Sleep minutes", \DailyHealthMetrics.sleepMinutes)] {
      let current = recent.compactMap { nonnegative($0[keyPath: key]) }
      let prior = previous.compactMap { nonnegative($0[keyPath: key]) }
      // Compare completed calendar days only; today's incomplete activity cannot distort a weekly report.
      let completeCurrent = validDays.filter { $0.date >= since(7) && $0.date < today }.compactMap { nonnegative($0[keyPath: key]) }
      let completePrior = validDays.filter { $0.date >= since(14) && $0.date < since(7) }.compactMap { nonnegative($0[keyPath: key]) }
      if completeCurrent.count == 7, completePrior.count == 7,
         let oldMean = mean(completePrior), oldMean > 0, let newMean = mean(completeCurrent) {
        report.append("\(name) \(String(format: "%+.0f", (newMean / oldMean - 1) * 100))% vs the previous week.")
      } else if !current.isEmpty || !prior.isEmpty {
        report.append("\(name): building two complete weeks of readings for comparison.")
      }
    }
    let recoveryReportSpecs: [(String, KeyPath<DailyHealthMetrics, Double?>, Int)] = [
      ("HRV", \.hrv, 2), ("Resting HR", \.restingHR, 2), ("VO₂ max", \.vo2Max, 1)
    ]
    for (name, key, minimum) in recoveryReportSpecs {
      let current = validDays.filter { $0.date >= since(7) && $0.date < today }.compactMap { positive($0[keyPath: key]) }
      let prior = validDays.filter { $0.date >= since(14) && $0.date < since(7) }.compactMap { positive($0[keyPath: key]) }
      if current.count >= minimum, prior.count >= minimum, let old = mean(prior), old > 0, let new = mean(current) {
        report.append("\(name) average \(String(format: "%+.0f", (new / old - 1) * 100))% vs prior week (\(current.count)/\(prior.count) recorded days).")
      }
    }
    let weeklySessions = sessions.filter { $0.start >= since(7) && $0.start < today }
    report.insert("Last 7 complete days: \(weeklySessions.count) workouts, \(Int(weeklySessions.reduce(0) { $0 + $1.minutes })) training minutes.", at: 0)
    return InsightsSummary(readiness: readiness, fitness: fitness, scores: fitnessParts.map(\.0),
      readinessComponents: readinessParts.map(\.0), load7: load7, load28: load28, loadRatio: ratio,
      loadStatus: loadStatus, dailyLoad: dailyLoad, trends: trends, records: personalRecords(days: validDays, workouts: sessions),
      weeklyReport: report, zones: zones, currentStreak: streak, activeDays: activeDays)
  }

  /// Apple Fitness effort is authoritative. HR-based intensity is explicitly an estimate;
  /// manual ratings are used only when neither Health source supplies an effort measure.
  static func sessionLoad(for workout: WorkoutRecord, annotation: WorkoutAnnotation? = nil, maxHR: Double) -> Double? {
    guard workout.minutes.isFinite, workout.minutes > 0 else { return nil }
    if let effort = workout.appleEffort, effort.isFinite, (1...10).contains(effort) { return workout.minutes * effort }
    if let heart = positive(workout.averageHeartRate), maxHR.isFinite, maxHR > 0 {
      return workout.minutes * max(1, min(10, heart / maxHR * 10))
    }
    if let effort = annotation?.effort, (1...10).contains(effort) { return workout.minutes * Double(effort) }
    return nil
  }

  static func heartZones(samples: [WorkoutHeartSample], end: Date, maxHR: Double) -> [HeartZoneTotal] {
    var totals = Array(repeating: 0.0, count: 5)
    guard maxHR.isFinite, maxHR > 0 else { return (1...5).map { HeartZoneTotal(zone: $0, minutes: 0) } }
    let sorted = samples.filter { $0.date < end && $0.bpm.isFinite && $0.bpm > 0 }.sorted { $0.date < $1.date }
    for (index, sample) in sorted.enumerated() {
      let next = index + 1 < sorted.count ? sorted[index + 1].date : end
      let seconds = min(60, max(0, min(next, end).timeIntervalSince(sample.date)))
      let fraction = sample.bpm / maxHR
      let zone = fraction < 0.6 ? 0 : fraction < 0.7 ? 1 : fraction < 0.8 ? 2 : fraction < 0.9 ? 3 : 4
      totals[zone] += seconds / 60
    }
    return (1...5).map { HeartZoneTotal(zone: $0, minutes: totals[$0 - 1]) }
  }

  static func adaptiveStepGoal(days: [DailyHealthMetrics], current: Double, now: Date = Date(),
                               calendar: Calendar = .current) -> AdaptiveGoalSuggestion? {
    guard current.isFinite, current >= 1_000 else { return nil }
    let today = calendar.startOfDay(for: now)
    let start = calendar.date(byAdding: .day, value: -30, to: today) ?? today
    let values = days.filter { $0.date >= start && $0.date < today }.compactMap { nonnegative($0.steps) }
    guard values.count >= 21, let average = mean(values) else { return nil }
    let fractionMet = Double(values.filter { $0 >= current }.count) / Double(values.count)
    if fractionMet >= 0.8 && average > current * 1.1 {
      let proposed = (min(current * 1.05, 40_000) / 100).rounded() * 100
      guard proposed > current else { return nil }
      return AdaptiveGoalSuggestion(current: current, proposed: proposed,
        reason: "You met your current step goal on at least 80% of \(values.count) recorded days. Consider a gradual 5% increase; accept only if it suits you.")
    }
    if fractionMet <= 0.3 && average < current * 0.8 {
      let proposed = (max(current * 0.95, 1_000) / 100).rounded() * 100
      guard proposed < current else { return nil }
      return AdaptiveGoalSuggestion(current: current, proposed: proposed,
        reason: "You met your step goal on at most 30% of \(values.count) recorded days. A 5% reduction may make the goal more achievable; your confirmation is required.")
    }
    return nil
  }

  private static func personalRecords(days: [DailyHealthMetrics], workouts: [WorkoutRecord]) -> [PersonalRecord] {
    var records: [PersonalRecord] = []
    if let longest = workouts.max(by: { $0.minutes < $1.minutes }) {
      records.append(PersonalRecord(title: "Longest workout", value: "\(Int(longest.minutes)) min · \(longest.title)", date: longest.start))
    }
    for distance in [1.0, 5.0, 10.0] {
      let candidates = workouts.filter { workout in
        guard workout.activityType == .running ||
          (workout.activityType == .other && workout.title.localizedCaseInsensitiveContains("run")),
          let km = workout.distanceKm else { return false }
        return km.isFinite && abs(km - distance) <= distance * 0.02
      }
      if let best = candidates.min(by: { $0.minutes < $1.minutes }) {
        records.append(PersonalRecord(title: "Fastest ~\(Int(distance)) km complete run",
          value: "\(number(best.minutes)) min over \(String(format: "%.2f", best.distanceKm ?? distance)) km (whole workout)", date: best.start))
      }
    }
    let specs: [(String, String, KeyPath<DailyHealthMetrics, Double?>, Bool)] = [
      ("Most daily steps", "steps", \.steps, true), ("Highest daily VO₂ max", "mL/kg/min", \.vo2Max, true),
      ("Lowest daily resting HR", "bpm", \.restingHR, false)
    ]
    for (title, unit, key, highest) in specs {
      let values = days.compactMap { day -> (Date, Double)? in positive(day[keyPath: key]).map { (day.date, $0) } }
      let best = values.sorted { highest ? $0.1 > $1.1 : $0.1 < $1.1 }.first
      if let best { records.append(PersonalRecord(title: title, value: "\(number(best.1)) \(unit)", date: best.0)) }
    }
    return records
  }

  private static func weighted(_ parts: [(InsightScore, Double)]) -> Int {
    let denominator = parts.reduce(0) { $0 + $1.1 }
    return score(parts.reduce(0) { $0 + Double($1.0.value) * $1.1 } / max(denominator, 0.001))
  }
  private static func score(_ value: Double) -> Int {
    guard value.isFinite else { return 0 }
    return Int(max(0, min(100, value)).rounded())
  }
  private static func positive(_ value: Double?) -> Double? { value.flatMap { $0.isFinite && $0 > 0 ? $0 : nil } }
  private static func nonnegative(_ value: Double?) -> Double? { value.flatMap { $0.isFinite && $0 >= 0 ? $0 : nil } }
  private static func mean(_ values: [Double]) -> Double? { values.isEmpty ? nil : values.reduce(0, +) / Double(values.count) }
  private static func number(_ value: Double) -> String { String(format: "%.1f", value) }
}
