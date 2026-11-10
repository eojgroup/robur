import Foundation

indirect enum HealthSyncValue: Codable, Equatable {
  case object([String: HealthSyncValue]), array([HealthSyncValue]), string(String), number(Double), bool(Bool), null

  init(from decoder: Decoder) throws {
    let container = try decoder.singleValueContainer()
    if container.decodeNil() { self = .null }
    else if let value = try? container.decode(Bool.self) { self = .bool(value) }
    else if let value = try? container.decode(Double.self) { self = .number(value) }
    else if let value = try? container.decode(String.self) { self = .string(value) }
    else if let value = try? container.decode([String: HealthSyncValue].self) { self = .object(value) }
    else { self = .array(try container.decode([HealthSyncValue].self)) }
  }

  func encode(to encoder: Encoder) throws {
    var container = encoder.singleValueContainer()
    switch self {
    case .object(let value): try container.encode(value)
    case .array(let value): try container.encode(value)
    case .string(let value): try container.encode(value)
    case .number(let value): try container.encode(value)
    case .bool(let value): try container.encode(value)
    case .null: try container.encodeNil()
    }
  }
}

struct HealthSyncRecord: Codable, Equatable {
  let kind: String
  let id: String
  let observedAt: Date
  let data: [String: HealthSyncValue]
}

struct HealthSyncBatch: Codable {
  let schemaVersion = 1
  let sourceDeviceId: String
  let capturedAt: Date
  let records: [HealthSyncRecord]

  static func encoder() -> JSONEncoder {
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .iso8601
    encoder.outputFormatting = [.sortedKeys]
    return encoder
  }

  static func split(_ records: [HealthSyncRecord], sourceDeviceId: String, now: Date = Date(),
                    maxBytes: Int = 3 * 1_024 * 1_024) throws -> [HealthSyncBatch] {
    let encoder = encoder()
    var result: [HealthSyncBatch] = [], pending: [HealthSyncRecord] = []
    var bytes = 4_096 // Reserve room for JSON framing and connection identifiers.
    for record in records {
      let size = try encoder.encode(record).count + 1
      guard size + 4_096 <= maxBytes else { throw HealthSyncModelError.recordTooLarge }
      if !pending.isEmpty && (pending.count >= 500 || bytes + size > maxBytes) {
        result.append(HealthSyncBatch(sourceDeviceId: sourceDeviceId, capturedAt: now, records: pending))
        pending = []; bytes = 4_096
      }
      pending.append(record); bytes += size
    }
    if !pending.isEmpty { result.append(HealthSyncBatch(sourceDeviceId: sourceDeviceId, capturedAt: now, records: pending)) }
    return result
  }
}

enum HealthSyncModelError: LocalizedError {
  case recordTooLarge
  var errorDescription: String? { "A Health record exceeds the upload limit. Leave detailed observations off and retry." }
}

enum HealthSyncExport {
  static func make(days: [DailyHealthMetrics], workouts: [WorkoutRecord], readings: [FitnessReading],
                   annotations: [String: WorkoutAnnotation], analysis: RecoveryAnalysis,
                   includeReviews: Bool, includeDetails: Bool, now: Date = Date(), calendar: Calendar = .current) throws -> [HealthSyncRecord] {
    let formatter = DateFormatter()
    formatter.calendar = calendar; formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.timeZone = calendar.timeZone; formatter.dateFormat = "yyyy-MM-dd"
    func dateKey(_ date: Date) -> String { formatter.string(from: date) }
    func values(_ pairs: [(String, Double?)]) -> [String: HealthSyncValue] {
      Dictionary(uniqueKeysWithValues: pairs.compactMap { key, value in
        guard let value, value.isFinite else { return nil }
        return (key, .number(value))
      })
    }
    func encoded<T: Encodable>(_ value: T) throws -> HealthSyncValue {
      try JSONDecoder().decode(HealthSyncValue.self, from: HealthSyncBatch.encoder().encode(value))
    }
    var result: [HealthSyncRecord] = []
    for day in days where day.date <= now {
      var data = values([
        ("sleepMinutes", day.sleepMinutes), ("steps", day.steps), ("exerciseMinutes", day.exerciseMinutes),
        ("standMinutes", day.standMinutes), ("activeEnergyKcal", day.activeEnergyKcal), ("restingHR", day.restingHR),
        ("hrv", day.hrv), ("vo2Max", day.vo2Max), ("weightKg", day.weightKg),
        ("respiratoryRate", day.respiratoryRate), ("oxygenSaturation", day.oxygenSaturation),
        ("bodyFatPercent", day.bodyFatPercent), ("bmi", day.bmi), ("heightCm", day.heightCm)
      ])
      data["date"] = .string(dateKey(day.date)); data["timeZone"] = .string(calendar.timeZone.identifier)
      data["aggregation"] = .string("HealthKit consolidated daily values; missing readings omitted")
      result.append(.init(kind: "daily", id: dateKey(day.date), observedAt: day.date, data: data))
    }
    for workout in workouts where workout.end <= now && workout.minutes.isFinite && workout.minutes > 0 {
      var data = values([("minutes", workout.minutes), ("distanceKm", workout.distanceKm),
        ("energyKcal", workout.energyKcal), ("averageHeartRate", workout.averageHeartRate),
        ("appleEffort", workout.appleEffort), ("cadence", workout.cadence)])
      data["title"] = .string(workout.title); data["activityType"] = .string(workout.activityType.rawValue)
      data["start"] = try encoded(workout.start); data["end"] = try encoded(workout.end)
      data["source"] = .string(workout.source); data["date"] = .string(dateKey(workout.start))
      if let effortSource = workout.effortSource { data["effortSource"] = .string(effortSource.rawValue) }
      if includeReviews, let annotation = annotations[workout.id] {
        data["review"] = try encoded(annotation)
      }
      result.append(.init(kind: "workout", id: workout.id, observedAt: workout.start, data: data))
      if includeDetails {
        // Observations associated with this workout, not a complete raw Health
        // archive. Stable IDs make repeated uploads idempotent.
        for sample in workout.heartRateSamples where sample.bpm.isFinite && sample.bpm > 0 && sample.date <= now {
          let sampleData: [String: HealthSyncValue] = ["metric": .string("Workout heart rate"),
            "value": .number(sample.bpm), "unit": .string("bpm"), "workoutId": .string(workout.id)]
          result.append(.init(kind: "quantity", id: "\(workout.id)-hr-\(sample.date.timeIntervalSince1970)-\(sample.bpm)",
            observedAt: sample.date, data: sampleData))
        }
      }
    }
    for reading in readings where reading.date <= now && reading.value.isFinite && reading.value >= 0 {
      result.append(.init(kind: "fitness", id: reading.id, observedAt: reading.date,
        data: ["metric": .string(reading.metric.rawValue), "value": .number(reading.value),
          "unit": .string(reading.metric.unit), "aggregation": .string("Daily HealthKit statistic")]))
    }
    for point in analysis.history {
      var data = values([("recovery", point.recovery.map(Double.init)), ("fitness", point.fitness.map(Double.init)),
        ("coverage", point.coverage), ("load", point.load), ("acuteLoad", point.acuteLoad), ("chronicLoad", point.chronicLoad)])
      data["date"] = .string(dateKey(point.date)); data["methodologyVersion"] = .string(analysis.methodologyVersion)
      data["components"] = try encoded(point.recoveryComponents)
      data["fitnessComponents"] = try encoded(point.fitnessComponents)
      result.append(.init(kind: "score", id: "\(analysis.methodologyVersion)-\(dateKey(point.date))", observedAt: point.date, data: data))
    }
    return result
  }
}
