import Combine
import Foundation
import Security

private struct HealthSyncConnection: Codable {
  let origin: URL
  let deviceToken: String
  let sourceDeviceId: String
  let userId: String
}

private enum HealthSyncKeychain {
  private static let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
    kSecAttrService as String: "com.eojgroup.robur.health-sync", kSecAttrAccount as String: "connection"]

  static func read() throws -> Data? {
    var request = query
    request[kSecReturnData as String] = true
    request[kSecMatchLimit as String] = kSecMatchLimitOne
    var result: CFTypeRef?
    let status = SecItemCopyMatching(request as CFDictionary, &result)
    if status == errSecItemNotFound { return nil }
    guard status == errSecSuccess else { throw CloudHealthSyncError.keychain }
    return result as? Data
  }

  static func save(_ data: Data) throws {
    let attributes: [String: Any] = [kSecValueData as String: data,
      kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly]
    var status = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
    if status == errSecItemNotFound {
      status = SecItemAdd(query.merging(attributes) { _, value in value } as CFDictionary, nil)
    }
    guard status == errSecSuccess else { throw CloudHealthSyncError.keychain }
  }

  static func remove() throws {
    let status = SecItemDelete(query as CFDictionary)
    guard status == errSecSuccess || status == errSecItemNotFound else { throw CloudHealthSyncError.keychain }
  }
}

/// Avoid redirecting a request containing Health data or an account token.
private final class HealthSyncRedirectPolicy: NSObject, URLSessionTaskDelegate {
  func urlSession(_ session: URLSession, task: URLSessionTask,
                  willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest,
                  completionHandler: @escaping (URLRequest?) -> Void) { completionHandler(nil) }
}

enum CloudHealthSyncError: LocalizedError {
  case endpoint, connection, consent, unavailable(Int), keychain, history, deploymentPaused
  var errorDescription: String? {
    switch self {
    case .endpoint: return "Enter the HTTPS origin of your Robur dashboard, without a path, password or query."
    case .connection: return "Connect this device with a new code from your web dashboard."
    case .consent: return "Cloud consent is paused or changed. Review the upload choices before resuming."
    case .unavailable(let status):
      if status == 401 { return "The device connection expired or was revoked. Connect with a new code." }
      if status == 403 { return "The server declined this upload. Review consent in the web dashboard." }
      if status == 429 { return "The server is busy. Wait a moment before retrying." }
      return "The server could not complete the request (HTTP \(status)). No retry will start automatically."
    case .keychain: return "The device could not securely read or save the connection. Unlock it and retry."
    case .history: return "Health history did not finish loading. Refresh Health access and retry."
    case .deploymentPaused: return "Web sync is paused while the cloud service is undeployed. Health data remains on this device."
    }
  }
}

@MainActor
final class CloudHealthSync: ObservableObject {
  static let shared = CloudHealthSync()
  static var deploymentEnabled: Bool { Bundle.main.object(forInfoDictionaryKey: "RoburCloudSyncEnabled") as? Bool == true }
  @Published var serverOrigin = Bundle.main.object(forInfoDictionaryKey: "RoburCloudSyncOrigin") as? String ?? ""
  @Published private(set) var connected = false
  @Published private(set) var uploading = false
  @Published private(set) var working = false
  @Published private(set) var status = "Cloud sync is off. Health data remains on this device."
  @Published private(set) var error: String?
  @Published private(set) var uploadedRecords = 0
  @Published private(set) var lastUpload: Date?
  @Published private(set) var enabled = false
  @Published private(set) var detailedSamples = false
  @Published private(set) var workoutReviews = false
  private var connection: HealthSyncConnection?
  private var uploadTask: Task<Void, Never>?
  private let session: URLSession

  init() {
    let configuration = URLSessionConfiguration.ephemeral
    configuration.urlCache = nil; configuration.httpCookieStorage = nil
    configuration.timeoutIntervalForRequest = 45
    configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
    session = URLSession(configuration: configuration, delegate: HealthSyncRedirectPolicy(), delegateQueue: nil)
    guard Self.deploymentEnabled else {
      status = CloudHealthSyncError.deploymentPaused.localizedDescription
      return
    }
    do {
      if let data = try HealthSyncKeychain.read() {
        let saved = try JSONDecoder().decode(HealthSyncConnection.self, from: data)
        connection = saved; serverOrigin = saved.origin.absoluteString; connected = true
        // Reopening the app never silently resumes an upload.
        status = "Connected. Review consent and upload manually when ready."
      }
    } catch { self.error = error.localizedDescription }
  }

  static func origin(_ text: String) throws -> URL {
    guard let parts = URLComponents(string: text.trimmingCharacters(in: .whitespacesAndNewlines)),
      parts.scheme?.lowercased() == "https", let host = parts.host, !host.isEmpty, parts.user == nil, parts.password == nil,
      parts.query == nil, parts.fragment == nil, parts.path.isEmpty || parts.path == "/",
      let url = parts.url else { throw CloudHealthSyncError.endpoint }
    return url
  }

  func connect(code: String, detailed: Bool, reviews: Bool) async {
    guard !working else { return }
    working = true; error = nil
    defer { working = false }
    do {
      let origin = try Self.origin(serverOrigin)
      let sourceId = UUID().uuidString
      let body: [String: HealthSyncValue] = ["code": .string(code.trimmingCharacters(in: .whitespacesAndNewlines)),
        "sourceDeviceId": .string(sourceId), "deviceName": .string("Robur Apple device")]
      let response = try await request(origin: origin, path: "/api/pairings/redeem", method: "POST", body: body)
      struct Pairing: Decodable { let deviceToken: String; let userId: String }
      let pairing = try JSONDecoder().decode(Pairing.self, from: response)
      let saved = HealthSyncConnection(origin: origin, deviceToken: pairing.deviceToken, sourceDeviceId: sourceId, userId: pairing.userId)
      try HealthSyncKeychain.save(JSONEncoder().encode(saved))
      connection = saved; connected = true
      try await consent(detailed: detailed, reviews: reviews)
      status = "Connected and consent saved. Choose Upload to share approved history."
    } catch { self.error = error.localizedDescription }
  }

  func resume(detailed: Bool, reviews: Bool) async {
    guard !working else { return }
    working = true; error = nil
    defer { working = false }
    do {
      try await consent(detailed: detailed, reviews: reviews)
      status = "Consent saved. Uploads start only when you choose Upload."
    } catch { self.error = error.localizedDescription }
  }

  private func consent(detailed: Bool, reviews: Bool) async throws {
    guard let connection else { throw CloudHealthSyncError.connection }
    _ = try await request(origin: connection.origin, path: "/api/health/consent", method: "POST", token: connection.deviceToken,
      body: ["version": .string("health-sync-v1"), "detailedSamples": .bool(detailed), "workoutReviews": .bool(reviews)])
    enabled = true; detailedSamples = detailed; workoutReviews = reviews
  }

  func pause() async {
    let stopping = uploadTask
    stopping?.cancel(); enabled = false; error = nil
    await stopping?.value
    working = true
    defer { working = false }
    status = "Uploads paused on this device."
    guard let connection else { return }
    do {
      _ = try await request(origin: connection.origin, path: "/api/health/consent", method: "DELETE", token: connection.deviceToken)
      status = "Cloud consent paused. Existing cloud records are retained until you delete them."
    } catch { self.error = "This device is paused; server pause could not be confirmed. \(error.localizedDescription)" }
  }

  func disconnect() {
    uploadTask?.cancel(); enabled = false
    do {
      try HealthSyncKeychain.remove()
      connection = nil; connected = false; lastUpload = nil
      status = "Disconnected on this device. Cloud records remain until you delete them in the web dashboard."
      error = nil
    } catch { self.error = error.localizedDescription }
  }

  func disconnectDevice() async {
    guard !working else { return }
    working = true
    defer { working = false }
    if let connection {
      do {
        _ = try await request(origin: connection.origin, path: "/api/health/device", method: "DELETE", token: connection.deviceToken)
      } catch {
        disconnect()
        self.error = "Disconnected locally; server revocation could not be confirmed. \(error.localizedDescription)"
        return
      }
    }
    disconnect()
  }

  func deleteCloudData() async {
    guard let connection, !working else { return }
    working = true; error = nil
    defer { working = false }
    do {
      _ = try await request(origin: connection.origin, path: "/api/health/data", method: "DELETE", token: connection.deviceToken)
      disconnect()
      status = "Cloud health records deleted and device access revoked. Local Apple Health records are unchanged."
    } catch { self.error = error.localizedDescription }
  }

  func startUpload(health: HealthKitClient, journal: WorkoutJournal) {
    guard !working, enabled else { return }
    uploadTask = Task { await upload(health: health, journal: journal) }
  }

  func cancelUpload() { uploadTask?.cancel() }

  private func upload(health: HealthKitClient, journal: WorkoutJournal) async {
    guard let connection, enabled else { error = CloudHealthSyncError.connection.localizedDescription; return }
    working = true; uploading = true; error = nil; uploadedRecords = 0
    defer { working = false; uploading = false; uploadTask = nil }
    do {
      struct Status: Decodable {
        struct Consent: Decodable { let detailedSamples: Bool; let workoutReviews: Bool?; let enabled: Bool? }
        let consent: Consent?
      }
      let data = try await request(origin: connection.origin, path: "/api/health/status", token: connection.deviceToken)
      let server = try JSONDecoder().decode(Status.self, from: data)
      guard let consent = server.consent, consent.enabled != false, consent.detailedSamples == detailedSamples,
        (consent.workoutReviews ?? false) == workoutReviews else { enabled = false; throw CloudHealthSyncError.consent }
      status = "Reading all available approved Health history…"
      guard health.authorizationRequested else { throw CloudHealthSyncError.history }
      await health.loadHistory(range: .all)
      try Task.checkCancellation()
      guard health.historyError == nil, !health.isLoadingHistory else { throw CloudHealthSyncError.history }
      if detailedSamples {
        let ids = health.workouts.map(\.id)
        for (index, id) in ids.enumerated() {
          try Task.checkCancellation()
          status = "Reading workout observations \(index + 1) / \(ids.count)…"
          await health.loadWorkoutDetails(id: id)
        }
      }
      let defaults = UserDefaults.standard
      let request = TrainingAnalysisRequest(days: health.dailyMetrics, workouts: health.analyticsWorkouts,
        annotations: journal.annotations, maxHR: defaults.object(forKey: "RoburMaxHeartRate") as? Double ?? 190,
        stepsGoal: defaults.object(forKey: "RoburStepsGoal") as? Double ?? 8000,
        exerciseGoal: defaults.object(forKey: "RoburExerciseGoal") as? Double ?? 30,
        historyStart: health.analyticsHistoryStart,
        fitnessReference: health.fitnessReference)
      let workouts = health.workouts, readings = health.fitnessReadings
      let analysis = try await TrainingAnalysisWorker.shared.make(request).recoveryAnalysis
      let records = try HealthSyncExport.make(days: request.days, workouts: workouts,
        readings: readings, annotations: request.annotations, analysis: analysis,
        includeReviews: workoutReviews, includeDetails: detailedSamples)
      let batches = try HealthSyncBatch.split(records, sourceDeviceId: connection.sourceDeviceId)
      for (index, batch) in batches.enumerated() {
        try Task.checkCancellation()
        guard enabled else { throw CloudHealthSyncError.consent }
        status = "Uploading batch \(index + 1) / \(batches.count)…"
        _ = try await request(origin: connection.origin, path: "/api/health/sync", method: "POST", token: connection.deviceToken,
          encodedBody: HealthSyncBatch.encoder().encode(batch))
        uploadedRecords += batch.records.count
      }
      lastUpload = Date()
      status = "Uploaded \(uploadedRecords) records. Repeated uploads update existing records."
    } catch is CancellationError { status = "Upload cancelled. Completed batches remain saved; retrying will update them." }
    catch { self.error = error.localizedDescription }
  }

  private func request(origin: URL, path: String, method: String = "GET", token: String? = nil,
                       body: [String: HealthSyncValue]? = nil, encodedBody: Data? = nil) async throws -> Data {
    guard Self.deploymentEnabled else { throw CloudHealthSyncError.deploymentPaused }
    guard let url = URL(string: path, relativeTo: origin)?.absoluteURL else { throw CloudHealthSyncError.endpoint }
    var request = URLRequest(url: url)
    request.httpMethod = method
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    request.setValue("no-store", forHTTPHeaderField: "Cache-Control")
    if let token { request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
    request.httpBody = try encodedBody ?? body.map { try JSONEncoder().encode($0) }
    let (data, response) = try await session.data(for: request)
    guard let response = response as? HTTPURLResponse, (200..<300).contains(response.statusCode) else {
      throw CloudHealthSyncError.unavailable((response as? HTTPURLResponse)?.statusCode ?? 0)
    }
    return data
  }
}
