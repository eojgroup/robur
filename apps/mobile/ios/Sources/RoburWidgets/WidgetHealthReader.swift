import Foundation
import HealthKit

/// Coalesce simultaneous requests from the recovery, training and cardio widgets.
actor WidgetHealthCache {
  static let shared = WidgetHealthCache()
  private var pending: Task<WidgetHealthSummary, Never>?
  private var cached: WidgetHealthSummary?
  func read() async -> WidgetHealthSummary {
    if let cached, Date().timeIntervalSince(cached.refreshedAt) >= 0,
      Date().timeIntervalSince(cached.refreshedAt) < 5 { return cached }
    if let pending { return await pending.value }
    let task = Task { await WidgetHealthReader().read() }
    pending = task
    let result = await task.value
    cached = result; pending = nil
    return result
  }
}

/// Reads only types already approved in the containing app. Never prompts from a widget.
final class WidgetHealthReader: @unchecked Sendable {
  private let store = HKHealthStore()

  func read(now: Date = Date()) async -> WidgetHealthSummary {
    guard HKHealthStore.isHealthDataAvailable() else { return WidgetHealthSummary(refreshedAt: now) }
    let start = Calendar.current.date(byAdding: .day, value: -35, to: Calendar.current.startOfDay(for: now))!
    async let hrv = quantity(.heartRateVariabilitySDNN, unit: .secondUnit(with: .milli), cumulative: false, from: start, to: now)
    async let resting = quantity(.restingHeartRate, unit: HKUnit.count().unitDivided(by: .minute()), cumulative: false, from: start, to: now)
    async let steps = quantity(.stepCount, unit: .count(), cumulative: true, from: start, to: now)
    async let exercise = quantity(.appleExerciseTime, unit: .minute(), cumulative: true, from: start, to: now)
    async let cardio = quantity(.vo2Max, unit: HKUnit(from: "ml/kg*min"), cumulative: false, from: start, to: now)
    async let sleeping = samples(type: HKObjectType.categoryType(forIdentifier: .sleepAnalysis)!, from: start, to: now)
    async let sessions = samples(type: HKObjectType.workoutType(), from: start, to: now)
    let (h, r, s, e, c, sleep, workouts) = await (hrv, resting, steps, exercise, cardio, sleeping, sessions)
    let asleep = Set([HKCategoryValueSleepAnalysis.asleepUnspecified, .asleepCore, .asleepDeep, .asleepREM].map(\.rawValue))
    let intervals = sleep.compactMap { sample -> DateInterval? in
      guard let sample = sample as? HKCategorySample, asleep.contains(sample.value) else { return nil }
      let a = max(start, sample.startDate), b = min(now, sample.endDate)
      return b > a ? DateInterval(start: a, end: b) : nil
    }
    let sleepDays = HealthImportMath.sleepMinutes(intervals: intervals, calendar: .current, wakingDay: true)
    let dates = Set(h.keys).union(r.keys).union(s.keys).union(e.keys).union(c.keys).union(sleepDays.keys)
    let days = dates.sorted().map { date in
      DailyHealthMetrics(date: date, sleepMinutes: sleepDays[date], steps: s[date], exerciseMinutes: e[date],
        restingHR: r[date], hrv: h[date], vo2Max: c[date])
    }
    let records = workouts.compactMap { $0 as? HKWorkout }.map { workout in
      let hrType = HKQuantityType.quantityType(forIdentifier: .heartRate)!
      return WorkoutRecord(id: workout.uuid.uuidString, start: workout.startDate, end: workout.endDate,
        title: "Workout", symbol: "figure.run", minutes: workout.duration / 60,
        distanceKm: workout.totalDistance?.doubleValue(for: .meterUnit(with: .kilo)), energyKcal: nil,
        averageHeartRate: workout.statistics(for: hrType)?.averageQuantity()?.doubleValue(for: HKUnit.count().unitDivided(by: .minute())),
        source: "Health")
    }
    return WidgetHealthSummary.make(days: days, workouts: records, now: now)
  }

  private func samples(type: HKSampleType, from start: Date, to end: Date) async -> [HKSample] {
    await withCheckedContinuation { continuation in
      let gate = HealthQueryCompletionGate()
      let predicate = HKQuery.predicateForSamples(withStart: start, end: end, options: [])
      let query = HKSampleQuery(sampleType: type, predicate: predicate, limit: HKObjectQueryNoLimit, sortDescriptors: nil) { [store] query, samples, _ in
        guard gate.claim() else { return }; store.stop(query)
        continuation.resume(returning: samples ?? [])
      }
      store.execute(query)
      DispatchQueue.global().asyncAfter(deadline: .now() + 5) { [store] in
        guard gate.claim() else { return }; store.stop(query); continuation.resume(returning: [])
      }
    }
  }

  private func quantity(_ identifier: HKQuantityTypeIdentifier, unit: HKUnit, cumulative: Bool, from start: Date, to end: Date) async -> [Date: Double] {
    guard let type = HKQuantityType.quantityType(forIdentifier: identifier) else { return [:] }
    return await withCheckedContinuation { continuation in
      let gate = HealthQueryCompletionGate()
      let predicate = HKQuery.predicateForSamples(withStart: start, end: end, options: .strictStartDate)
      let query = HKStatisticsCollectionQuery(quantityType: type, quantitySamplePredicate: predicate,
        options: cumulative ? .cumulativeSum : .discreteAverage, anchorDate: Calendar.current.startOfDay(for: end), intervalComponents: DateComponents(day: 1))
      query.initialResultsHandler = { [store] query, collection, _ in
        guard gate.claim() else { return }; store.stop(query)
        var values: [Date: Double] = [:]
        collection?.enumerateStatistics(from: start, to: end) { statistic, _ in
          if let value = (cumulative ? statistic.sumQuantity() : statistic.averageQuantity())?.doubleValue(for: unit), value.isFinite, value >= 0 {
            values[statistic.startDate] = value
          }
        }
        continuation.resume(returning: values)
      }
      store.execute(query)
      DispatchQueue.global().asyncAfter(deadline: .now() + 5) { [store] in
        guard gate.claim() else { return }; store.stop(query); continuation.resume(returning: [:])
      }
    }
  }
}
