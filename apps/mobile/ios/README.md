# Robur Apple Apps

Project path: `apps/mobile/ios`.

The project contains one App Store product with two targets:

- `Robur`: universal iPhone/iPad SwiftUI app.
- `RoburWatch Watch App`: embedded watchOS SwiftUI companion app.

## Quick Start

```bash
brew install xcodegen
bundle install
pnpm generate:icons
xcodegen generate --spec project.yml
open Robur.xcodeproj
```

Set the signing team for both targets in Xcode or provide `APPLE_TEAM_ID` in CI.

Claritas-style wrapper commands are also available:

```bash
ruby generate_xcodeproj.rb
ruby validate_xcodeproj.rb
```

## On-Device HealthKit MVP

The app includes:

- `Sources/RoburShared/HealthKitClient.swift` for HealthKit availability,
  authorization, and on-device queries shared by the iPhone/iPad and Watch apps.
- HealthKit entitlements on both targets.
- Actual readings for sleep, resting HR, HRV, workouts, running workout
  distance, cycling distance, strength sessions, and weekly training duration.
- Explicit empty states; the app never substitutes fabricated health metrics.

Apple Health data can only be read on device after user permission. This MVP
keeps data on device and does not call the Robur API, require GCP, or register
for push notifications.

Read [Apple HealthKit device validation](../../../docs/apple-healthkit-device-test.md)
before the first device build. It lists the two Apple identifiers, HealthKit
capabilities, signing setup, and the real-device acceptance checks.

## TestFlight

```bash
bundle exec fastlane ios beta
```

The lane expects App Store Connect, signing, and GitHub secrets described in
`../../../docs/admin-manual-tasks.md`. The GitHub workflow now uploads only
when a maintainer manually dispatches it with **distribute to TestFlight** set
to true; ordinary pushes and pull requests compile only.
