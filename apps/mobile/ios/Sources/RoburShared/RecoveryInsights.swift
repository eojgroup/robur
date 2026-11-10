import Foundation

struct FitnessReference: Codable, Equatable {
  let value: Double?
  let establishedAt: Date
}

struct RecoveryScoreComponent: Identifiable, Codable, Equatable {
  var id: String { key }
  let key: String
  let title: String
  let score: Int
  let current: Double
  let baseline: Double?
  let unit: String
  let effectiveWeight: Double
  let contribution: Double
  let explanation: String
}

struct RecoveryHistoryPoint: Identifiable, Codable, Equatable {
  var id: Date { date }
  let date: Date
  let recovery: Int?
  let fitness: Int?
  let coverage: Double
  let recoveryComponents: [RecoveryScoreComponent]
  let fitnessComponents: [RecoveryScoreComponent]
  let load: Double?
  let acuteLoad: Double?
  let chronicLoad: Double?
}

struct RecoveryAnalysis: Codable, Equatable {
  static let version = "robur-recovery-2.1"
  let methodologyVersion: String
  let date: Date
  let score: Int?
  let fitnessScore: Int?
  let recoveryComponents: [RecoveryScoreComponent]
  let fitnessComponents: [RecoveryScoreComponent]
  let history: [RecoveryHistoryPoint]
  /// Fraction of the configured recovery weights with eligible observations.
  let coverage: Double
  let baselineDays: Int
  let loadCoverage: Double?
  let sleepDebtMinutes: Double?
  var confidence: String { coverage >= 0.8 && baselineDays >= 21 ? "Established coverage" : coverage >= 0.5 ? "Partial coverage" : "Limited coverage" }
}

/// Robur's versioned, descriptive wellness model. Research informs the inputs,
/// not a clinically validated 0–100 formula. Apple HRV is SDNN, not RMSSD.
/// Historical points use only measurements/workouts available by that point's
/// time cutoff. Imported history and edited personal ratings can revise history.
enum RecoveryInsights {
  private struct Part {
    let key: String, title: String, value: Double, current: Double, baseline: Double?, unit: String, weight: Double, explanation: String
  }

  static func make(days: [DailyHealthMetrics], workouts: [WorkoutRecord], annotations: [String: WorkoutAnnotation],
                   maxHR: Double, now: Date = Date(), historyStart: Date? = nil, stepsGoal: Double = 8_000,
                   exerciseGoal: Double = 30, fitnessReference: FitnessReference? = nil,
                   calendar: Calendar = .current) -> RecoveryAnalysis {
    let today = calendar.startOfDay(for: now)
    // One imported daily aggregate per calendar day; repeated input must not
    // inflate baseline coverage. Prefer the later aggregate for the same day.
    let safeDays = days.filter { $0.date <= now && $0.date.timeIntervalSince1970.isFinite }.sorted { $0.date < $1.date }
    var byDay: [Date: DailyHealthMetrics] = [:]
    for day in safeDays { byDay[calendar.startOfDay(for: day.date)] = day }
    let ordered = byDay.values.sorted { $0.date < $1.date }
    var seen: Set<String> = []
    let sessions = workouts.filter { $0.start <= now && $0.end <= now && $0.minutes.isFinite && $0.minutes > 0 &&
      $0.start.timeIntervalSince1970.isFinite && $0.end >= $0.start && seen.insert($0.id).inserted }.sorted { $0.start < $1.start }
    let first = min(ordered.first.map { calendar.startOfDay(for: $0.date) } ?? today,
                    sessions.first.map { calendar.startOfDay(for: $0.start) } ?? today)
    let loadHistoryStart = min(historyStart ?? sessions.first.map { calendar.startOfDay(for: $0.start) } ?? today, today)
    let groupedSessions = Dictionary(grouping: sessions) { calendar.startOfDay(for: $0.end) }
    var history: [RecoveryHistoryPoint] = []
    var recentDays: [DailyHealthMetrics] = [], recentSessions: [WorkoutRecord] = []
    var dayCursor = first, acute = 0.0, chronic = 0.0
    var anchorValues: [Double] = [], anchorStart: Date?
    var finalParts: [Part] = [], finalFitness: [Part] = []
    var finalCoverage = 0.0, finalBaselineCount = 0, finalDebt: Double?, finalLoadCoverage: Double?
    while dayCursor <= today {
      let next = calendar.date(byAdding: .day, value: 1, to: dayCursor) ?? dayCursor.addingTimeInterval(86_400)
      let cutoff = dayCursor == today ? now : next.addingTimeInterval(-0.001)
      if let daily = byDay[dayCursor] {
        recentDays.append(daily)
        if let vo2 = positive(daily.vo2Max) {
          if anchorStart == nil { anchorStart = dayCursor }
          if let start = anchorStart, dayCursor < (calendar.date(byAdding: .day, value: 28, to: start) ?? next) { anchorValues.append(vo2) }
        }
      }
      let retention = calendar.date(byAdding: .day, value: -90, to: dayCursor) ?? first
      recentDays.removeAll { $0.date < retention }
      recentSessions += groupedSessions[dayCursor] ?? []
      recentSessions.removeAll { $0.start < retention }
      let todaySessions = groupedSessions[dayCursor] ?? []
      let todayLoads = todaySessions.compactMap { TrainingInsights.sessionLoad(for: $0, annotation: annotations[$0.id], maxHR: maxHR) }
      let load = todayLoads.reduce(0, +)
      // A training impulse/response visualization, not an individualized
      // Banister performance prediction. 7/42 days are explicit Robur choices.
      acute += (1 - exp(-1 / 7.0)) * (load - acute)
      chronic += (1 - exp(-1 / 42.0)) * (load - chronic)
      let age = max(0, calendar.dateComponents([.day], from: loadHistoryStart, to: dayCursor).day ?? 0)
      let result = recoveryParts(days: recentDays, sessions: recentSessions, annotations: annotations, maxHR: maxHR,
        date: dayCursor, cutoff: cutoff, acute: acute, chronic: chronic, historyDays: age, calendar: calendar)
      let anchor: Double?
      if let fitnessReference {
        anchor = cutoff >= fitnessReference.establishedAt ? positive(fitnessReference.value) : nil
      } else {
        anchor = anchorValues.count >= 2 ? mean(anchorValues) : nil
      }
      let fitness = fitnessParts(days: recentDays, sessions: recentSessions, anchor: anchor,
        date: dayCursor, stepsGoal: stepsGoal, exerciseGoal: exerciseGoal, calendar: calendar)
      let recoveryComponents = components(result.parts)
      let fitnessComponents = components(fitness.parts)
      let recoveryScore = result.signals >= 2 ? combined(recoveryComponents) : nil
      let fitnessScore = fitness.observed >= 14 && fitness.parts.count >= 3 ? combined(fitnessComponents) : nil
      history.append(RecoveryHistoryPoint(date: dayCursor, recovery: recoveryScore, fitness: fitnessScore,
        coverage: result.parts.reduce(0) { $0 + $1.weight }, recoveryComponents: recoveryComponents, fitnessComponents: fitnessComponents, load: todayLoads.isEmpty ? nil : load,
        acuteLoad: age >= 7 && !sessions.isEmpty ? acute : nil,
        chronicLoad: age >= 42 && !sessions.isEmpty ? chronic : nil))
      if dayCursor == today {
        finalParts = result.parts; finalFitness = fitness.parts; finalCoverage = result.parts.reduce(0) { $0 + $1.weight }
        finalBaselineCount = result.baselineDays; finalDebt = result.debt; finalLoadCoverage = result.loadCoverage
      }
      guard next > dayCursor else { break }
      dayCursor = next
    }
    let latest = history.last
    return RecoveryAnalysis(methodologyVersion: RecoveryAnalysis.version, date: today, score: latest?.recovery,
      fitnessScore: latest?.fitness, recoveryComponents: components(finalParts), fitnessComponents: components(finalFitness),
      history: history, coverage: finalCoverage, baselineDays: finalBaselineCount,
      loadCoverage: finalLoadCoverage, sleepDebtMinutes: finalDebt)
  }

  private static func recoveryParts(days: [DailyHealthMetrics], sessions: [WorkoutRecord], annotations: [String: WorkoutAnnotation],
      maxHR: Double, date: Date, cutoff: Date, acute: Double, chronic: Double, historyDays: Int, calendar: Calendar)
      -> (parts: [Part], signals: Int, baselineDays: Int, debt: Double?, loadCoverage: Double?) {
    func start(_ ago: Int) -> Date { calendar.date(byAdding: .day, value: -ago, to: date) ?? date }
    var parts: [Part] = [], signals = 0, baselineDays = 0
    let baseline = days.filter { $0.date >= start(30) && $0.date < date }
    func relative(_ key: String, _ title: String, _ field: KeyPath<DailyHealthMetrics, Double?>, weight: Double, inverse: Bool, logScale: Bool, unit: String) {
      guard let latest = days.last(where: { $0.date >= start(1) && $0.date <= cutoff && positive($0[keyPath: field]) != nil }),
        let current = positive(latest[keyPath: field]) else { return }
      let latestDay = calendar.startOfDay(for: latest.date)
      let samples = baseline.filter { $0.date < latestDay }.compactMap { positive($0[keyPath: field]) }
      guard samples.count >= 7, let base = mean(samples) else { return }
      baselineDays = max(baselineDays, samples.count)
      let values = samples.map { logScale ? log($0) : $0 }
      let centre = mean(values) ?? 0
      let dispersion = sqrt(values.reduce(0) { $0 + pow($1 - centre, 2) } / Double(values.count))
      let floor = logScale ? 0.10 : base * 0.05
      let z = ((logScale ? log(current) : current) - centre) / max(dispersion, floor)
      let value = bounded(70 + (inverse ? -1 : 1) * min(2, max(-4, z)) * 10)
      parts.append(Part(key: key, title: title, value: value, current: current, baseline: base,
        unit: unit, weight: weight,
        explanation: "Latest daily reading \(String(format: "%.1f", current)) \(unit) vs the preceding 30-day average \(String(format: "%.1f", base)) (\(samples.count) recorded days); baseline 70/100. \(logScale ? "Log SDNN is standardized within your own series; it is not RMSSD." : "A rise above your own resting-range baseline lowers this component.") Timing, illness, stress and measurement conditions can affect it."))
      signals += 1
    }
    relative("hrv", "HRV", \.hrv, weight: 0.25, inverse: false, logScale: true, unit: "ms SDNN")
    relative("restingHR", "Resting HR", \.restingHR, weight: 0.20, inverse: true, logScale: false, unit: "bpm")
    relative("respiratoryRate", "Respiratory rate", \.respiratoryRate, weight: 0.10, inverse: true, logScale: false, unit: "breaths/min")
    let sleepBaseline = baseline.compactMap { positive($0.sleepMinutes) }
    var debt: Double?
    if sleepBaseline.count >= 7, let base = mean(sleepBaseline),
      let latest = days.last(where: { $0.date >= start(1) && positive($0.sleepMinutes) != nil }), let sleep = positive(latest.sleepMinutes) {
      // Seven hours is a reference floor for adults, not an inferred personal
      // sleep requirement. Sleep alone cannot produce an overall recovery score.
      let target = max(420, base)
      parts.append(Part(key: "sleep", title: "Sleep", value: bounded(70 + (sleep / target - 1) * 100),
        current: sleep, baseline: target, unit: "min", weight: 0.25,
        explanation: "Recorded sleep vs your prior mean, with a 7-hour adult reference floor. Duration does not measure all sleep quality or recovery needs."))
      signals += 1; baselineDays = max(baselineDays, sleepBaseline.count)
      let recentSleep = days.filter { $0.date >= start(2) }.compactMap { positive($0.sleepMinutes) }
      if recentSleep.count >= 2 {
        let averageDeficit = recentSleep.reduce(0) { $0 + max(0, target - $1) } / Double(recentSleep.count)
        debt = averageDeficit
        parts.append(Part(key: "sleepDebt", title: "Recent sleep shortfall", value: bounded(85 - averageDeficit / 3),
          current: averageDeficit, baseline: 0, unit: "min/night", weight: 0.10,
          explanation: "Mean nightly shortfall across \(recentSleep.count) recorded days in the latest 3 days. Missing nights are excluded, not counted as no sleep. This is an observed shortfall, not a clinical sleep-debt estimate."))
      }
    }
    let recent = sessions.filter { $0.start >= start(27) && $0.end <= cutoff }
    let rated = recent.filter { TrainingInsights.sessionLoad(for: $0, annotation: annotations[$0.id], maxHR: maxHR) != nil }
    let loadCoverage = recent.isEmpty ? nil : Double(rated.count) / Double(recent.count)
    if historyDays >= 42, rated.count >= 4, (loadCoverage ?? 0) >= 0.7, chronic > 0 {
      parts.append(Part(key: "load", title: "Training demand", value: bounded(75 - max(0, acute / chronic - 1) * 20),
        current: acute, baseline: chronic, unit: "AU/day", weight: 0.10,
        explanation: "7-day vs 42-day exponentially smoothed observed session load. Above-baseline recent demand reduces this component. Load coverage \(Int((loadCoverage ?? 0) * 100))%; missing ratings and missing imported workouts can bias it. No injury-risk or safe-load threshold is inferred."))
    }
    return (parts, signals, baselineDays, debt, loadCoverage)
  }

  private static func fitnessParts(days: [DailyHealthMetrics], sessions: [WorkoutRecord], anchor: Double?, date: Date,
      stepsGoal: Double, exerciseGoal: Double, calendar: Calendar) -> (parts: [Part], observed: Int) {
    let start = calendar.date(byAdding: .day, value: -29, to: date) ?? date
    let recent = days.filter { $0.date >= start && calendar.startOfDay(for: $0.date) <= date }
    let workouts = sessions.filter { $0.start >= start }
    var parts: [Part] = []
    if let current = recent.compactMap({ positive($0.vo2Max) }).last, let anchor, anchor > 0 {
      parts.append(Part(key: "cardio", title: "Cardio", value: bounded(70 + (current / anchor - 1) * 100),
        current: current, baseline: anchor, unit: "mL/kg/min", weight: 0.35,
        explanation: "Latest VO₂ max vs the first 28 recorded calendar days' available VO₂ max mean. This personal reference becomes fixed after that window; it is not a population percentile."))
    }
    let activity = recent.compactMap { day -> Double? in
      var fractions: [Double] = []
      if let value = nonnegative(day.steps), stepsGoal.isFinite, stepsGoal > 0 { fractions.append(min(1, value / stepsGoal)) }
      if let value = nonnegative(day.exerciseMinutes), exerciseGoal.isFinite, exerciseGoal > 0 { fractions.append(min(1, value / exerciseGoal)) }
      return mean(fractions)
    }
    if activity.count >= 7, let average = mean(activity) {
      parts.append(Part(key: "activity", title: "Activity", value: bounded(average * 100), current: average * 100, baseline: 100,
        unit: "% of goals", weight: 0.25, explanation: "30-day mean completion of configured daily step/exercise goals, using recorded days. Changing goals can change recalculated scores."))
    }
    let activeDates = Set(recent.filter { (stepsGoal.isFinite && stepsGoal > 0 && ($0.steps ?? -1) >= stepsGoal) || (exerciseGoal.isFinite && exerciseGoal > 0 && ($0.exerciseMinutes ?? -1) >= exerciseGoal) }
      .map { calendar.startOfDay(for: $0.date) }).union(workouts.filter { $0.minutes >= 10 }.map { calendar.startOfDay(for: $0.start) })
    let observed = Set(recent.map { calendar.startOfDay(for: $0.date) }).union(workouts.map { calendar.startOfDay(for: $0.start) }).count
    if observed >= 14 {
      parts.append(Part(key: "consistency", title: "Consistency", value: bounded(Double(activeDates.count) / 20 * 100),
        current: Double(activeDates.count), baseline: 20, unit: "active days/30d", weight: 0.25,
        explanation: "20 active days per 30-day window maps to 100; an active day meets a movement target or includes 10 workout minutes."))
    }
    if !workouts.isEmpty {
      let strength = workouts.filter { $0.activityType.category == .strength }.count
      parts.append(Part(key: "strength", title: "Strength", value: bounded(Double(strength) / 8 * 100),
        current: Double(strength), baseline: 8, unit: "sessions/30d", weight: 0.15,
        explanation: "Eight strength sessions per 30 days maps to 100. This records training participation, not measured strength or muscle size. Acute recovery is intentionally excluded from fitness."))
    }
    return (parts, observed)
  }

  private static func components(_ parts: [Part]) -> [RecoveryScoreComponent] {
    let total = parts.reduce(0) { $0 + $1.weight }
    guard total > 0 else { return [] }
    return parts.map { part in
      let weight = part.weight / total
      return RecoveryScoreComponent(key: part.key, title: part.title, score: Int(part.value.rounded()),
        current: part.current, baseline: part.baseline, unit: part.unit, effectiveWeight: weight,
        contribution: Double(Int(part.value.rounded())) * weight, explanation: part.explanation)
    }
  }
  private static func combined(_ parts: [RecoveryScoreComponent]) -> Int? {
    guard !parts.isEmpty else { return nil }
    return Int(parts.reduce(0) { $0 + $1.contribution }.rounded())
  }
  private static func bounded(_ value: Double) -> Double { max(0, min(100, value)) }
  private static func positive(_ value: Double?) -> Double? { guard let value, value.isFinite, value > 0 else { return nil }; return value }
  private static func nonnegative(_ value: Double?) -> Double? { guard let value, value.isFinite, value >= 0 else { return nil }; return value }
  private static func mean(_ values: [Double]) -> Double? { values.isEmpty ? nil : values.reduce(0, +) / Double(values.count) }
}
