import Combine
import Foundation
import MapKit

struct GymMapPlace: Identifiable, Equatable {
  let name: String
  let address: String
  let latitude: Double
  let longitude: Double
  var id: String { "\(name)|\(latitude)|\(longitude)" }
  var coordinate: CLLocationCoordinate2D { .init(latitude: latitude, longitude: longitude) }
  var isValid: Bool { latitude.isFinite && longitude.isFinite && (-90...90).contains(latitude) && (-180...180).contains(longitude) }
}

@MainActor
protocol GymMapSearching: AnyObject {
  func start(query: String, completion: @escaping @MainActor (Result<[GymMapPlace], Error>) -> Void)
  func cancel()
}

@MainActor
private final class AppleGymMapSearch: GymMapSearching {
  private var search: MKLocalSearch?
  func start(query: String, completion: @escaping @MainActor (Result<[GymMapPlace], Error>) -> Void) {
    let request = MKLocalSearch.Request()
    request.naturalLanguageQuery = query
    request.resultTypes = [.pointOfInterest, .address]
    let search = MKLocalSearch(request: request)
    self.search = search
    search.start { response, error in
      Task { @MainActor in
        if let error { completion(.failure(error)); return }
        let places = response?.mapItems.map { item in
          GymMapPlace(name: item.name ?? "Training place", address: item.placemark.title ?? "",
            latitude: item.placemark.coordinate.latitude, longitude: item.placemark.coordinate.longitude)
        } ?? []
        completion(.success(places))
      }
    }
  }
  func cancel() { search?.cancel(); search = nil }
}

/// Searches place names/addresses without requesting or reading the user's location.
/// A request generation rejects callbacks arriving after cancel, timeout or an edit.
@MainActor
final class GymMapSearch: ObservableObject {
  @Published var query = "" { didSet { if query != oldValue { reset() } } }
  @Published private(set) var results: [GymMapPlace] = []
  @Published private(set) var selected: GymMapPlace?
  @Published private(set) var isSearching = false
  @Published private(set) var message: String?
  private let makeSearch: () -> any GymMapSearching
  private var search: (any GymMapSearching)?
  private var generation = UUID()
  private var timeout: Task<Void, Never>?

  init(makeSearch: (() -> any GymMapSearching)? = nil) {
    self.makeSearch = makeSearch ?? { AppleGymMapSearch() }
  }

  func find() {
    reset()
    let text = query.split(whereSeparator: \.isWhitespace).joined(separator: " ")
    guard !text.isEmpty else { message = "Enter a gym name, city or address."; return }
    let requestID = generation
    let request = makeSearch()
    search = request
    isSearching = true
    timeout = Task { [weak self] in
      do { try await Task.sleep(nanoseconds: 15_000_000_000) } catch { return }
      guard let self, self.generation == requestID else { return }
      self.reset()
      self.message = "Maps took too long. Check your connection and try again."
    }
    request.start(query: text) { [weak self] result in
      guard let self, self.generation == requestID else { return }
      self.timeout?.cancel(); self.timeout = nil
      self.search = nil
      self.isSearching = false
      switch result {
      case .success(let places):
        var seen: Set<String> = []
        self.results = places.filter { $0.isValid && seen.insert($0.id).inserted }
        self.message = self.results.isEmpty ? "No places found. Include the city or full address and try again." : nil
      case .failure:
        self.message = "Could not search Apple Maps. Check your connection and try again."
      }
    }
  }

  func select(_ place: GymMapPlace) {
    guard results.contains(place) else { return }
    selected = place
  }

  func reset() {
    generation = UUID()
    search?.cancel(); search = nil
    timeout?.cancel(); timeout = nil
    isSearching = false
    results = []; selected = nil; message = nil
  }
}
