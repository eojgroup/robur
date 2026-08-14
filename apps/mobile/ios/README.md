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

## HealthKit Shell

The app includes:

- `Sources/RoburApp/HealthKitClient.swift` for HealthKit availability, authorization, and future query aggregation.
- HealthKit entitlements on iOS and watchOS targets.
- A Today screen with recovery, training load, sleep, resting HR, HRV, recommendation, and weekly totals.
- A compact watchOS Today glance.

Apple Health data can only be read on device after user permission. The API receives only the app's user-approved summary payload through `/api/healthkit/sync`.

## TestFlight

```bash
bundle exec fastlane ios beta
```

The lane expects App Store Connect, signing, and GitHub secrets described in `../../../docs/admin-manual-tasks.md`.
