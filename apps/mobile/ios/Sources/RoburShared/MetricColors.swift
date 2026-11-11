import SwiftUI

/// The same bundled palette supplies native and web metric colours. Labels and
/// point values remain visible; colour is never the only indication of a metric.
enum MetricColors {
  private struct Spec: Decodable, Sendable { let light: String; let dark: String; let aliases: [String] }
  private static func normalized(_ key: String) -> String { key.lowercased().filter { $0.isASCII && ($0.isLetter || $0.isNumber) } }
  private static let specs: [String: Spec] = {
    guard let url = Bundle.main.url(forResource: "metric-colors", withExtension: "json"),
      let data = try? Data(contentsOf: url), let source = try? JSONDecoder().decode([String: Spec].self, from: data) else { return [:] }
    var result: [String: Spec] = [:]
    for (key, spec) in source { for alias in [key] + spec.aliases { result[normalized(alias)] = spec } }
    return result
  }()
  private static func rgb(_ hex: String) -> (CGFloat, CGFloat, CGFloat) {
    let value = UInt32(hex.trimmingCharacters(in: CharacterSet(charactersIn: "#")), radix: 16) ?? 0xA94F16
    return (CGFloat((value >> 16) & 255) / 255, CGFloat((value >> 8) & 255) / 255, CGFloat(value & 255) / 255)
  }
  static func color(_ key: String, scheme: ColorScheme? = nil) -> Color {
    let spec = specs[normalized(key)] ?? Spec(light: "#A94F16", dark: "#FFA453", aliases: [])
    if let scheme {
      let (r, g, b) = rgb(scheme == .dark ? spec.dark : spec.light)
      return Color(red: Double(r), green: Double(g), blue: Double(b))
    }
    #if canImport(UIKit)
    return Color(uiColor: UIColor { traits in
      let (r, g, b) = rgb(traits.userInterfaceStyle == .dark ? spec.dark : spec.light)
      return UIColor(red: r, green: g, blue: b, alpha: 1)
    })
    #else
    let (r, g, b) = rgb(spec.dark)
    return Color(red: Double(r), green: Double(g), blue: Double(b))
    #endif
  }
  static func training(_ category: TrainingCategory) -> Color {
    switch category {
    case .strength: return color("strength")
    case .endurance: return color("cardio")
    case .mobility: return color("hrv")
    case .sport: return color("energy")
    case .other: return .gray
    }
  }
}
