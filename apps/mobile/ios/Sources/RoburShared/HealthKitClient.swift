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
      return "Robur reads your approved Health data on this device. If values are missing, check Robur's access in the Health app."
    }

    return "Robur reads workouts, sleep, resting heart rate, HRV, running distance, and cycling distance to calculate today's recommendation."
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
    } catch {
      lastError = "Unable to read Apple Health data: \(error.localizedDescription)"
    }
  }

  private var readTypes: Set<HKObjectType> {
    Set([
      HKObjectType.workoutType(),
      HKObjectType.quantityType(forIdentifier: .restingHeartRate)!,
      HKObjectType.quantityType(forIdentifier: .heartRateVariabilitySDNN)!,
      HKObjectType.quantityType(forIdentifier: .distanceCycling)!,
      HKObjectType.categoryType(forIdentifier: .sleepAnalysis)!
    ])
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
