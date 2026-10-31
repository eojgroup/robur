#if os(iOS) || os(watchOS)
import Foundation
import Combine
import WatchConnectivity

@MainActor
final class WorkoutReviewSync: NSObject, ObservableObject, WCSessionDelegate {
  static let shared = WorkoutReviewSync()
  @Published private(set) var status = "Reviews are saved on this device."
  private let store: WorkoutReviewStore
  private let payloadKey = "roburWorkoutReview"
  private let receiptKey = "roburWorkoutReviewReceipt"
  private var activated = false
  private var retryTask: Task<Void, Never>?

  init(store: WorkoutReviewStore? = nil) {
    self.store = store ?? .shared
    super.init()
  }

  func activate() {
    guard WCSession.isSupported() else { status = "Reviews are saved on this device; Watch pairing is unavailable here."; return }
    if !activated {
      activated = true
      store.onLocalChange = { [weak self] _, _ in self?.flush() }
      WCSession.default.delegate = self
      WCSession.default.activate()
    }
    flush()
  }

  func flush() {
    guard WCSession.isSupported(), WCSession.default.activationState == .activated else { return }
    #if targetEnvironment(simulator)
    status = "Reviews saved locally. Sync is tested on paired devices."
    #else
    let session = WCSession.default
    #if os(iOS)
    guard session.isPaired, session.isWatchAppInstalled else {
      status = "Reviews saved locally. Install Robur on your paired Watch to sync."
      return
    }
    #else
    guard session.isCompanionAppInstalled else {
      status = "Reviews saved locally. Install Robur on your paired iPhone to sync."
      return
    }
    #endif
    for id in store.pendingReviewedIDs.sorted() {
      guard let entry = store.reviews[id], let data = try? WorkoutReviewRules.encode(workoutID: id, entry: entry) else { continue }
      let alreadyQueued = session.outstandingUserInfoTransfers.contains { transfer in
        guard let queued = transfer.userInfo[payloadKey] as? Data,
              let payload = try? WorkoutReviewRules.decode(queued) else { return false }
        return payload.workoutID == id && payload.entry == entry
      }
      if !alreadyQueued { session.transferUserInfo([payloadKey: data]) }
    }
    status = store.pendingReviewedIDs.isEmpty ? "Review sync is up to date." : "Reviews saved; syncing when the paired device is available."
    if !store.pendingReviewedIDs.isEmpty { scheduleRetry() }
    #endif
  }

  private func scheduleRetry() {
    guard retryTask == nil else { return }
    retryTask = Task { [weak self] in
      try? await Task.sleep(for: .seconds(60))
      guard !Task.isCancelled, let self else { return }
      self.retryTask = nil
      self.flush()
    }
  }

  private func acknowledge(_ payload: WorkoutReviewPayload) {
    let session = WCSession.default
    guard session.activationState == .activated,
          let data = try? WorkoutReviewRules.encode(workoutID: payload.workoutID, entry: payload.entry) else { return }
    let queued = session.outstandingUserInfoTransfers.contains { transfer in
      guard let data = transfer.userInfo[receiptKey] as? Data,
            let receipt = try? WorkoutReviewRules.decode(data) else { return false }
      return receipt == payload
    }
    if !queued { session.transferUserInfo([receiptKey: data]) }
  }

  nonisolated func session(_ session: WCSession, activationDidCompleteWith activationState: WCSessionActivationState, error: Error?) {
    let message = error?.localizedDescription
    Task { @MainActor in
      if let message { self.status = "Review sync unavailable: \(message). Changes remain saved locally." }
      else { self.flush() }
    }
  }

  nonisolated func session(_ session: WCSession, didReceiveUserInfo userInfo: [String: Any] = [:]) {
    guard userInfo.count == 1 else { return }
    if let data = userInfo["roburWorkoutReviewReceipt"] as? Data,
       let receipt = try? WorkoutReviewRules.decode(data) {
      Task { @MainActor in
        self.store.markSynced(forID: receipt.workoutID, entry: receipt.entry)
        self.flush()
      }
      return
    }
    guard let data = userInfo["roburWorkoutReview"] as? Data,
          let payload = try? WorkoutReviewRules.decode(data) else { return }
    Task { @MainActor in
      if self.store.mergeRemote(entry: payload.entry, forID: payload.workoutID) {
        // Receipt means the counterpart actually persisted the review, rather
        // than merely accepting a WatchConnectivity transport delivery.
        self.acknowledge(payload)
        self.status = "Workout review received from your paired device."
      } else { self.status = self.store.lastError ?? "Could not save the received review." }
    }
  }

  nonisolated func session(_ session: WCSession, didFinish userInfoTransfer: WCSessionUserInfoTransfer, error: Error?) {
    guard userInfoTransfer.userInfo["roburWorkoutReview"] is Data ||
          userInfoTransfer.userInfo["roburWorkoutReviewReceipt"] is Data else { return }
    let message = error?.localizedDescription
    Task { @MainActor in
      if let message {
        self.status = "Review sync will retry when available: \(message). Changes remain saved locally."
        self.scheduleRetry()
      }
    }
  }

  nonisolated func sessionReachabilityDidChange(_ session: WCSession) { Task { @MainActor in self.flush() } }
  #if os(iOS)
  nonisolated func sessionDidBecomeInactive(_ session: WCSession) {}
  nonisolated func sessionDidDeactivate(_ session: WCSession) { session.activate() }
  nonisolated func sessionWatchStateDidChange(_ session: WCSession) { Task { @MainActor in self.flush() } }
  #else
  nonisolated func sessionCompanionAppInstalledDidChange(_ session: WCSession) { Task { @MainActor in self.flush() } }
  #endif
}
#endif
