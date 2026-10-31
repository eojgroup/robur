import Foundation

/// Foreground confirmation prompts only: motion never creates a Health workout.
struct WorkoutSuggestionGate {
  private(set) var candidate: WorkoutActivity?
  private var observedSince: Date?
  private var lastSuggestedAt: Date?
  var minimumDuration: TimeInterval = 60
  var cooldown: TimeInterval = 30 * 60

  mutating func observe(_ activity: WorkoutActivity?, at now: Date) {
    guard activity == .running || activity == .cycling else {
      candidate = nil; observedSince = nil; return
    }
    if candidate != activity { candidate = activity; observedSince = now }
  }

  mutating func suggestion(at now: Date) -> WorkoutActivity? {
    guard let candidate, let since = observedSince, now.timeIntervalSince(since) >= minimumDuration,
          lastSuggestedAt.map({ now.timeIntervalSince($0) >= cooldown }) ?? true else { return nil }
    lastSuggestedAt = now
    return candidate
  }

  mutating func resetObservation() { candidate = nil; observedSince = nil }
}

struct WorkoutReviewPolicy {
  static func pending(workouts: [WorkoutRecord], annotations: [String: WorkoutAnnotation],
                      reviewedIDs: Set<String>, now: Date = Date()) -> [WorkoutRecord] {
    let cutoff = now.addingTimeInterval(-7 * 24 * 60 * 60)
    return workouts.filter { workout in
      guard workout.end <= now, workout.end >= cutoff, !reviewedIDs.contains(workout.id) else { return false }
      let annotation = annotations[workout.id]
      return annotation?.muscles.isEmpty != false && (annotation?.notes.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true)
    }.sorted { $0.end > $1.end }
  }
}
