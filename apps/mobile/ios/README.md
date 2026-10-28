# Robur Apple Apps

Project path: `apps/mobile/ios`.

The project contains one App Store product with two targets:

- `Robur`: universal iPhone/iPad SwiftUI app.
- `RoburWatch Watch App`: embedded watchOS SwiftUI companion app.

## Quick Start

```bash
brew install xcodegen
pnpm generate:icons
APPLE_TEAM_ID=<your-team-id> ruby generate_xcodeproj.rb
open Robur.xcodeproj
```

The generated project uses automatic signing for Debug. Release signing is
configured only inside the protected TestFlight workflow.

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

TestFlight uses direct signing in GitHub Actions; it does not use Fastlane,
Match, a certificate repository, an Apple ID password, or a downloaded
provisioning-profile secret.

Apple source or workflow changes pushed to `main` compile, test, archive, and
release to TestFlight, as in Claritas. Pull requests only compile and test.
For another release, use **Actions → Build Apple clients → Run workflow**,
select `main`, and leave **distribute to TestFlight** enabled. Uncheck it for
a compile-only diagnostic run. Missing signing credentials fail the release.

See [TestFlight release and manual setup](../../../docs/apple-testflight-release.md)
for the current account configuration, credential commands, and device checks.

### One-time Apple setup

Confirm these identifiers before releasing; App Store bundle identifiers cannot
be changed after publication:

```text
App Store Connect app: Robur Health (Apple ID 6801487531)
Primary iPhone/iPad ID: com.eojgroup.robur
Embedded Watch ID:      com.eojgroup.robur.watchkitapp
```

In Apple Developer, register both explicit IDs and enable **HealthKit** on
both. In App Store Connect, confirm that Apple ID `6801487531` has the primary
bundle ID `com.eojgroup.robur`. The Watch app is embedded in that one iOS App
Store Connect product.

Create a **Team** App Store Connect API key with permission to provision and
upload builds. Do not use an Individual key: the workflow creates/reuses
profiles through the provisioning API. An Account Holder must enable API access,
and an Account Holder or Admin creates the Team key.

Export one active **Apple Distribution** certificate together with its private
key as a password-protected `.p12` file. The certificate must belong to the
same Apple team and be active in Apple Developer.

### Protected GitHub configuration

Add these to the `production` environment:

```text
Variables
  APPLE_TEAM_ID                       Apple Developer Team ID
  APP_STORE_CONNECT_APP_ID            6801487531 for Robur Health
  TESTFLIGHT_GROUP_NAME               Exact pre-created internal beta group name

Secrets
  APP_STORE_CONNECT_KEY_ID            Team API key ID
  APP_STORE_CONNECT_ISSUER_ID         Team API issuer ID
  APP_STORE_CONNECT_PRIVATE_KEY_P8    Literal .p8 file contents, not base64
  APPLE_DISTRIBUTION_CERTIFICATE_P12  Base64-encoded password-protected .p12
  APPLE_DISTRIBUTION_CERTIFICATE_PASSWORD
```

For the P12 secret on a trusted Mac:

```bash
base64 -i RoburDistribution.p12 | pbcopy
```

The workflow creates or renews only the two App Store provisioning profiles
that match that certificate, imports them into an isolated temporary keychain,
archives, exports, uploads the IPA, and removes the signing material at the
end of the job.

Before the first upload, create one internal TestFlight group (for example,
`Robur Test Group`) in App Store Connect and set `TESTFLIGHT_GROUP_NAME` to
its name character-for-character. The workflow requires exactly one matching
group, waits for processing, and assigns the build to it. External testers can
still require Apple beta review.

`VERSION` controls the human marketing version. The workflow derives a unique
Apple-valid build number from the GitHub workflow run, so repeated TestFlight
releases do not collide with build `1`. The current local-only application has
no custom cryptography, so both app targets declare exempt encryption; revisit
that declaration before adding non-exempt encryption.

## Workout journal and progress

The iPhone/iPad app has Today, Workouts, Progress and Places tabs. Workouts
imports Apple Health workouts and supports local muscle tags, perceived effort
(1–10), notes and a saved gym. Session load is minutes × self-rated effort in
arbitrary units; unrated workouts are excluded from effort charts. These details
are not written to HealthKit and do not sync to the Watch or other devices.

Progress offers 30 days, 90 days, one year and all available Health history.
There is no app-imposed date cutoff or sample count limit for All history;
Apple Health permissions and device availability still determine coverage.
VO₂ max, resting HR and HRV use weekly means (monthly for year/all-history),
while workout minutes and effort load use totals. Select either chart to inspect
workouts from the same period. Muscle charts count tagged sessions per group.
Missing Health readings are not replaced with estimated fitness values.

Places saves names with optional coordinates, offers foreground matching within
200 m, and supports both manual check-ins and opt-in automatic background gym
visits. Automatic detection uses Core Location circular-region entry/exit events
with Always authorization, Precise Location and Background App Refresh. At most
20 saved positions are monitored, in save order, with the limit visible in the
UI. It does not start continuous GPS tracking or create Health workouts from
presence. The application delegate restores the location delegate on background
launch. iOS can delay region events or stop delivery after force-quit; manual
check-in remains available. Detected visits are labeled approximate and can be
deleted. Duplicate events are idempotent; automatic exits cannot close a manual
visit. A manual checkout suppresses repeat arrival until a region exit.

Positions older than two minutes or less accurate than 100 m are not used for
foreground suggestions. An overlapping visit suggests a gym in the workout
editor for the user to confirm. Notes, places and visits are written atomically
with iOS complete protection until first user authentication, so background
region events can be saved while locked after the first unlock. An unreadable
existing journal is preserved.

Existing users should tap **Access** on Today or **Manage Health access** in
Workouts/Progress to authorize newly supported data categories. For existing
permission changes, use the Health app. Real-device validation must include old
history, partial permissions, empty VO₂ max history, location denial, inaccurate
positions, background arrivals/departures while locked, permission downgrade, disabling detection, overlapping gym visits, saved tags after relaunch, light/dark mode,
VoiceOver, and large text. Location and actual Health readings cannot be fully
verified in a simulator.
