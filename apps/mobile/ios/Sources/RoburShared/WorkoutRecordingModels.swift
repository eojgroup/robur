import Foundation
import HealthKit

enum WorkoutRecordingPhase: String, Equatable {
  case idle, preparing, running, paused, saving, finished
  var isActive: Bool { self == .preparing || self == .running || self == .paused || self == .saving }
  var title: String {
    switch self {
    case .idle: return "Ready"
    case .preparing: return "Preparing workout"
    case .running: return "Recording"
    case .paused: return "Paused"
    case .saving: return "Saving to Apple Health"
    case .finished: return "Saved to Apple Health"
    }
  }
}

struct WorkoutRecordingClock: Equatable, Codable {
  let startedAt: Date
  var pausedAt: Date? = nil
  var totalPausedSeconds: TimeInterval = 0
  mutating func pause(at date: Date = Date()) {
    guard pausedAt == nil else { return }
    pausedAt = max(date, startedAt)
  }
  mutating func resume(at date: Date = Date()) {
    guard let pausedAt else { return }
    totalPausedSeconds += max(0, date.timeIntervalSince(pausedAt))
    self.pausedAt = nil
  }
  func elapsed(asOf date: Date = Date()) -> TimeInterval {
    max(0, min(date, pausedAt ?? date).timeIntervalSince(startedAt) - totalPausedSeconds)
  }
}

extension WorkoutActivity {
  var healthKitActivityType: HKWorkoutActivityType {
    switch self {
    case .running: return .running
    case .cycling: return .cycling
    case .walking: return .walking
    case .swimming: return .swimming
    case .tennis: return .tennis
    // A generic racket-sports category does not identify a specific sport.
    case .racketSports: return .other
    case .traditionalStrength: return .traditionalStrengthTraining
    case .functionalStrength: return .functionalStrengthTraining
    case .hiit: return .highIntensityIntervalTraining
    case .mobility: return .flexibility
    case .hiking: return .hiking
    case .rowing: return .rowing
    case .other: return .other
    }
  }
  func workoutConfiguration(location: HKWorkoutSessionLocationType = .unknown) -> HKWorkoutConfiguration {
    let configuration = HKWorkoutConfiguration()
    configuration.activityType = healthKitActivityType
    configuration.locationType = location
    return configuration
  }
  static func fromHealthKit(_ type: HKWorkoutActivityType) -> WorkoutActivity {
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
    case .flexibility, .yoga, .pilates, .barre, .taiChi, .mindAndBody, .cooldown, .preparationAndRecovery: return .mobility
    case .hiking: return .hiking
    case .rowing: return .rowing
    default: return .other
    }
  }
}

enum WorkoutRecordingMetadata {
  static let musclesKey = "com.eojgroup.robur.muscleGroups"
  static let notesKey = "com.eojgroup.robur.notes"
  static let activityKey = "com.eojgroup.robur.activity"
  static func dictionary(muscles: Set<MuscleGroup>, notes: String) -> [String: Any] {
    [musclesKey: muscles.map(\.rawValue).sorted().joined(separator: ","),
     notesKey: String(notes.trimmingCharacters(in: .whitespacesAndNewlines).prefix(4_000))]
  }
  static func muscles(in metadata: [String: Any]?) -> Set<MuscleGroup> {
    let values = (metadata?[musclesKey] as? String)?.split(separator: ",").map(String.init)
      ?? (metadata?[musclesKey] as? [String] ?? [])
    return Set(values.compactMap(MuscleGroup.init(rawValue:)))
  }
  static func notes(in metadata: [String: Any]?) -> String { metadata?[notesKey] as? String ?? "" }
}
