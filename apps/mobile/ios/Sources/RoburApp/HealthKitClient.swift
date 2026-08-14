import Foundation
import Combine
import HealthKit

@MainActor
final class HealthKitClient: ObservableObject {
  @Published private(set) var snapshot: FitnessSnapshot?
  @Published private(set) var authorizationRequested = false
  @Published private(set) var lastError: String?

  private let store = HKHealthStore()

  var statusText: String {
    if let lastError {
      return lastError
    }

    return authorizationRequested ? "Apple Health connected" : "Apple Health ready"
  }

  var promptTitle: String {
    authorizationRequested ? "Apple Health connected" : "Connect Apple Health"
  }

  var promptMessage: String {
    if authorizationRequested {
      return "Robur can use your approved Health data to keep recovery, sleep, HRV, and training load current."
    }

    return "Robur reads workouts, sleep, resting heart rate, HRV, running distance, and cycling distance to calculate today's recommendation."
  }

  func requestAuthorization() {
    guard HKHealthStore.isHealthDataAvailable() else {
      lastError = "Apple Health is unavailable on this device."
      return
    }

    let readTypes = Set<HKObjectType>([
      HKObjectType.workoutType(),
      HKObjectType.quantityType(forIdentifier: .restingHeartRate)!,
      HKObjectType.quantityType(forIdentifier: .heartRateVariabilitySDNN)!,
      HKObjectType.quantityType(forIdentifier: .distanceWalkingRunning)!,
      HKObjectType.quantityType(forIdentifier: .distanceCycling)!,
      HKObjectType.categoryType(forIdentifier: .sleepAnalysis)!
    ])

    store.requestAuthorization(toShare: Set<HKSampleType>(), read: readTypes) { [weak self] success, error in
      Task { @MainActor in
        self?.authorizationRequested = success
        self?.lastError = error?.localizedDescription
        Task {
          await self?.refreshTodaySnapshot()
        }
      }
    }
  }

  func refreshTodaySnapshot() async {
    guard HKHealthStore.isHealthDataAvailable() else {
      snapshot = RoburData.today
      return
    }

    // Shell for real HealthKit aggregation. The mock keeps first-run UI stable
    // until the app wires score formulas, background delivery, and API sync.
    snapshot = RoburData.today
  }
}
