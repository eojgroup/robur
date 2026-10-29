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
        averageHeartRate: 135, source: "Presentation test", appleEffort: Double(5 + index % 4),
        heartRateSamples: (0..<45).map { minute in WorkoutHeartSample(date: start.addingTimeInterval(Double(minute) * 60), bpm: 115 + Double(minute % 40)) })
    }
    let readings = (0..<40).map { index -> FitnessReading in
      let date = Calendar.current.date(byAdding: .day, value: -(index + 1), to: now)!
      return FitnessReading(id: "preview-\(index)", date: date, value: 46 - Double(index) * 0.08, metric: .cardio)
    }
    let days = (0..<91).map { index -> DailyHealthMetrics in
      let date = Calendar.current.startOfDay(for: Calendar.current.date(byAdding: .day, value: -index, to: now)!)
      return DailyHealthMetrics(date: date, sleepMinutes: 430 + Double(index % 30), steps: 7000 + Double((index * 211) % 4000),
        exerciseMinutes: 25 + Double(index % 30), standMinutes: 90 + Double(index % 20), activeEnergyKcal: 450 + Double(index % 100),
        restingHR: 54 + Double(index % 5), hrv: 55 + Double(index % 10), vo2Max: 46 - Double(index) * 0.02, weightKg: 78 + Double(index) * 0.01)
    }
    let health = HealthKitClient(previewWorkouts: workouts, previewReadings: readings, defaults: defaults,
      previewDays: days, previewProfile: HealthProfile(age: 35, biologicalSex: "Male", bloodType: "A+", heightCm: 180, weightKg: 78, bodyFatPercent: 19, bmi: 24.1))
    let journal = WorkoutJournal(url: directory.appendingPathComponent("journal.json"))
    XCTAssertTrue(journal.addGym(name: "Riverside Fitness"))
    for workout in workouts {
      XCTAssertTrue(journal.save(WorkoutAnnotation(muscles: [.back, .glutes], effort: 7,
        gymID: journal.gyms.first?.id, notes: "Deadlift and row session"), for: workout))
    }
    let monitor = GymMonitor(journal: journal, defaults: defaults)
    let screens: [(String, AnyView)] = [
      ("today", AnyView(RoburTodayView())),
      ("workouts", AnyView(WorkoutHistoryView())),
      ("progress", AnyView(FitnessHistoryView())),
      ("places", AnyView(GymLocationsView()))
    ]
    let output = FileManager.default.temporaryDirectory.appendingPathComponent("robur-previews")
    try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
    let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
    let originalWindow = scene.windows.first { $0.isKeyWindow }
    defer { originalWindow?.makeKeyAndVisible() }
    for (name, screen) in screens {
      for dark in [false, true] {
        let controller = UIHostingController(rootView: screen.environmentObject(health).environmentObject(journal).environmentObject(monitor))
        let window = UIWindow(windowScene: scene)
        window.frame = scene.coordinateSpace.bounds
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
