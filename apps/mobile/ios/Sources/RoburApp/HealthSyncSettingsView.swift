import SwiftUI

struct HealthSyncSettingsView: View {
  @EnvironmentObject private var health: HealthKitClient
  @EnvironmentObject private var journal: WorkoutJournal
  @StateObject private var cloud = CloudHealthSync.shared
  @State private var code = ""
  @State private var accepted = false
  @State private var detailed = false
  @State private var reviews = false
  @State private var deleting = false

  private var choicesMatch: Bool { detailed == cloud.detailedSamples && reviews == cloud.workoutReviews }
  private var origin: URL? { try? CloudHealthSync.origin(cloud.serverOrigin) }

  var body: some View {
    Form {
      if !CloudHealthSync.deploymentEnabled {
        Section("Web sync paused") {
          Text("The web service has not been deployed. Cloud uploads are disabled in this build; all Health data stays on this device.")
          Text("Recovery, fitness history and all other on-device features remain available.").font(.caption).foregroundStyle(.secondary)
        }
      } else {
        Section("Private web dashboard") {
          Text("Connect a browser and this device to view the same training and Health history. Cloud sync is optional; all on-device features work without it.")
            .font(.subheadline)
          TextField("Dashboard HTTPS address", text: $cloud.serverOrigin)
            .keyboardType(.URL).textInputAutocapitalization(.never).autocorrectionDisabled()
            .disabled(cloud.connected || cloud.working)
          if let origin {
            Link("Open dashboard and create a device code", destination: origin)
            Link("Privacy and data retention", destination: origin.appendingPathComponent("privacy"))
          }
        }
        if !cloud.connected {
          Section("Connect this device") {
            Text("Sign in on the web dashboard, create a one-use device code, and enter it here. The connection is stored in this device’s Keychain.")
              .font(.caption).foregroundStyle(.secondary)
            TextField("One-use connection code", text: $code)
              .textInputAutocapitalization(.characters).autocorrectionDisabled()
            Button("Connect & save upload choices") {
              Task { await cloud.connect(code: code, detailed: detailed, reviews: reviews); code = "" }
            }.disabled(!accepted || code.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || origin == nil || cloud.working)
          }
        }
        Section("Choose what can leave this device") {
          Text("Approved daily sleep, HRV (SDNN), resting heart rate, respiratory rate, oxygen saturation, steps, exercise, stand minutes, active energy, VO₂ max and body measurements; workout types, times, duration, distance, energy and effort; versioned score history and its components.")
            .font(.caption)
          Toggle("Include workout reviews", isOn: $reviews)
          Text("Optional muscle groups, personal ratings and notes can contain sensitive free text.")
            .font(.caption).foregroundStyle(.secondary)
          Toggle("Include workout observations", isOn: $detailed)
          Text("Optional workout heart-rate observations take longer to read and upload. This is not a full raw Apple Health archive. GPS routes, Medical ID, blood type and clinical records are excluded.")
            .font(.caption).foregroundStyle(.secondary)
          Toggle("I allow these selected datasets to be stored in my private Robur cloud account", isOn: $accepted)
          Text("Review the destination above. Uploads are manual and use HTTPS. Read access in Apple Health does not itself authorize cloud uploads.")
            .font(.caption).foregroundStyle(.secondary)
        }.disabled(cloud.working)
        if cloud.connected {
          Section("Upload history") {
            Button("Save upload choices / resume") { Task { await cloud.resume(detailed: detailed, reviews: reviews) } }
              .disabled(!accepted || cloud.working)
            Button("Upload all available approved history") { cloud.startUpload(health: health, journal: journal) }
              .disabled(!accepted || !cloud.enabled || !choicesMatch || cloud.working || !health.authorizationRequested)
            if cloud.uploading { Button("Cancel upload") { cloud.cancelUpload() } }
            if !health.authorizationRequested { Button("Connect Apple Health first") { health.requestAuthorization() } }
            Text("Uploads include available history and update matching records on repeat. Missing categories stay missing. Deletions in Apple Health are not automatically propagated; delete cloud data here to clear the saved dataset.")
              .font(.caption).foregroundStyle(.secondary)
            Button("Pause cloud consent") { Task { await cloud.pause(); accepted = false } }
              .disabled(cloud.working && !cloud.uploading)
            Button("Disconnect this device") { Task { await cloud.disconnectDevice(); accepted = false } }.disabled(cloud.working)
            Button("Delete cloud health data", role: .destructive) { deleting = true }.disabled(cloud.working)
          }
        }
        Section("Status") {
          Text(cloud.status).font(.subheadline)
          if cloud.working { ProgressView() }
          if let date = cloud.lastUpload { LabeledContent("Last upload", value: date.formatted(date: .abbreviated, time: .shortened)) }
          if let error = cloud.error { Text(error).font(.caption).foregroundStyle(.red) }
        }
      }
    }
    .navigationTitle("Web & data sync")
    .scrollContentBackground(.hidden).background(RoburStyle.background)
    .onAppear { detailed = cloud.detailedSamples; reviews = cloud.workoutReviews; accepted = cloud.enabled }
    .confirmationDialog("Delete all cloud health records?", isPresented: $deleting, titleVisibility: .visible) {
      Button("Delete cloud data and revoke devices", role: .destructive) { Task { await cloud.deleteCloudData(); accepted = false } }
    } message: {
      Text("This removes your saved cloud health dataset and revokes connected devices. Your local Apple Health records and Robur reviews remain on this device. Backup copies expire under the service’s retention policy.")
    }
  }
}
