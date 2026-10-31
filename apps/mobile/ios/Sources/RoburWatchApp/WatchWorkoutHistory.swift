import Foundation
import Combine
import HealthKit

@MainActor
final class WatchWorkoutHistory: ObservableObject {
  @Published private(set) var workouts: [WorkoutRecord] = []
  @Published private(set) var loading = false
  @Published private(set) var error: String?
  private let store = HKHealthStore()

  func refresh() async {
    guard !loading, HKHealthStore.isHealthDataAvailable() else { return }
    loading = true
    defer { loading = false }
    do {
      let samples: [HKWorkout] = try await withCheckedThrowingContinuation { continuation in
        let start = Calendar.current.date(byAdding: .day, value: -7, to: Date()) ?? Date()
        let query = HKSampleQuery(sampleType: .workoutType(),
          predicate: HKQuery.predicateForSamples(withStart: start, end: Date(), options: .strictStartDate),
          limit: HKObjectQueryNoLimit, sortDescriptors: [NSSortDescriptor(key: HKSampleSortIdentifierStartDate, ascending: false)]) { _, samples, error in
          if let error { continuation.resume(throwing: error) }
          else { continuation.resume(returning: samples as? [HKWorkout] ?? []) }
        }
        store.execute(query)
      }
      workouts = samples.map { workout in
        let type: WorkoutActivity
        switch workout.workoutActivityType {
        case .running: type = .running
        case .cycling: type = .cycling
        case .tennis: type = .tennis
        case .traditionalStrengthTraining: type = .traditionalStrength
        case .functionalStrengthTraining: type = .functionalStrength
        case .walking: type = .walking
        case .swimming: type = .swimming
        case .hiking: type = .hiking
        case .rowing: type = .rowing
        case .highIntensityIntervalTraining: type = .hiit
        case .yoga, .pilates, .flexibility: type = .mobility
        default: type = .other
        }
        return WorkoutRecord(id: workout.uuid.uuidString, start: workout.startDate, end: workout.endDate,
          title: type.title, symbol: type.symbol, minutes: workout.duration / 60,
          distanceKm: workout.totalDistance?.doubleValue(for: .meterUnit(with: .kilo)),
          energyKcal: workout.statistics(for: .quantityType(forIdentifier: .activeEnergyBurned)!)?.sumQuantity()?.doubleValue(for: .kilocalorie()),
          averageHeartRate: nil, source: workout.sourceRevision.source.name, activityType: type)
      }
      error = nil
    } catch {
      self.error = "Could not read workouts: \(error.localizedDescription)"
    }
  }
}
