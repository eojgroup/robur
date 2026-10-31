import SwiftUI

/// The same optional, activity-specific review on iPhone and Apple Watch.
struct WorkoutReviewFields: View {
  let workout: WorkoutRecord
  @Binding var muscles: Set<MuscleGroup>
  @Binding var quick: WorkoutQuickReview

  private var columns: [GridItem] {
    #if os(watchOS)
    [GridItem(.flexible()), GridItem(.flexible())]
    #else
    [GridItem(.adaptive(minimum: 110))]
    #endif
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 16) {
      switch workout.activityType.category {
      case .strength:
        Text("What did you train?").font(.headline)
        LazyVGrid(columns: columns, spacing: 8) {
          ForEach(MuscleGroup.allCases) { group in
            chip(group.rawValue, selected: muscles.contains(group)) {
              if muscles.contains(group) { muscles.remove(group) } else { muscles.insert(group) }
            }
          }
        }
      case .endurance:
        if let average = recordedAverage {
          VStack(alignment: .leading, spacing: 4) {
            Text("Recorded average").font(.caption).foregroundStyle(.secondary)
            Text("\(average.speed) km/h · \(average.pace) /km").font(.subheadline.bold())
          }
        }
        Text("How was the pace?").font(.headline)
        LazyVGrid(columns: columns, spacing: 8) {
          ForEach(ReviewPace.allCases) { pace in
            chip(pace.title, selected: quick.pace == pace) { quick.pace = quick.pace == pace ? nil : pace }
          }
        }
      case .sport:
        Text("What was your focus?").font(.headline)
        LazyVGrid(columns: columns, spacing: 8) {
          ForEach(SportReviewFocus.allCases) { focus in
            chip(focus.title, selected: quick.sportFocus.contains(focus)) {
              if quick.sportFocus.contains(focus) { quick.sportFocus.remove(focus) } else { quick.sportFocus.insert(focus) }
            }
          }
        }
        Picker("Execution", selection: $quick.execution) {
          Text("Not set").tag(ReviewExecution?.none)
          ForEach(ReviewExecution.allCases) { value in Text(value.title).tag(Optional(value)) }
        }.workoutReviewPickerStyle()
      case .mobility:
        Text("How does your body feel?").font(.headline)
        LazyVGrid(columns: columns, spacing: 8) {
          ForEach(ReviewBodyFeeling.allCases) { feeling in
            chip(feeling.title, selected: quick.bodyFeeling == feeling) {
              quick.bodyFeeling = quick.bodyFeeling == feeling ? nil : feeling
            }
          }
        }
      case .other:
        Text("How did the session feel?").font(.headline)
      }
      if workout.activityType.category != .mobility {
        VStack(alignment: .leading, spacing: 5) {
          Picker("How hard did it feel?", selection: $quick.feltEffort) {
            Text("Not set").tag(Int?.none)
            ForEach(1...10, id: \.self) { score in
              Text(score == 1 ? "1 · Easy" : score == 10 ? "10 · Max" : "\(score) / 10").tag(Optional(score))
            }
          }.workoutReviewPickerStyle()
          Text("Effort from 1 (easy) to 10 (max). Separate from your Apple Fitness rating.")
            .font(.caption).foregroundStyle(.secondary)
        }
      }
      Text("Everything here is optional.").font(.caption).foregroundStyle(.secondary)
    }
  }

  private func chip(_ title: String, selected: Bool, action: @escaping () -> Void) -> some View {
    Button(action: action) {
      HStack(spacing: 5) {
        if selected { Image(systemName: "checkmark").imageScale(.small) }
        Text(title).font(.subheadline)
      }.frame(maxWidth: .infinity, minHeight: 30).padding(8)
        .background(selected ? Color.accentColor.opacity(0.18) : Color.secondary.opacity(0.1),
          in: RoundedRectangle(cornerRadius: 12))
    }.buttonStyle(.plain).accessibilityAddTraits(selected ? .isSelected : [])
  }

  private var recordedAverage: (speed: String, pace: String)? {
    guard let distance = workout.distanceKm, distance.isFinite, distance > 0,
          workout.minutes.isFinite, workout.minutes > 0 else { return nil }
    let speed = distance / workout.minutes * 60
    let seconds = (workout.minutes / distance * 60).rounded()
    guard speed.isFinite, speed > 0, seconds.isFinite, seconds >= 0 else { return nil }
    // Only the seconds remainder becomes an Int, so unusually large valid values cannot overflow.
    let paceMinutes = floor(seconds / 60).formatted(.number.precision(.fractionLength(0)).grouping(.never))
    let paceSeconds = Int(seconds.truncatingRemainder(dividingBy: 60))
    return (speed.formatted(.number.precision(.fractionLength(1))), "\(paceMinutes):\(String(format: "%02d", paceSeconds))")
  }

  static func caption(for activity: WorkoutActivity) -> String {
    switch activity.category {
    case .strength: return "Muscles & feeling"
    case .endurance: return "Pace & feeling"
    case .sport: return "Focus & execution"
    case .mobility: return "Body feeling"
    case .other: return "Session feeling"
    }
  }
}

private extension View {
  @ViewBuilder func workoutReviewPickerStyle() -> some View {
    #if os(watchOS)
    pickerStyle(.navigationLink)
    #else
    pickerStyle(.menu)
    #endif
  }
}
