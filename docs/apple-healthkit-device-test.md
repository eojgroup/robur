# Apple HealthKit Device Validation

This device check proves the iPhone/iPad and Apple Watch read approved Apple
Health data locally. GCP and TestFlight delivery are separate concerns; neither
is needed to validate HealthKit reads on a physical device.

## What the current app does

Both native targets use the same on-device `HealthKitClient` and request read
access to workouts, sleep analysis, resting heart rate, HRV, and cycling
distance. The iPhone/iPad app additionally requests heart rate, active energy
and VO₂ max to show per-workout details and historical fitness charts. It then
calculates a local Today snapshot:

- Sleep is the union of approved asleep-stage samples in the latest 36 hours,
  so overlapping Core, Deep, and REM samples are not double-counted.
- Resting heart rate and HRV use the most recent sample in the past seven days.
- Running totals use only `HKWorkout` records marked **Running**, so walking
  distance is not accidentally reported as running.
- Cycling uses cycling-workout distance when available, otherwise approved
  cycling-distance samples; strength sessions and training duration come from
  workouts this ISO week.

All values remain on device. A read request completing successfully does not
prove that every type was approved: Apple deliberately makes denied read access
indistinguishable from an empty Health store. Robur therefore reports that no
approved data is available instead of claiming a permission denial.

## Manual Apple setup

1. Install the full current Xcode release on the development Mac and sign into
   Xcode with the Robur Apple Developer account. Command Line Tools alone cannot
   build an iPhone or Apple Watch app. Install XcodeGen too:

   ```bash
   brew install xcodegen
   ```

2. Before creating anything in the Apple portal, confirm that these are the
   final bundle IDs. An App Store app cannot change its bundle ID after release.
   The code currently uses these **explicit** App IDs:

   ```text
   com.eojgroup.robur
   com.eojgroup.robur.watchkitapp
   ```

   In Apple Developer > Certificates, Identifiers & Profiles, create or confirm
   both IDs and enable **HealthKit** for both. Do not enable Clinical Health Records,
   HealthKit Background Delivery, App Groups, or Push Notifications for this
   local-read MVP. If the IDs already exist, changing a capability requires new
   provisioning profiles.

3. Obtain the Apple Developer Team ID. For local development the generated
   project uses automatic signing in Debug; the protected TestFlight workflow
   configures direct manual distribution signing. You can first try a free Xcode
   Personal Team for a personal device test, but its App IDs, devices, and
   provisioning profiles expire after seven days. A paid Apple Developer Program
   team is required for TestFlight and App Store distribution; use it now if
   Xcode cannot provision the HealthKit capability for the Personal Team.

4. Generate the project with the real team ID, then open it in Xcode:

   ```bash
   cd apps/mobile/ios
   APPLE_TEAM_ID=<your-10-character-team-id> ruby generate_xcodeproj.rb
   open Robur.xcodeproj
   ```

   Confirm the selected team under Signing & Capabilities for `Robur` and
   `RoburWatch Watch App`. Xcode automatic signing should make development
   profiles for the two HealthKit-enabled IDs.

5. Connect an iPhone on iOS 17 or later, trust the Mac, and enable Developer
   Mode if iOS requests it. To verify Watch data, pair an Apple Watch on
   watchOS 10 or later with that phone. Select the iPhone as the `Robur` scheme
   destination and run it; the Watch companion is embedded in that build.

Apple references: [register an App ID](https://developer.apple.com/help/account/identifiers/register-an-app-id), [enable capabilities](https://developer.apple.com/help/account/identifiers/enable-app-capabilities/), and [configure HealthKit access](https://developer.apple.com/documentation/xcode/configuring-healthkit-access).

## Device acceptance test

1. In the Health/Fitness apps, ensure the test account has a recent sleep
   session with asleep stages, a resting-heart-rate sample, an HRV sample, a
   running workout, a cycling workout or cycling-distance sample, and optionally
   a strength workout. Let the Watch finish synchronizing to the phone.
2. Run Robur on the phone, tap **Connect Apple Health**, and select the requested
   read categories. If iOS offers limited or full historical access, use full
   access for this test.
3. Confirm the phone view shows real values rather than the empty-state dashes:
   sleep is plausible and not inflated by sleep stages; RHR and HRV are recent;
   running and cycling totals match the Health app for this week; strength and
   training duration match workouts.
4. Run the embedded Watch app and tap **Connect Apple Health** there too. Verify
   that its Today values match the Health data available on the Watch.
5. Test an empty or revoked-access case. The app should remain usable, show
   **Connect Apple Health** / **No approved Apple Health data found yet**, and
   never show sample placeholder metrics.

`xcodebuild` or GitHub Actions can compile the project, but only this physical
device test can confirm Apple Health authorization and real data availability.

## Distribution after the device test

- Confirm the App Store Connect iOS record `Robur Health` (Apple ID
  `6801487531`) uses `com.eojgroup.robur`; the Watch app is embedded in that
  product.
- Configure the direct-signing Team API key, Apple Distribution P12, and exact
  internal TestFlight group documented in
  [the Apple app README](../apps/mobile/ios/README.md). Fastlane Match and a
  certificate repository are not used.
- Publish an accurate privacy policy before external TestFlight or App Store
  distribution. It must describe the exact Health data used and any future
  sharing. HealthKit data must not be used for advertising or sale.

See Apple's [HealthKit authorization guidance](https://developer.apple.com/documentation/healthkit/authorizing-access-to-health-data), [HealthKit privacy guidance](https://developer.apple.com/documentation/healthkit/protecting-user-privacy), and [TestFlight overview](https://developer.apple.com/help/app-store-connect/test-a-beta-version/testflight-overview/).


## Workout journal, history and automatic gym visits

- Share workout and fitness history, select **All history**, and compare the
  earliest visible workout with the Health app. Also try a restricted-history
  authorization. Switch back to 30 days and confirm no older records remain.
- Tag muscles, set effort, add notes and a gym to a real workout. Relaunch and
  confirm the details persist. Clear effort and confirm that session is excluded
  from effort load, while its duration remains in training volume.
- Compare weekly/monthly VO₂ max, resting HR and HRV chart averages with the
  underlying Health readings. Choose a chart date and verify the related
  workouts are from that same period. No-data types must remain empty.
- At your gym, save its position in **Places**, enable **Automatic gym visits**,
  and grant **Always** location access. Keep Precise Location and Background
  App Refresh enabled. Leave, return and leave again with the phone locked;
  verify one approximate detected visit, with no duplicate records. Geofence
  delivery can be delayed by iOS and is not guaranteed after force-quit.
- Manually check out while still inside the region. Verify that repeated inside
  events do not reopen the visit until a departure and later arrival.
- Confirm automatic events cannot replace or close a manual check-in. Disable
  automatic detection and verify monitored regions stop. Revoke Always/Precise
  access or Background App Refresh and confirm the app explains the missing
  setting and leaves manual check-in available.
- Update an existing gym position and verify the old region is replaced. Delete
  a mistaken detected visit and verify the original Health workout is unchanged.
  A gym visit alone must never create a Health workout.
- Review all screens on iPhone/iPad in light/dark appearance, with large text and
  VoiceOver. Simulator previews use explicit test fixtures, never sample values
  in the shipped application's normal data path.

Apple's [region monitoring documentation](https://developer.apple.com/library/archive/documentation/UserExperience/Conceptual/LocationAwarenessPG/RegionMonitoring/RegionMonitoring.html)
explains background event delivery and the limit of 20 monitored regions per app.
