import Foundation

protocol ReviewChoice: RawRepresentable, CaseIterable, Identifiable, Codable, Hashable where RawValue == String {
  var title: String { get }
}
extension ReviewChoice { var id: String { rawValue } }

enum ReviewPace: String, ReviewChoice {
  case easy, steady, fast, intervals
  var title: String {
    switch self { case .easy: return "Easy"; case .steady: return "Steady"; case .fast: return "Fast"; case .intervals: return "Intervals" }
  }
}
enum SportReviewFocus: String, ReviewChoice {
  case technique, footwork, tactics, skills, matchPlay
  var title: String {
    switch self { case .technique: return "Technique"; case .footwork: return "Footwork"; case .tactics: return "Tactics"; case .skills: return "Specific skills"; case .matchPlay: return "Match play" }
  }
}
enum ReviewExecution: String, ReviewChoice {
  case learning, consistent, sharp
  var title: String {
    switch self { case .learning: return "Learning"; case .consistent: return "Consistent"; case .sharp: return "Sharp" }
  }
}
enum ReviewBodyFeeling: String, ReviewChoice {
  case tight, comfortable, loose
  var title: String {
    switch self { case .tight: return "Tight"; case .comfortable: return "Comfortable"; case .loose: return "Loose" }
  }
}

/// Personal observations in Robur; never replaces an imported Fitness effort rating.
struct WorkoutQuickReview: Codable, Equatable {
  var pace: ReviewPace? = nil
  var feltEffort: Int? = nil
  var sportFocus: Set<SportReviewFocus> = []
  var execution: ReviewExecution? = nil
  var bodyFeeling: ReviewBodyFeeling? = nil
  var isEmpty: Bool { pace == nil && feltEffort == nil && sportFocus.isEmpty && execution == nil && bodyFeeling == nil }
  var isValid: Bool { feltEffort.map { (1...10).contains($0) } ?? true }
  var conflictKey: String {
    [pace?.rawValue ?? "", feltEffort.map(String.init) ?? "", sportFocus.map(\.rawValue).sorted().joined(separator: ","),
     execution?.rawValue ?? "", bodyFeeling?.rawValue ?? ""].joined(separator: "|")
  }
}
