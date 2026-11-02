import XCTest
@testable import Robur

@MainActor
final class GymMapSearchTests: XCTestCase {
  private final class Search: GymMapSearching {
    var query: String?
    var cancelled = false
    var completion: (@MainActor (Result<[GymMapPlace], Error>) -> Void)?
    func start(query: String, completion: @escaping @MainActor (Result<[GymMapPlace], Error>) -> Void) {
      self.query = query; self.completion = completion
    }
    func cancel() { cancelled = true }
  }
  private let berlin = GymMapPlace(name: "Berlin Gym", address: "Berlin", latitude: 52.52, longitude: 13.4)
  private let paris = GymMapPlace(name: "Paris Gym", address: "Paris", latitude: 48.85, longitude: 2.35)

  func testEditingQueryCancelsSearchAndRejectsItsLateResults() {
    let request = Search()
    let model = GymMapSearch(makeSearch: { request })
    model.query = "  Gym\n Berlin  "
    model.find()
    XCTAssertEqual(request.query, "Gym Berlin")
    XCTAssertTrue(model.isSearching)
    model.query = "Paris gym"
    XCTAssertTrue(request.cancelled)
    request.completion?(.success([berlin]))
    XCTAssertTrue(model.results.isEmpty)
    XCTAssertFalse(model.isSearching)
    XCTAssertNil(model.selected)
  }

  func testOnlyCurrentValidResultsCanBeSelectedAndQueryEditsClearCoordinates() {
    let request = Search()
    let model = GymMapSearch(makeSearch: { request })
    model.query = "Berlin gym"
    model.find()
    request.completion?(.success([berlin, berlin, GymMapPlace(name: "Invalid", address: "", latitude: 200, longitude: 0)]))
    XCTAssertEqual(model.results, [berlin])
    model.select(paris)
    XCTAssertNil(model.selected)
    model.select(berlin)
    XCTAssertEqual(model.selected, berlin)
    model.query = "Paris"
    XCTAssertNil(model.selected)
    XCTAssertTrue(model.results.isEmpty)
  }

  func testCancelRejectsResultsAndEmptyOrFailedSearchShowsAnActionableMessage() {
    let request = Search()
    let model = GymMapSearch(makeSearch: { request })
    model.find()
    XCTAssertNil(request.query)
    XCTAssertNotNil(model.message)
    model.query = "Gym"
    model.find()
    model.reset()
    request.completion?(.success([berlin]))
    XCTAssertTrue(model.results.isEmpty)
    model.find()
    request.completion?(.failure(NSError(domain: "Test", code: 1)))
    XCTAssertFalse(model.isSearching)
    XCTAssertNotNil(model.message)
    XCTAssertNil(model.selected)
  }
}
