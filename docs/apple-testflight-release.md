# Robur Apple/TestFlight release

Robur releases a universal iPhone/iPad app and its embedded Watch companion.
Health data stays on each device; no backend, GCP deployment, login, analytics,
or push service is required for this beta. This is the on-device fitness MVP;
web/API sync is deferred.

## Current status and release behavior

GitHub's `production` environment uses:

| Variable | Value |
| --- | --- |
| `APPLE_TEAM_ID` | `VTBJTFDTQY` |
| `APP_STORE_CONNECT_APP_ID` | `6801487531` (Robur Health) |
| `TESTFLIGHT_GROUP_NAME` | `Robur Test Group` |

The Apple signing secrets are configured and have delivered successful TestFlight
releases. The manual account tasks below apply when setting up or rotating them.

The workflow uses ARM (`macos-15`) for simulator testing and pins
`macos-15-intel` for signing/distribution, both with Xcode 26.3.
The generic `macos-15` label routes to ARM runners; on 2 November 2026, run
[41434330544](https://github.com/eojgroup/robur/actions/runs/41434330544) passed all
128 tests and both iPad checks, but its release was cancelled before starting
because GitHub could not acquire an ARM runner. Switching pools addresses that
capacity failure. Running the simulator tests on Intel timed out in
[41490297906](https://github.com/eojgroup/robur/actions/runs/41490297906), so only
the archive/distribution job uses that pool. The [Intel image inventory](https://github.com/actions/runner-images/blob/main/images/macos/macos-15-Readme.md)
includes the selected Xcode version. Apple-source or
Apple-workflow pushes to `main` compile both apps, run simulator unit tests,
then sign, archive, export, upload, wait for Apple processing, and deliver to
`Robur Test Group`. PRs compile/test only. A successful compile alone does not
count as a release: missing credentials fail the TestFlight job.

## Verified release status

[GitHub run 41354317014](https://github.com/eojgroup/robur/actions/runs/41354317014)
successfully built, tested and released version 1.5.0. A green build job alone
does not establish TestFlight availability: verify the archive/upload and final
group-assignment steps too.

## One-time manual account tasks

1. In [Apple Developer identifiers](https://developer.apple.com/account/resources/identifiers/list),
   select team `VTBJTFDTQY`. Confirm explicit IDs `com.eojgroup.robur` and
   `com.eojgroup.robur.watchkitapp`; enable HealthKit on both and save. No
   separate App Store Connect product is needed for the embedded Watch app.
2. In [App Store Connect](https://appstoreconnect.apple.com/apps/6801487531),
   confirm Robur Health uses `com.eojgroup.robur`. Resolve any pending program
   agreements in the Account Holder's account. Do not change the bundle IDs.
3. Under **Users and Access → Integrations → App Store Connect API → Team Keys**,
   use the existing Claritas Team key if it has the needed permissions, or
   create a Team key with Admin access for this provisioning pipeline. The
   Account Holder may first need to request API access. Save the `.p8` download
   securely; Apple only lets you download it once. Record its Key ID and Issuer
   ID. An Individual key is not suitable for the provisioning API here.
4. Obtain an active Apple Distribution certificate and its private key for this
   team. You can reuse Claritas's original password-protected `.p12`. Otherwise,
   create an Apple Distribution certificate using a CSR from Keychain Access,
   install it on the Mac that generated the CSR, then in **Keychain Access → My
   Certificates**, expand the certificate to confirm the private key is present.
   Select the certificate with its private key and **Export Items** as a `.p12`,
   protected by a strong password. Exporting only the public certificate will
   not work. Keep these files outside the repository.
5. In Robur's **TestFlight → Internal Testing**, create/confirm **Robur Test
   Group**. Add the App Store Connect users who should test it. Enable automatic
   distribution if desired. This pipeline requires an internal group; external
   beta testing and Apple's beta review are separate manual tasks.
6. Add the following secrets to
   [GitHub's production environment](https://github.com/eojgroup/robur/settings/environments).
   Open **production → Environment secrets → Add environment secret**.

| Secret | Value |
| --- | --- |
| `APP_STORE_CONNECT_KEY_ID` | Team key's Key ID |
| `APP_STORE_CONNECT_ISSUER_ID` | Team key's Issuer ID |
| `APP_STORE_CONNECT_PRIVATE_KEY_P8` | Entire original `.p8` text, including BEGIN/END lines |
| `APPLE_DISTRIBUTION_CERTIFICATE_P12` | Base64 of the `.p12`, not its file path |
| `APPLE_DISTRIBUTION_CERTIFICATE_PASSWORD` | Password used when exporting the `.p12` |

Alternatively, from a trusted Mac with `gh` authenticated, use these commands
with your real file paths. `gh secret set` prompts securely for values where
no file is supplied; keep secrets out of command arguments and chat.

```bash
gh secret set APP_STORE_CONNECT_KEY_ID --repo eojgroup/robur --env production
gh secret set APP_STORE_CONNECT_ISSUER_ID --repo eojgroup/robur --env production
gh secret set APP_STORE_CONNECT_PRIVATE_KEY_P8 --repo eojgroup/robur --env production < /secure/path/AuthKey.p8
base64 -i /secure/path/Distribution.p12 | gh secret set APPLE_DISTRIBUTION_CERTIFICATE_P12 --repo eojgroup/robur --env production
gh secret set APPLE_DISTRIBUTION_CERTIFICATE_PASSWORD --repo eojgroup/robur --env production
```

Provisioning profiles are generated/reused automatically; do not upload profile
secrets or configure Fastlane/Match. The workflow uses an isolated signing
keychain and removes the keychain and credential files even after a failure.

## Release and verify

After supplying credentials:

```bash
gh workflow run apple-build.yml --repo eojgroup/robur --ref main -f distribute_to_testflight=true
gh run list --repo eojgroup/robur --workflow apple-build.yml --limit 5
# Substitute the new run ID from that list:
gh run watch RUN_ID --repo eojgroup/robur --exit-status
```

You can also use **Actions → Build Apple clients → Run workflow → main**,
leaving **distribute to TestFlight** checked. Approve the production environment
if GitHub shows a pending approval. All future relevant `main` pushes use the
same release path automatically.

Open **Robur Health → TestFlight** and confirm the build is processed and
available to **Robur Test Group**. The distribution client retries Apple HTTP 429/5xx responses up to five
attempts with bounded backoff, and retries transient read failures for GET
requests. Authentication/configuration errors still fail immediately. The
workflow waits up to 20 minutes for Apple processing. If Apple takes longer, check processing in App Store Connect before
releasing again; a new dispatch uses a new build number. Failed/invalid builds
and failed group assignment are errors, not successful releases. Archive/export
diagnostics are retained in the run's artifacts for 14 days.

`apps/mobile/ios/VERSION` controls the marketing version. CI derives an
Apple-valid build number from the workflow run number and retry attempt. Do not
reset the workflow numbering or replace this scheme with local build `1`.

Install Apple's TestFlight app on the tester's iPhone/iPad, accept the invite,
and install Robur. Use the paired iPhone's Watch app to install its companion.
Follow [the device acceptance checklist](apple-healthkit-device-test.md),
including denied/partial permissions, no-data states, real sleep/HR/HRV/workout
readings, and Watch behavior. Simulator tests cannot verify actual HealthKit
permissions or paired Watch installation.

## Privacy and public App Store release

Both bundles include a privacy manifest for the app-only UserDefaults flag.
Robur reads HealthKit locally and transmits none of it. The beta includes an
in-app privacy explanation and explains that fitness estimates are not medical
advice. Before public App Store submission, provide a hosted privacy-policy URL,
support contact/URL, screenshots for supported device sizes, app description,
age rating, and accurate App Privacy answers reflecting the current local-only
behavior. Revisit those answers and the manifest if you add sync or analytics.
Public App Store review/submission is separate from this TestFlight pipeline.

## Google Cloud is paused

The repository variable `GCP_DEPLOYMENTS_ENABLED` is set to `false`. Both
Terraform apply and GKE container publishing/deployment additionally require an
explicit `main` workflow dispatch with their production boolean enabled.
Pushes cannot deploy GCP. Local checks and application validation remain usable.
Existing cloud resources are not destroyed and can continue incurring charges.
When resuming GCP, deliberately set the repository variable to `true`, then
follow the separate GCP onboarding guide and dispatch the required workflow.


The universal 1.4 build embeds `com.eojgroup.robur.widgets` and
`com.eojgroup.robur.watchkitapp.widgets`. `prepare_app_store_profiles.rb` registers
these explicit extension IDs if missing, enables HealthKit, and includes both
profiles in signing/export. The API key needs Certificates, Identifiers & Profiles
access. Widgets inherit the containing app's Health permission and do not require
an App Group. Keep App Intent descriptions free of reserved platform names:
Apple rejected 1.3 build 1000.22.1 for including “iPhone” and “Apple Watch” there.
