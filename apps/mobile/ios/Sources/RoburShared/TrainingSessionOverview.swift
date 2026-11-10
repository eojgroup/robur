import Foundation

/// A display-only comparison. A nearby Health workout never changes plan state,
/// Calendar or Reminders, and an unmatched workout is not proof it was unplanned.
struct TrainingSessionComparison: Identifiable {
  let plan: PlanEntry?
  let workout: WorkoutRecord?
  var id: String { plan.map { "plan-\($0.id.uuidString)" } ?? "workout-\(workout!.id)" }
  var date: Date { workout?.start ?? plan!.startDate }
}

enum TrainingSessionOverview {
  /// Match exact known activities on the same local day, within three hours and
  /// with reasonably similar durations. Closest candidates win deterministically;
  /// each plan and workout appears once. These are suggestions, not persisted links.
  static func compare(plans: [PlanEntry], workouts: [WorkoutRecord], calendar: Calendar = .current) -> [TrainingSessionComparison] {
    struct Candidate {
      let plan: PlanEntry
      let workout: WorkoutRecord
      let difference: TimeInterval
      let durationDifference: Double
    }
    var seen: Set<String> = []
    let validWorkouts = workouts.filter { $0.minutes.isFinite && $0.minutes > 0 &&
      $0.start.timeIntervalSince1970.isFinite && seen.insert($0.id).inserted }
    let candidates = plans.filter(\.isValid).flatMap { plan in
      validWorkouts.compactMap { workout -> Candidate? in
        guard plan.activity != .other, plan.activity == workout.activityType,
          calendar.isDate(plan.startDate, inSameDayAs: workout.start) else { return nil }
        let difference = abs(plan.startDate.timeIntervalSince(workout.start))
        let ratio = workout.minutes / Double(plan.durationMinutes)
        guard difference <= 3 * 3_600, ratio >= 0.5, ratio <= 2 else { return nil }
        return Candidate(plan: plan, workout: workout, difference: difference,
          durationDifference: abs(workout.minutes - Double(plan.durationMinutes)))
      }
    }.sorted {
      if $0.difference != $1.difference { return $0.difference < $1.difference }
      if $0.durationDifference != $1.durationDifference { return $0.durationDifference < $1.durationDifference }
      if $0.plan.id != $1.plan.id { return $0.plan.id.uuidString < $1.plan.id.uuidString }
      return $0.workout.id < $1.workout.id
    }
    var usedPlans: Set<UUID> = [], usedWorkouts: Set<String> = []
    var result: [TrainingSessionComparison] = []
    for candidate in candidates where !usedPlans.contains(candidate.plan.id) && !usedWorkouts.contains(candidate.workout.id) {
      usedPlans.insert(candidate.plan.id); usedWorkouts.insert(candidate.workout.id)
      result.append(TrainingSessionComparison(plan: candidate.plan, workout: candidate.workout))
    }
    result += plans.filter { !usedPlans.contains($0.id) }.map { TrainingSessionComparison(plan: $0, workout: nil) }
    result += validWorkouts.filter { !usedWorkouts.contains($0.id) }.map { TrainingSessionComparison(plan: nil, workout: $0) }
    return result.sorted { $0.date == $1.date ? $0.id < $1.id : $0.date < $1.date }
  }
}
