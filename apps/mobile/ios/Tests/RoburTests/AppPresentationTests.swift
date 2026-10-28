import XCTest
import SwiftUI
import UIKit
@testable import Robur

final class AppPresentationTests: XCTestCase {
  @MainActor
  func testCapturePhoneScreensInLightAndDarkMode() async throws {
    let suite = "RoburPresentationTests.\(UUID().uuidString)"
    let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let now = Date()
    let workouts = (0..<12).map { index -> WorkoutRecord in
      let start = Calendar.current.date(byAdding: .day, value: -(index * 3 + 1), to: now)!
      return WorkoutRecord(id: "preview-\(index)", start: start, end: start.addingTimeInterval(2700),
        title: index.isMultiple(of: 2) ? "Strength" : "Run", symbol: index.isMultiple(of: 2) ? "dumbbell.fill" : "figure.run",
        minutes: 45, distanceKm: index.isMultiple(of: 2) ? nil : 6.5, energyKcal: 320,
        averageHeartRate: 135, source: "Presentation test")
    }
    let readings = (0..<40).map { index -> FitnessReading in
      let date = Calendar.current.date(byAdding: .day, value: -(index + 1), to: now)!
      return FitnessReading(id: "preview-\(index)", date: date, value: 46 - Double(index) * 0.08, metric: .cardio)
    }
    let health = HealthKitClient(previewWorkouts: workouts, previewReadings: readings, defaults: defaults)
    let journal = WorkoutJournal(url: directory.appendingPathComponent("journal.json"))
    XCTAssertTrue(journal.addGym(name: "Riverside Fitness"))
    for workout in workouts {
      XCTAssertTrue(journal.save(WorkoutAnnotation(muscles: [.back, .glutes], effort: 7,
        gymID: journal.gyms.first?.id, notes: "Deadlift and row session"), for: workout))
    }
    let screens: [(String, AnyView)] = [
      ("today", AnyView(RoburTodayView())),
      ("workouts", AnyView(WorkoutHistoryView())),
      ("progress", AnyView(FitnessHistoryView())),
      ("places", AnyView(GymLocationsView()))
    ]
    let output = FileManager.default.temporaryDirectory.appendingPathComponent("robur-previews")
    try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
    for (name, screen) in screens {
      for dark in [false, true] {
        let controller = UIHostingController(rootView: screen.environmentObject(health).environmentObject(journal))
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 393, height: 852))
        window.rootViewController = controller
        window.overrideUserInterfaceStyle = dark ? .dark : .light
        window.makeKeyAndVisible()
        controller.view.setNeedsLayout()
        controller.view.layoutIfNeeded()
        try await Task.sleep(nanoseconds: 600_000_000)
        var rendered = false
        let image = UIGraphicsImageRenderer(bounds: window.bounds).image { _ in
          rendered = window.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
        }
        XCTAssertTrue(rendered, "Failed to render \(name)")
        let filename = "\(name)-\(dark ? "dark" : "light").png"
        let data = try XCTUnwrap(image.pngData())
        try data.write(to: output.appendingPathComponent(filename))
        let attachment = XCTAttachment(image: image)
        attachment.name = filename
        attachment.lifetime = .keepAlways
        add(attachment)
        window.isHidden = true
      }
    }
  }
}
