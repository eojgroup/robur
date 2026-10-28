import SwiftUI
import CoreLocation
import Combine

@MainActor
final class GymLocator: NSObject, ObservableObject, CLLocationManagerDelegate {
  @Published private(set) var location: CLLocation?
  @Published private(set) var message: String?
  @Published private(set) var locating = false
  private let manager = CLLocationManager()
  private var requested = false

  override init() {
    super.init()
    manager.delegate = self
    manager.desiredAccuracy = kCLLocationAccuracyNearestTenMeters
  }

  func locate() {
    requested = true
    location = nil
    message = nil
    locating = true
    switch manager.authorizationStatus {
    case .notDetermined: manager.requestWhenInUseAuthorization()
    case .authorizedAlways, .authorizedWhenInUse: manager.requestLocation()
    default:
      locating = false
      message = "Location access is off. You can still save gyms and check in manually, or enable location for Robur in Settings."
    }
  }

  func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
    guard requested else { return }
    switch manager.authorizationStatus {
    case .authorizedWhenInUse, .authorizedAlways: manager.requestLocation()
    case .denied, .restricted:
      locating = false
      message = "Location access is off. Manual check-in is always available."
    default: break
    }
  }

  func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
    locating = false
    requested = false
    guard let fix = locations.last, fix.horizontalAccuracy >= 0, fix.horizontalAccuracy <= 100,
          abs(fix.timestamp.timeIntervalSinceNow) < 60 else {
      message = "Could not get an accurate position. Try again outdoors or check in manually."
      return
    }
    location = fix
  }

  func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
    locating = false
    requested = false
    message = "Could not locate you: \(error.localizedDescription)"
  }

  func distance(to gym: GymLocation) -> Double? {
    guard let location, abs(location.timestamp.timeIntervalSinceNow) < 120,
          let latitude = gym.latitude, let longitude = gym.longitude else { return nil }
    return location.distance(from: CLLocation(latitude: latitude, longitude: longitude))
  }
}

struct GymLocationsView: View {
  @EnvironmentObject private var journal: WorkoutJournal
  @StateObject private var locator = GymLocator()
  @State private var adding = false
  @State private var name = ""
  @State private var savePosition = false
  @State private var deleting: GymLocation?

  private var nearby: GymLocation? {
    journal.gyms.compactMap { gym -> (GymLocation, Double)? in
      guard let distance = locator.distance(to: gym), distance <= 200 else { return nil }
      return (gym, distance)
    }.min { $0.1 < $1.1 }?.0
  }

  var body: some View {
    NavigationStack {
      ScrollView {
        VStack(alignment: .leading, spacing: 20) {
          VStack(alignment: .leading, spacing: 6) {
            Text("SHOW UP. BUILD MOMENTUM.").font(.caption.bold()).foregroundStyle(RoburStyle.teal)
            Text("Your training places").font(.largeTitle.bold())
            Text("Save your gym and keep a record of your visits.").foregroundStyle(.secondary)
          }
          if let visit = journal.activeVisit {
            VStack(alignment: .leading, spacing: 12) {
              Label("Checked in", systemImage: "location.fill").foregroundStyle(RoburStyle.teal).font(.headline)
              Text(journal.gymName(visit.gymID) ?? "Fitness centre").font(.title2.bold())
              Text("Since \(visit.start.formatted(date: .abbreviated, time: .shortened))")
              Button("Check out") { journal.checkOut() }.buttonStyle(.borderedProminent)
              Text("A visit records your presence, not an exercise session. Record your workout with your Watch or another Health app.")
                .font(.caption).foregroundStyle(.secondary)
            }.roburCard()
          }
          VStack(alignment: .leading, spacing: 12) {
            Label("Find a saved gym nearby", systemImage: "location.magnifyingglass").font(.headline)
            Text("Use your position once to suggest a saved place within 200 metres. Confirm check-in yourself.")
              .font(.subheadline).foregroundStyle(.secondary)
            Button { locator.locate() } label: { Label("Find nearby", systemImage: "location") }
              .buttonStyle(.bordered).disabled(locator.locating)
            if locator.locating { ProgressView("Finding your position…") }
            if let nearby {
              Text("Nearby: \(nearby.name)").font(.headline)
              Button("Check in at \(nearby.name)") { journal.checkIn(nearby) }
                .disabled(journal.activeVisit?.gymID == nearby.id)
            } else if locator.location != nil {
              Text("No saved gym found nearby. Save your current position when adding a place.").font(.caption)
            }
            if let message = locator.message { Text(message).font(.caption).foregroundStyle(.secondary) }
          }.roburCard()
          HStack {
            Text("SAVED PLACES").font(.caption.bold()).foregroundStyle(.secondary)
            Spacer()
            Button { name = ""; savePosition = false; adding = true } label: { Label("Add place", systemImage: "plus") }
          }
          if journal.gyms.isEmpty {
            ContentUnavailableView("Make it your place", systemImage: "mappin.and.ellipse",
              description: Text("Add a fitness centre, studio or home gym. Coordinates are optional."))
          }
          ForEach(journal.gyms) { gym in
            VStack(alignment: .leading, spacing: 12) {
              HStack {
                Label(gym.name, systemImage: "building.2").font(.headline)
                Spacer()
                Button(role: .destructive) { deleting = gym } label: { Image(systemName: "trash") }
                  .accessibilityLabel("Delete \(gym.name)")
              }
              if let distance = locator.distance(to: gym) {
                Text("\(Int(distance)) m away").font(.caption).foregroundStyle(.secondary)
              }
              let count = journal.visits.filter { $0.gymID == gym.id }.count
              Text("\(count) recorded visits").font(.caption).foregroundStyle(.secondary)
              Button("Check in") { journal.checkIn(gym) }.buttonStyle(.bordered)
                .disabled(journal.activeVisit?.gymID == gym.id)
            }.roburCard()
          }
          if !journal.visits.isEmpty {
            VStack(alignment: .leading, spacing: 12) {
              Text("Recent visits").font(.headline)
              ForEach(Array(journal.visits.suffix(10).reversed())) { visit in
                VStack(alignment: .leading, spacing: 4) {
                  Text(journal.gymName(visit.gymID) ?? "Fitness centre").font(.subheadline.bold())
                  Text(visit.start.formatted(date: .abbreviated, time: .shortened)).font(.caption)
                  if let end = visit.end {
                    Text("\(max(0, Int(end.timeIntervalSince(visit.start) / 60))) min visit").font(.caption).foregroundStyle(.secondary)
                  }
                }
              }
            }.roburCard()
          }
          Text("Your saved places and visit times stay on this device. Location is used only when you request it. Robur does not track visits in the background. In a workout’s details, a visit overlapping that workout suggests its place for you to confirm.")
            .font(.footnote).foregroundStyle(.secondary)
        }.padding()
      }.background(RoburStyle.background)
        .navigationTitle("Places").navigationBarTitleDisplayMode(.inline)
        .sheet(isPresented: $adding) { addPlace }
        .confirmationDialog("Delete this place and its visit history?", isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } })) {
          Button("Delete place", role: .destructive) {
            if let deleting { journal.deleteGym(deleting) }
            deleting = nil
          }
        } message: { Text("Place tags will be removed from workouts. Your other workout details will remain.") }
    }
  }

  private var addPlace: some View {
    NavigationStack {
      Form {
        if let error = journal.storageError { Text(error).foregroundStyle(.red) }
        Section("Fitness centre") { TextField("Name", text: $name) }
        Section {
          Toggle("Save current position", isOn: $savePosition)
          if savePosition {
            Button("Use current position") { locator.locate() }.disabled(locator.locating)
            if locator.locating { ProgressView() }
            if let location = locator.location, abs(location.timestamp.timeIntervalSinceNow) < 120 {
              Label("Position ready", systemImage: "checkmark.circle.fill").foregroundStyle(RoburStyle.teal)
            }
            if let message = locator.message { Text(message).font(.caption) }
          }
        } footer: { Text("Stand at your gym to save its position. You can save a name without location permission.") }
      }
      .navigationTitle("Add place")
      .toolbar {
        ToolbarItem(placement: .cancellationAction) { Button("Cancel") { adding = false } }
        ToolbarItem(placement: .confirmationAction) {
          Button("Save") {
            let position = savePosition ? locator.location : nil
            if journal.addGym(name: name, latitude: position?.coordinate.latitude, longitude: position?.coordinate.longitude) {
              adding = false
            }
          }
          .disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ||
                    (savePosition && (locator.location == nil || abs(locator.location!.timestamp.timeIntervalSinceNow) >= 120 || locator.locating)))
        }
      }
    }
  }
}
