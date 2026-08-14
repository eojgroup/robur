import Foundation

struct PushRegistrationPayload: Encodable {
  let installationId: String
  let platform: String
  let deviceToken: String
  let bundleId: String
  let environment: String
  let registeredAt: String
}

final class RoburAPIClient {
  static let shared = RoburAPIClient()

  private let session: URLSession
  private let defaults: UserDefaults

  init(session: URLSession = .shared, defaults: UserDefaults = .standard) {
    self.session = session
    self.defaults = defaults
  }

  func registerPushDevice(deviceToken: String) async throws {
    let payload = PushRegistrationPayload(
      installationId: installationId(),
      platform: "ios",
      deviceToken: deviceToken,
      bundleId: Bundle.main.bundleIdentifier ?? "com.eojgroup.robur",
      environment: apnsEnvironment(),
      registeredAt: ISO8601DateFormatter().string(from: Date())
    )

    var request = URLRequest(url: apiBaseURL().appending(path: "/api/push/register"))
    request.httpMethod = "POST"
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    request.httpBody = try JSONEncoder().encode(payload)

    let (_, response) = try await session.data(for: request)
    guard let httpResponse = response as? HTTPURLResponse,
          (200..<300).contains(httpResponse.statusCode) else {
      throw URLError(.badServerResponse)
    }
  }

  private func apiBaseURL() -> URL {
    if let rawValue = Bundle.main.object(forInfoDictionaryKey: "ROBUR_API_BASE_URL") as? String,
       let url = URL(string: rawValue) {
      return url
    }

    return URL(string: "https://app.robur.app")!
  }

  private func apnsEnvironment() -> String {
    let value = Bundle.main.object(forInfoDictionaryKey: "APNS_ENVIRONMENT") as? String
    return value == "production" ? "production" : "development"
  }

  private func installationId() -> String {
    let key = "RoburInstallationID"
    if let existing = defaults.string(forKey: key) {
      return existing
    }

    let created = UUID().uuidString
    defaults.set(created, forKey: key)
    return created
  }
}
