import Combine
import Foundation
import HealthKit

@MainActor
final class HealthKitClient: ObservableObject {
  @Published private(set) var snapshot: FitnessSnapshot?
  @Published private(set) var authorizationRequested: Bool
  @Published private(set) var isRefreshing = false
  @Published private(set) var hasHealthData = false
  @Published private(set) var lastUpdated: Date?
  @Published private(set) var lastError: String?

  #if os(iOS)
  @Published private(set) var workouts: [WorkoutRecord] = []
  @Published private(set) var analyticsWorkouts: [WorkoutRecord] = []
  @Published private(set) var analyticsHistoryStart: Date?
  @Published private(set) var effortImportStatus: String?
  @Published private(set) var effortImportError: String?
  @Published private(set) var needsHealthAuthorizationReview = false
  private var effortCandidates: [String: [WorkoutEffortCandidate]] = [:]
  @Published private(set) var fitnessReadings: [FitnessReading] = []
  @Published private(set) var dailyMetrics: [DailyHealthMetrics] = []
  @Published private(set) var profile = HealthProfile()
  @Published private(set) var workoutDetailsLoading: Set<String> = []
  @Published private(set) var workoutDetailsError: String?
  private var rawWorkouts: [String: HKWorkout] = [:]
  private var loadedWorkoutDetails: Set<String> = []
  @Published private(set) var historyRange: HistoryRange = .quarter
  @Published private(set) var isLoadingHistory = false
  @Published private(set) var historyError: String?
  private var historyRequest = UUID()
  #endif

  private static let authorizationRequestKey = "RoburHealthKitAuthorizationRequested"

  private let store: HKHealthStore
  private let defaults: UserDefaults

  init(store: HKHealthStore = HKHealthStore(), defaults: UserDefaults = .standard) {
    self.store = store
    self.defaults = defaults
    authorizationRequested = defaults.bool(forKey: Self.authorizationRequestKey)
  }

  var statusText: String {
    if isRefreshing {
      return "Updating Apple Health…"
    }

    if let lastError {
      return lastError
    }

    if hasHealthData, let lastUpdated {
      return "Apple Health updated (\(lastUpdated.formatted(date: .omitted, time: .shortened)))"
    }

    if authorizationRequested {
      return "No approved Apple Health data found yet"
    }

    return "Apple Health ready"
  }

  var promptTitle: String {
    authorizationRequested ? "Refresh Apple Health" : "Connect Apple Health"
  }

  var promptMessage: String {
    if authorizationRequested {
      return "Robur reads approved Health data on this device. Use Access to share effort, steps, exercise, stand time, body measurements and other newly supported categories. Manage existing permissions and history in the Health app."
    }

    return "Robur reads workouts, Fitness effort, sleep, heart metrics, steps, exercise, stand time, body measurements and shared profile information to show your training and progress. Choose which categories and history to share."
  }

  func requestAuthorization() {
    guard !isRefreshing else { return }
    guard HKHealthStore.isHealthDataAvailable() else {
      lastError = "Apple Health is unavailable on this device."
      return
    }

    Task {
      do {
        try await store.requestAuthorization(toShare: Set<HKSampleType>(), read: readTypes)
        authorizationRequested = true
        defaults.set(true, forKey: Self.authorizationRequestKey)
        lastError = nil
        await refreshTodaySnapshot()
      } catch {
        lastError = "Unable to request Apple Health access: \(error.localizedDescription)"
      }
    }
  }

  func refreshTodaySnapshot() async {
    guard authorizationRequested, !isRefreshing else { return }
    guard HKHealthStore.isHealthDataAvailable() else {
      snapshot = RoburData.noHealthData
      hasHealthData = false
      lastError = "Apple Health is unavailable on this device."
      return
    }

    isRefreshing = true
    defer { isRefreshing = false }

    do {
      let metrics = try await readMetrics()
      snapshot = HealthSnapshotBuilder.makeSnapshot(from: metrics)
      hasHealthData = metrics.hasData
      lastUpdated = Date()
      lastError = nil
      #if os(iOS)
      await loadHistory(range: historyRange)
      #endif
    } catch {
      lastError = "Unable to read Apple Health data: \(error.localizedDescription)"
    }
  }

  private var readTypes: Set<HKObjectType> {
    var types: Set<HKObjectType> = [
      HKObjectType.workoutType(),
      HKObjectType.quantityType(forIdentifier: .restingHeartRate)!,
      HKObjectType.quantityType(forIdentifier: .heartRateVariabilitySDNN)!,
      HKObjectType.quantityType(forIdentifier: .distanceCycling)!,
      HKObjectType.categoryType(forIdentifier: .sleepAnalysis)!
    ]
    #if os(iOS)
    types.insert(HKObjectType.quantityType(forIdentifier: .heartRate)!)
    types.insert(HKObjectType.quantityType(forIdentifier: .activeEnergyBurned)!)
    let quantityIdentifiers: [HKQuantityTypeIdentifier] = [
      .vo2Max, .stepCount, .appleExerciseTime, .appleStandTime, .bodyMass,
      .height, .bodyMassIndex, .bodyFatPercentage, .respiratoryRate, .oxygenSaturation,
      .distanceWalkingRunning, .runningStrideLength
    ]
    for identifier in quantityIdentifiers {
      if let type = HKObjectType.quantityType(forIdentifier: identifier) { types.insert(type) }
    }
    let characteristics: [HKCharacteristicTypeIdentifier] = [.dateOfBirth, .biologicalSex, .bloodType]
    for identifier in characteristics {
      if let type = HKObjectType.characteristicType(forIdentifier: identifier) { types.insert(type) }
    }
    if #available(iOS 18.0, *) {
      types.insert(HKObjectType.quantityType(forIdentifier: .workoutEffortScore)!)
      types.insert(HKObjectType.quantityType(forIdentifier: .estimatedWorkoutEffortScore)!)
    }
    #endif
    return types
  }

  private func readMetrics() async throws -> HealthMetrics {
    let now = Date()
    var calendar = Calendar(identifier: .iso8601)
    calendar.timeZone = .current
    let weekStart = calendar.dateInterval(of: .weekOfYear, for: now)?.start ?? now
    let sleepStart = calendar.date(byAdding: .hour, value: -36, to: now) ?? now
    let heartMetricStart = calendar.date(byAdding: .day, value: -7, to: now) ?? now

    async let restingHeartRate = latestQuantity(
      identifier: .restingHeartRate,
      unit: HKUnit.count().unitDivided(by: HKUnit.minute()),
      start: heartMetricStart,
      end: now
    )
    async let heartRateVariability = latestQuantity(
      identifier: .heartRateVariabilitySDNN,
      unit: HKUnit.secondUnit(with: .milli),
      start: heartMetricStart,
      end: now
    )
    async let sleep = sleepMinutes(from: sleepStart, to: now)
    async let cyclingDistance = cumulativeQuantity(
      identifier: .distanceCycling,
      start: weekStart,
      end: now,
      unit: HKUnit.meterUnit(with: .kilo)
    )
    async let workouts = weeklyWorkoutMetrics(from: weekStart, to: now)

    let workoutMetrics = try await workouts
    let cyclingKm = workoutMetrics.cyclingKm > 0
      ? workoutMetrics.cyclingKm
      : try await cyclingDistance

    return HealthMetrics(
      sleepMinutes: try await sleep,
      restingHeartRateBpm: try await restingHeartRate,
      heartRateVariabilityMs: try await heartRateVariability,
      runningKm: workoutMetrics.runningKm,
      cyclingKm: cyclingKm,
      strengthSessions: workoutMetrics.strengthSessions,
      trainingMinutes: workoutMetrics.trainingMinutes,
      workoutCount: workoutMetrics.workoutCount
    )
  }

  private func latestQuantity(
    identifier: HKQuantityTypeIdentifier,
    unit: HKUnit,
    start: Date,
    end: Date
  ) async throws -> Double? {
    guard let sampleType = HKQuantityType.quantityType(forIdentifier: identifier) else {
      return nil
    }

    let predicate = HKQuery.predicateForSamples(
      withStart: start,
      end: end,
      options: [.strictStartDate, .strictEndDate]
    )
    let sortDescriptors = [NSSortDescriptor(key: HKSampleSortIdentifierEndDate, ascending: false)]

    return try await withCheckedThrowingContinuation { continuation in
      let query = HKSampleQuery(
        sampleType: sampleType,
        predicate: predicate,
        limit: 1,
        sortDescriptors: sortDescriptors
      ) { _, samples, error in
        if let error {
          continuation.resume(throwing: error)
          return
        }

        let quantity = (samples?.first as? HKQuantitySample)?.quantity
        continuation.resume(returning: quantity?.doubleValue(for: unit))
      }
      store.execute(query)
    }
  }

  private func cumulativeQuantity(
    identifier: HKQuantityTypeIdentifier,
    start: Date,
    end: Date,
    unit: HKUnit
  ) async throws -> Double? {
    guard let quantityType = HKQuantityType.quantityType(forIdentifier: identifier) else {
      return nil
    }

    let predicate = HKQuery.predicateForSamples(withStart: start, end: end, options: .strictStartDate)

    return try await withCheckedThrowingContinuation { continuation in
      let query = HKStatisticsQuery(
        quantityType: quantityType,
        quantitySamplePredicate: predicate,
        options: .cumulativeSum
      ) { _, result, error in
        if let error {
          continuation.resume(throwing: error)
          return
        }

        continuation.resume(returning: result?.sumQuantity()?.doubleValue(for: unit))
      }
      store.execute(query)
    }
  }

  private func sleepMinutes(from start: Date, to end: Date) async throws -> Int? {
    let sampleType = HKObjectType.categoryType(forIdentifier: .sleepAnalysis)!
    let predicate = HKQuery.predicateForSamples(withStart: start, end: end, options: [])
    let asleepValues: Set<Int> = [
      HKCategoryValueSleepAnalysis.asleepUnspecified.rawValue,
      HKCategoryValueSleepAnalysis.asleepCore.rawValue,
      HKCategoryValueSleepAnalysis.asleepDeep.rawValue,
      HKCategoryValueSleepAnalysis.asleepREM.rawValue
    ]

    let intervals: [DateInterval] = try await withCheckedThrowingContinuation { continuation in
      let query = HKSampleQuery(
        sampleType: sampleType,
        predicate: predicate,
        limit: HKObjectQueryNoLimit,
        sortDescriptors: [NSSortDescriptor(key: HKSampleSortIdentifierStartDate, ascending: true)]
      ) { _, samples, error in
        if let error {
          continuation.resume(throwing: error)
          return
        }

        let intervals = (samples ?? []).compactMap { sample -> DateInterval? in
          guard let category = sample as? HKCategorySample,
                asleepValues.contains(category.value) else {
            return nil
          }

          let intervalStart = max(category.startDate, start)
          let intervalEnd = min(category.endDate, end)
          guard intervalEnd > intervalStart else {
            return nil
          }

          return DateInterval(start: intervalStart, end: intervalEnd)
        }
        continuation.resume(returning: intervals)
      }
      store.execute(query)
    }

    let mergedIntervals = merge(intervals: intervals)
    let minutes = Int((mergedIntervals.reduce(0) { $0 + $1.duration } / 60).rounded())
    return minutes > 0 ? minutes : nil
  }

  private func weeklyWorkoutMetrics(from start: Date, to end: Date) async throws -> WeeklyWorkoutMetrics {
    let predicate = HKQuery.predicateForSamples(withStart: start, end: end, options: .strictStartDate)
    let sortDescriptors = [NSSortDescriptor(key: HKSampleSortIdentifierStartDate, ascending: false)]

    return try await withCheckedThrowingContinuation { continuation in
      let query = HKSampleQuery(
        sampleType: HKObjectType.workoutType(),
        predicate: predicate,
        limit: HKObjectQueryNoLimit,
        sortDescriptors: sortDescriptors
      ) { _, samples, error in
        if let error {
          continuation.resume(throwing: error)
          return
        }

        let workouts = (samples ?? []).compactMap { $0 as? HKWorkout }
        let runningWorkouts = workouts.filter { $0.workoutActivityType == .running }
        let cyclingWorkouts = workouts.filter { $0.workoutActivityType == .cycling }
        let strengthSessions = workouts.filter {
          $0.workoutActivityType == .traditionalStrengthTraining ||
            $0.workoutActivityType == .functionalStrengthTraining
        }.count
        let distanceUnit = HKUnit.meterUnit(with: .kilo)

        continuation.resume(
          returning: WeeklyWorkoutMetrics(
            runningKm: runningWorkouts.reduce(0) { total, workout in
              total + (workout.totalDistance?.doubleValue(for: distanceUnit) ?? 0)
            },
            cyclingKm: cyclingWorkouts.reduce(0) { total, workout in
              total + (workout.totalDistance?.doubleValue(for: distanceUnit) ?? 0)
            },
            strengthSessions: strengthSessions,
            trainingMinutes: Int((workouts.reduce(0) { $0 + $1.duration } / 60).rounded()),
            workoutCount: workouts.count
          )
        )
      }
      store.execute(query)
    }
  }

  private func merge(intervals: [DateInterval]) -> [DateInterval] {
    let sortedIntervals = intervals.sorted { $0.start < $1.start }
    guard var current = sortedIntervals.first else {
      return []
    }

    var merged: [DateInterval] = []
    for interval in sortedIntervals.dropFirst() {
      if interval.start <= current.end {
        current = DateInterval(start: current.start, end: max(current.end, interval.end))
      } else {
        merged.append(current)
        current = interval
      }
    }
    merged.append(current)
    return merged
  }
}

private struct WeeklyWorkoutMetrics {
  let runningKm: Double
  let cyclingKm: Double
  let strengthSessions: Int
  let trainingMinutes: Int
  let workoutCount: Int
}

#if os(iOS)
extension HealthKitClient {
  #if DEBUG
  // Explicitly injected data for simulator presentation tests; the app uses the default initializer.
  convenience init(previewWorkouts: [WorkoutRecord], previewReadings: [FitnessReading], defaults: UserDefaults,
                   previewDays: [DailyHealthMetrics] = [], previewProfile: HealthProfile = HealthProfile()) {
    self.init(defaults: defaults)
    workouts = previewWorkouts
    analyticsWorkouts = previewWorkouts
    analyticsHistoryStart = previewWorkouts.map(\.start).min()
    fitnessReadings = previewReadings
    dailyMetrics = previewDays
    profile = previewProfile
  }
  #endif

  func loadHistory(range: HistoryRange) async {
    guard authorizationRequested, HKHealthStore.isHealthDataAvailable() else { return }
    if isLoadingHistory && range == historyRange { return }
    if historyRange != range { workouts = []; fitnessReadings = [] }
    historyRange = range
    let request = UUID()
    historyRequest = request
    isLoadingHistory = true
    historyError = nil
    effortImportError = nil
    defer { if historyRequest == request { isLoadingHistory = false } }
    await refreshHealthAuthorizationReview()
    let now = Date()
    let visibleStart = range.startDate(now: now) ?? store.earliestPermittedSampleDate()
    // Analytics always retain enough data for independent 7/28/30/90-day baselines.
    let baselineStart = Calendar.current.date(byAdding: .day, value: -91, to: now) ?? visibleStart
    let healthStart = min(visibleStart, baselineStart)
    do {
      async let workoutSamples = historySamples(type: HKObjectType.workoutType(), start: healthStart, end: now)
      async let healthHistory = readDailyHealth(from: healthStart, to: now)
      async let userProfile = readProfile(now: now)
      async let effort = readWorkoutEffort()
      let samples = try await workoutSamples
      let history = await healthHistory
      let profileResult = await userProfile
      let effortResult = await effort
      let effortScores = effortResult.values
      guard historyRequest == request else { return }
      let imported = samples.compactMap { $0 as? HKWorkout }
      let recentHeart = await readRecentWorkoutHeartRates(imported, now: now)
      guard historyRequest == request else { return }
      rawWorkouts = Dictionary(uniqueKeysWithValues: imported.map { ($0.uuid.uuidString, $0) })
      loadedWorkoutDetails = []
      effortCandidates = effortResult.candidates
      effortImportError = effortResult.error
      analyticsHistoryStart = healthStart
      analyticsWorkouts = imported.map { workout in
        let heartType = HKQuantityType.quantityType(forIdentifier: .heartRate)!
        let energyType = HKQuantityType.quantityType(forIdentifier: .activeEnergyBurned)!
        let info = Self.workoutPresentation(workout.workoutActivityType)
        return WorkoutRecord(id: workout.uuid.uuidString, start: workout.startDate, end: workout.endDate,
          title: info.0, symbol: info.1, minutes: workout.duration / 60,
          distanceKm: workout.totalDistance?.doubleValue(for: .meterUnit(with: .kilo)),
          energyKcal: workout.statistics(for: energyType)?.sumQuantity()?.doubleValue(for: .kilocalorie()),
          averageHeartRate: workout.statistics(for: heartType)?.averageQuantity()?.doubleValue(for: HKUnit.count().unitDivided(by: .minute())),
          source: workout.sourceRevision.source.name, appleEffort: effortScores[workout.uuid.uuidString]?.score,
          heartRateSamples: recentHeart[workout.uuid.uuidString] ?? [],
          effortSource: effortScores[workout.uuid.uuidString]?.source,
          activityType: Self.workoutActivity(workout.workoutActivityType))
      }
      workouts = analyticsWorkouts.filter { $0.start >= visibleStart }
      updateEffortStatus()
      fitnessReadings = history.readings.filter { $0.date >= Calendar.current.startOfDay(for: visibleStart) && $0.date <= now }
      dailyMetrics = history.days.filter { $0.date <= now }
      profile = profileResult
    } catch {
      guard historyRequest == request else { return }
      historyError = "Unable to load history: \(error.localizedDescription). Pull to refresh to retry."
    }
  }

  func refreshHealthAuthorizationReview() async {
    // The old authorizationRequested flag only records that a sheet was shown.
    // It does not mean newly introduced read types have ever been requested.
    let status = try? await store.statusForAuthorizationRequest(toShare: [], read: readTypes)
    needsHealthAuthorizationReview = status == .shouldRequest
  }

  private struct EffortImportResult {
    var values: [String: WorkoutEffortSelection] = [:]
    var candidates: [String: [WorkoutEffortCandidate]] = [:]
    var error: String? = nil
  }

  /// Import all scopes, including the workout's default activity. Older versions
  /// discarded non-nil activities, which silently omitted real Fitness ratings.
  private func readWorkoutEffort() async -> EffortImportResult {
    guard #available(iOS 18.0, *) else {
      return EffortImportResult(error: "Apple Fitness effort requires iOS 18 or later.")
    }
    do {
      let relationships: [HKWorkoutEffortRelationship] = try await withCheckedThrowingContinuation { continuation in
        let query = HKWorkoutEffortRelationshipQuery(predicate: nil, anchor: nil, options: .default) { _, relationships, _, error in
          if let error { continuation.resume(throwing: error) }
          else { continuation.resume(returning: relationships ?? []) }
        }
        store.execute(query)
      }
      var result = EffortImportResult()
      for relationship in relationships {
        let id = relationship.workout.uuid.uuidString
        let values = effortValues(samples: relationship.samples ?? [], activity: relationship.activity)
        result.candidates[id, default: []].append(contentsOf: values)
      }
      result.values = result.candidates.compactMapValues { HealthImportMath.effort($0) }
      return result
    } catch {
      return EffortImportResult(error: "Effort relationships could not be read: \(error.localizedDescription). Review Health access or open a workout to retry its effort.")
    }
  }

  @available(iOS 18.0, *)
  private func effortValues(samples: [HKSample], activity: HKWorkoutActivity?) -> [WorkoutEffortCandidate] {
    samples.compactMap { sample in
      guard let quantity = sample as? HKQuantitySample else { return nil }
      let source: WorkoutEffortSource
      switch quantity.quantityType.identifier {
      case HKQuantityTypeIdentifier.workoutEffortScore.rawValue: source = .reported
      case HKQuantityTypeIdentifier.estimatedWorkoutEffortScore.rawValue: source = .estimated
      default: return nil
      }
      return WorkoutEffortCandidate(score: quantity.quantity.doubleValue(for: .appleEffortScore()),
        source: source, date: quantity.endDate, activityID: activity?.uuid.uuidString,
        durationMinutes: activity.map { $0.duration / 60 }, sampleID: quantity.uuid.uuidString)
    }
  }

  private func refreshRelatedEffort(for workout: HKWorkout) async {
    guard #available(iOS 18.0, *) else { return }
    let id = workout.uuid.uuidString
    var candidates = effortCandidates[id] ?? []
    var failures = 0
    // Association predicates, not timestamps, recover scores missing from the
    // relationship query. Activity scores can live on any constituent activity.
    let scopes: [HKWorkoutActivity?] = [nil] + workout.workoutActivities.map { Optional($0) }
    for activity in scopes {
      let predicate = HKQuery.predicateForWorkoutEffortSamplesRelated(workout: workout, activity: activity)
      let identifiers: [HKQuantityTypeIdentifier] = [.workoutEffortScore, .estimatedWorkoutEffortScore]
      for identifier in identifiers {
        do {
          let samples = try await associatedSamples(identifier: identifier, predicate: predicate)
          candidates.append(contentsOf: effortValues(samples: samples, activity: activity))
        } catch { failures += 1 }
      }
    }
    candidates = Array(Set(candidates))
    effortCandidates[id] = candidates
    if let selection = HealthImportMath.effort(candidates) {
      if let index = workouts.firstIndex(where: { $0.id == id }) {
        workouts[index].appleEffort = selection.score
        workouts[index].effortSource = selection.source
      }
      if let index = analyticsWorkouts.firstIndex(where: { $0.id == id }) {
        analyticsWorkouts[index].appleEffort = selection.score
        analyticsWorkouts[index].effortSource = selection.source
      }
    }
    if failures > 0 {
      effortImportError = "Some associated effort data could not be read. Available ratings are still shown; review Robur's Health access and retry."
    }
    updateEffortStatus()
  }

  private func updateEffortStatus() {
    guard #available(iOS 18.0, *) else {
      effortImportStatus = "Apple Fitness effort requires iOS 18 or later."
      return
    }
    let reported = workouts.filter { $0.effortSource == .reported }.count
    let estimated = workouts.filter { $0.effortSource == .estimated }.count
    if reported + estimated > 0 {
      effortImportStatus = "\(reported) Fitness ratings · \(estimated) Apple estimates. Recorded ratings take priority over estimates."
    } else {
      let review = needsHealthAuthorizationReview ? "New Health categories need review. Use Access to request workout effort, then refresh. " : ""
      effortImportStatus = review + "No Apple Fitness effort shared for these workouts. Review workout effort in Robur's Health access, then refresh. Opening a workout retries its associated ratings."
    }
  }

  func loadWorkoutDetails(id: String) async {
    guard !workoutDetailsLoading.contains(id), let workout = rawWorkouts[id] else { return }
    workoutDetailsLoading.insert(id)
    defer { workoutDetailsLoading.remove(id) }
    workoutDetailsError = nil
    await refreshRelatedEffort(for: workout)
    guard !loadedWorkoutDetails.contains(id) else { return }
    do {
      let associated = HKQuery.predicateForObjects(from: workout)
      async let heart = try? associatedSamples(identifier: .heartRate, predicate: associated)
      async let steps = try? associatedSamples(identifier: .stepCount, predicate: associated)
      async let distances = try? associatedSamples(identifier: workout.workoutActivityType == .cycling ? .distanceCycling : .distanceWalkingRunning, predicate: associated)
      let heartResult = await heart
      let stepsResult = await steps
      let distanceResult = await distances
      let heartSamples = heartResult ?? []
      let stepSamples = stepsResult ?? []
      let distanceSamples = distanceResult ?? []
      let bpm = HKUnit.count().unitDivided(by: .minute())
      let heartValues = heartSamples.map { WorkoutHeartSample(date: $0.startDate, bpm: $0.quantity.doubleValue(for: bpm)) }
      let totalSteps = stepSamples.reduce(0) { $0 + $1.quantity.doubleValue(for: .count()) }
      var splits: [WorkoutSplit] = []
      var coveredKm = 0.0
      var splitStart = workout.startDate
      for sample in distanceSamples {
        let distance = sample.quantity.doubleValue(for: .meterUnit(with: .kilo))
        guard distance > 0, sample.endDate > sample.startDate else { continue }
        var remaining = distance
        var cursor = sample.startDate
        let secondsPerKm = sample.endDate.timeIntervalSince(sample.startDate) / distance
        while coveredKm + remaining >= 1 {
          let needed = 1 - coveredKm
          let boundary = cursor.addingTimeInterval(needed * secondsPerKm)
          splits.append(WorkoutSplit(index: splits.count + 1, minutes: boundary.timeIntervalSince(splitStart) / 60, distanceKm: 1))
          splitStart = boundary
          cursor = boundary
          remaining -= needed
          coveredKm = 0
        }
        coveredKm += remaining
      }
      if let index = workouts.firstIndex(where: { $0.id == id }) {
        workouts[index].heartRateSamples = heartValues
        workouts[index].splits = splits
        if totalSteps > 0 && workout.duration > 0 { workouts[index].cadence = totalSteps / (workout.duration / 60) }
      }
      if let index = analyticsWorkouts.firstIndex(where: { $0.id == id }) {
        analyticsWorkouts[index].heartRateSamples = heartValues
        analyticsWorkouts[index].splits = splits
        if totalSteps > 0 && workout.duration > 0 { analyticsWorkouts[index].cadence = totalSteps / (workout.duration / 60) }
      }
      if heartResult != nil && stepsResult != nil && distanceResult != nil { loadedWorkoutDetails.insert(id) }
      else { workoutDetailsError = "Some workout details are unavailable. Approved data is still shown; reopen to retry." }
    }
  }

  private func readRecentWorkoutHeartRates(_ workouts: [HKWorkout], now: Date) async -> [String: [WorkoutHeartSample]] {
    let cutoff = Calendar.current.date(byAdding: .day, value: -30, to: now) ?? now
    let recent = workouts.filter { $0.startDate >= cutoff }
    guard !recent.isEmpty else { return [:] }
    let predicate = NSCompoundPredicate(orPredicateWithSubpredicates: recent.map { HKQuery.predicateForObjects(from: $0) })
    guard let samples = try? await associatedSamples(identifier: .heartRate, predicate: predicate) else { return [:] }
    let unit = HKUnit.count().unitDivided(by: .minute())
    var result: [String: [WorkoutHeartSample]] = [:]
    for sample in samples {
      let matches = recent.filter { sample.startDate >= $0.startDate && sample.startDate < $0.endDate }
      // Overlapping workouts cannot safely be attributed by time after a bulk query.
      // Their exact associations are loaded on demand when opening the workout.
      guard matches.count == 1, let workout = matches.first else { continue }
      let bpm = sample.quantity.doubleValue(for: unit)
      guard bpm.isFinite, bpm > 0 else { continue }
      result[workout.uuid.uuidString, default: []].append(WorkoutHeartSample(date: sample.startDate, bpm: bpm))
    }
    return result
  }

  private func associatedSamples(identifier: HKQuantityTypeIdentifier, predicate: NSPredicate) async throws -> [HKQuantitySample] {
    guard let type = HKQuantityType.quantityType(forIdentifier: identifier) else { return [] }
    return try await withCheckedThrowingContinuation { continuation in
      let query = HKSampleQuery(sampleType: type, predicate: predicate, limit: HKObjectQueryNoLimit,
        sortDescriptors: [NSSortDescriptor(key: HKSampleSortIdentifierStartDate, ascending: true)]) { _, samples, error in
        if let error { continuation.resume(throwing: error) }
        else { continuation.resume(returning: (samples ?? []).compactMap { $0 as? HKQuantitySample }) }
      }
      store.execute(query)
    }
  }

  private struct DailyQuantitySpec {
    let metric: FitnessMetric
    let identifier: HKQuantityTypeIdentifier
    let unit: HKUnit
    let cumulative: Bool
  }

  private func readDailyHealth(from start: Date, to end: Date) async -> (days: [DailyHealthMetrics], readings: [FitnessReading]) {
    let specs: [DailyQuantitySpec] = [
      DailyQuantitySpec(metric: .steps, identifier: .stepCount, unit: .count(), cumulative: true),
      DailyQuantitySpec(metric: .exercise, identifier: .appleExerciseTime, unit: .minute(), cumulative: true),
      DailyQuantitySpec(metric: .stand, identifier: .appleStandTime, unit: .minute(), cumulative: true),
      DailyQuantitySpec(metric: .energy, identifier: .activeEnergyBurned, unit: .kilocalorie(), cumulative: true),
      DailyQuantitySpec(metric: .restingHR, identifier: .restingHeartRate, unit: HKUnit.count().unitDivided(by: .minute()), cumulative: false),
      DailyQuantitySpec(metric: .hrv, identifier: .heartRateVariabilitySDNN, unit: .secondUnit(with: .milli), cumulative: false),
      DailyQuantitySpec(metric: .cardio, identifier: .vo2Max, unit: HKUnit(from: "ml/kg*min"), cumulative: false),
      DailyQuantitySpec(metric: .weight, identifier: .bodyMass, unit: .gramUnit(with: .kilo), cumulative: false),
      DailyQuantitySpec(metric: .bodyFat, identifier: .bodyFatPercentage, unit: .percent(), cumulative: false),
      DailyQuantitySpec(metric: .bmi, identifier: .bodyMassIndex, unit: .count(), cumulative: false),
      DailyQuantitySpec(metric: .height, identifier: .height, unit: .meterUnit(with: .centi), cumulative: false),
      DailyQuantitySpec(metric: .respiratoryRate, identifier: .respiratoryRate, unit: HKUnit.count().unitDivided(by: .minute()), cumulative: false),
      DailyQuantitySpec(metric: .oxygenSaturation, identifier: .oxygenSaturation, unit: .percent(), cumulative: false)
    ]
    var values: [FitnessMetric: [Date: Double]] = [:]
    // Ask HealthKit for consolidated cumulative statistics; never manually sum per-source totals.
    await withTaskGroup(of: (FitnessMetric, [Date: Double]).self) { group in
      for spec in specs {
        group.addTask { [self] in
          let daily = (try? await dailyQuantities(spec: spec, start: start, end: end)) ?? [:]
          return (spec.metric, daily)
        }
      }
      for await (metric, daily) in group { values[metric] = daily }
    }
    values[.sleep] = (try? await dailySleep(from: start, to: end)) ?? [:]
    let calendar = Calendar.current
    let dates = Set(values.values.flatMap { $0.keys }).sorted()
    let days = dates.map { date in
      DailyHealthMetrics(date: date, sleepMinutes: values[.sleep]?[date], steps: values[.steps]?[date],
        exerciseMinutes: values[.exercise]?[date], standMinutes: values[.stand]?[date],
        activeEnergyKcal: values[.energy]?[date], restingHR: values[.restingHR]?[date],
        hrv: values[.hrv]?[date], vo2Max: values[.cardio]?[date], weightKg: values[.weight]?[date])
    }
    let readings = values.flatMap { metric, daily in
      daily.map { date, value in
        FitnessReading(id: "\(metric.rawValue)-\(calendar.startOfDay(for: date).timeIntervalSince1970)", date: date, value: value, metric: metric)
      }
    }.sorted { $0.date < $1.date }
    return (days, readings)
  }

  private func dailyQuantities(spec: DailyQuantitySpec, start: Date, end: Date) async throws -> [Date: Double] {
    guard let type = HKQuantityType.quantityType(forIdentifier: spec.identifier) else { return [:] }
    let predicate = HKQuery.predicateForSamples(withStart: start, end: end, options: .strictStartDate)
    return try await withCheckedThrowingContinuation { continuation in
      let query = HKStatisticsCollectionQuery(quantityType: type, quantitySamplePredicate: predicate,
        options: spec.cumulative ? .cumulativeSum : .discreteAverage,
        anchorDate: Calendar.current.startOfDay(for: end), intervalComponents: DateComponents(day: 1))
      query.initialResultsHandler = { _, collection, error in
        if let error { continuation.resume(throwing: error); return }
        var result: [Date: Double] = [:]
        collection?.enumerateStatistics(from: start, to: end) { statistics, _ in
          let quantity = spec.cumulative ? statistics.sumQuantity() : statistics.averageQuantity()
          if var value = quantity?.doubleValue(for: spec.unit), value.isFinite, value >= 0 {
            if spec.metric == .bodyFat || spec.metric == .oxygenSaturation { value *= 100 }
            result[statistics.startDate] = value
          }
        }
        continuation.resume(returning: result)
      }
      store.execute(query)
    }
  }

  private func dailySleep(from start: Date, to end: Date) async throws -> [Date: Double] {
    let samples = try await historySamples(type: HKObjectType.categoryType(forIdentifier: .sleepAnalysis)!, start: start, end: end, options: [])
    let asleep: Set<Int> = [HKCategoryValueSleepAnalysis.asleepUnspecified.rawValue,
      HKCategoryValueSleepAnalysis.asleepCore.rawValue, HKCategoryValueSleepAnalysis.asleepDeep.rawValue,
      HKCategoryValueSleepAnalysis.asleepREM.rawValue]
    let intervals = samples.compactMap { sample -> DateInterval? in
      guard let sample = sample as? HKCategorySample, asleep.contains(sample.value) else { return nil }
      let clippedStart = max(start, sample.startDate)
      let clippedEnd = min(end, sample.endDate)
      return clippedEnd > clippedStart ? DateInterval(start: clippedStart, end: clippedEnd) : nil
    }
    return HealthImportMath.sleepMinutes(intervals: intervals, calendar: .current, wakingDay: true)
  }

  private func readProfile(now: Date) async -> HealthProfile {
    let start = store.earliestPermittedSampleDate()
    async let weight = try? latestQuantity(identifier: .bodyMass, unit: .gramUnit(with: .kilo), start: start, end: now)
    async let height = try? latestQuantity(identifier: .height, unit: .meterUnit(with: .centi), start: start, end: now)
    async let fat = try? latestQuantity(identifier: .bodyFatPercentage, unit: .percent(), start: start, end: now)
    async let bmi = try? latestQuantity(identifier: .bodyMassIndex, unit: .count(), start: start, end: now)
    var result = HealthProfile()
    if let birth = try? store.dateOfBirthComponents(), birth.year != nil, birth.month != nil, birth.day != nil,
       let date = Calendar.current.date(from: birth) {
      result.age = Calendar.current.dateComponents([.year], from: date, to: now).year
    }
    if let sex = try? store.biologicalSex().biologicalSex {
      switch sex {
      case .female: result.biologicalSex = "Female"
      case .male: result.biologicalSex = "Male"
      case .other: result.biologicalSex = "Other"
      default: break
      }
    }
    if let blood = try? store.bloodType().bloodType {
      switch blood {
      case .aPositive: result.bloodType = "A+"
      case .aNegative: result.bloodType = "A−"
      case .bPositive: result.bloodType = "B+"
      case .bNegative: result.bloodType = "B−"
      case .abPositive: result.bloodType = "AB+"
      case .abNegative: result.bloodType = "AB−"
      case .oPositive: result.bloodType = "O+"
      case .oNegative: result.bloodType = "O−"
      default: break
      }
    }
    result.weightKg = await weight
    result.heightCm = await height
    result.bodyFatPercent = (await fat).map { $0 * 100 }
    result.bmi = await bmi
    return result
  }

  private func historySamples(type: HKSampleType, start: Date, end: Date, options: HKQueryOptions = .strictStartDate) async throws -> [HKSample] {
    let predicate = HKQuery.predicateForSamples(withStart: start, end: end, options: options)
    return try await withCheckedThrowingContinuation { continuation in
      let query = HKSampleQuery(sampleType: type, predicate: predicate, limit: HKObjectQueryNoLimit,
        sortDescriptors: [NSSortDescriptor(key: HKSampleSortIdentifierStartDate, ascending: false)]) { _, samples, error in
        if let error { continuation.resume(throwing: error) }
        else { continuation.resume(returning: samples ?? []) }
      }
      store.execute(query)
    }
  }

  private func historyReadings(identifier: HKQuantityTypeIdentifier, metric: FitnessMetric,
                               unit: HKUnit, start: Date, end: Date) async throws -> [FitnessReading] {
    let samples = try await historySamples(type: HKQuantityType.quantityType(forIdentifier: identifier)!, start: start, end: end)
    return samples.compactMap { sample in
      guard let quantity = sample as? HKQuantitySample else { return nil }
      return FitnessReading(id: quantity.uuid.uuidString, date: quantity.startDate,
                            value: quantity.quantity.doubleValue(for: unit), metric: metric)
    }
  }

  static func workoutActivity(_ type: HKWorkoutActivityType) -> WorkoutActivity {
    switch type {
    case .running: return .running
    case .cycling: return .cycling
    case .walking: return .walking
    case .swimming: return .swimming
    case .tennis: return .tennis
    case .badminton, .pickleball, .racquetball, .squash, .tableTennis: return .racketSports
    case .traditionalStrengthTraining: return .traditionalStrength
    case .functionalStrengthTraining: return .functionalStrength
    case .highIntensityIntervalTraining: return .hiit
    case .yoga, .pilates, .flexibility, .mindAndBody, .taiChi, .barre, .preparationAndRecovery, .cooldown: return .mobility
    case .hiking: return .hiking
    case .rowing: return .rowing
    default: return .other
    }
  }

  static func workoutPresentation(_ type: HKWorkoutActivityType) -> (String, String) {
    switch type {
    case .running: return ("Run", "figure.run")
    case .cycling: return ("Cycle", "figure.outdoor.cycle")
    case .traditionalStrengthTraining: return ("Strength", "dumbbell.fill")
    case .functionalStrengthTraining: return ("Functional strength", "figure.strengthtraining.functional")
    case .walking: return ("Walk", "figure.walk")
    case .hiking: return ("Hike", "figure.hiking")
    case .swimming: return ("Swim", "figure.pool.swim")
    case .tennis: return ("Tennis", "figure.tennis")
    case .badminton: return ("Badminton", "figure.badminton")
    case .pickleball: return ("Pickleball", "figure.pickleball")
    case .racquetball: return ("Racquetball", "figure.racquetball")
    case .squash: return ("Squash", "figure.squash")
    case .tableTennis: return ("Table tennis", "figure.table.tennis")
    case .yoga: return ("Yoga", "figure.yoga")
    case .pilates: return ("Pilates", "figure.pilates")
    case .highIntensityIntervalTraining: return ("Intervals", "bolt.heart.fill")
    case .rowing: return ("Row", "figure.rower")
    case .elliptical: return ("Elliptical", "figure.elliptical")
    case .stairClimbing, .stairs, .stepTraining: return ("Stairs", "figure.stair.stepper")
    case .dance, .cardioDance, .socialDance: return ("Dance", "figure.dance")
    case .coreTraining: return ("Core", "figure.core.training")
    case .flexibility: return ("Flexibility", "figure.flexibility")
    case .taiChi: return ("Tai chi", "figure.taichi")
    case .barre: return ("Barre", "figure.barre")
    case .mindAndBody: return ("Mind and body", "figure.mind.and.body")
    case .preparationAndRecovery, .cooldown: return ("Recovery", "figure.cooldown")
    case .mixedCardio, .crossTraining: return ("Mixed cardio", "figure.mixed.cardio")
    case .soccer: return ("Football", "figure.soccer")
    case .basketball: return ("Basketball", "figure.basketball")
    case .volleyball: return ("Volleyball", "figure.volleyball")
    case .baseball: return ("Baseball", "figure.baseball")
    case .softball: return ("Softball", "figure.softball")
    case .golf: return ("Golf", "figure.golf")
    case .boxing: return ("Boxing", "figure.boxing")
    case .kickboxing: return ("Kickboxing", "figure.kickboxing")
    case .martialArts: return ("Martial arts", "figure.martial.arts")
    case .wrestling: return ("Wrestling", "figure.wrestling")
    case .climbing: return ("Climbing", "figure.climbing")
    case .skatingSports: return ("Skating", "figure.skating")
    case .snowboarding: return ("Snowboarding", "figure.snowboarding")
    case .downhillSkiing: return ("Downhill skiing", "figure.skiing.downhill")
    case .crossCountrySkiing: return ("Cross-country skiing", "figure.skiing.crosscountry")
    case .paddleSports: return ("Paddling", "figure.rower")
    case .surfingSports: return ("Surfing", "figure.surfing")
    case .waterFitness: return ("Water fitness", "figure.water.fitness")
    case .waterPolo: return ("Water polo", "figure.waterpolo")
    case .waterSports: return ("Water sport", "figure.water.fitness")
    case .jumpRope: return ("Jump rope", "figure.jumprope")
    case .trackAndField: return ("Track and field", "figure.track.and.field")
    case .handball: return ("Handball", "figure.handball")
    case .rugby: return ("Rugby", "figure.rugby")
    case .americanFootball: return ("American football", "figure.american.football")
    case .australianFootball: return ("Australian football", "figure.australian.football")
    case .hockey: return ("Hockey", "figure.hockey")
    case .gymnastics: return ("Gymnastics", "figure.gymnastics")
    case .equestrianSports: return ("Equestrian", "figure.equestrian.sports")
    case .fitnessGaming: return ("Fitness gaming", "figure.play")
    default: return ("Other workout", "figure.mixed.cardio")
    }
  }
}
#endif
