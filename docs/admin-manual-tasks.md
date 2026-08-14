# Robur administrator tasks

Automation owns the repeatable infrastructure and deployment wiring. The
following tasks intentionally remain manual because they select account owners,
approval policy, DNS ownership, or third-party credentials.

## Static web launch: required manual decisions

1. Confirm a billing-account administrator who should receive budget alerts.
   If the Terraform budget apply is denied, grant a suitable account-level
   Billing Budget/Costs role, then set `billing_account_id` in the ignored
   Hosting Terraform variables and reapply. A budget alerts; it cannot stop
   charges by itself.
2. Add the appropriate people as required reviewers to GitHub’s `production`
   environment if the organization requires deployment approval. The helper
   enforces `main` as the only deployment branch but intentionally does not
   select reviewers.
3. After the Hosting Terraform apply, add the exact Firebase-issued DNS records
   shown by `terraform output -json custom_domain_dns_updates` at the registrar
   for `robur.fit`. Do not guess the records or point the domain at GKE.

The complete command sequence is in
[static web hosting onboarding](gcp-project-onboarding.md).

### GitHub variables and secrets for static Hosting

Run `infra/scripts/configure-github-hosting.sh` after the Hosting Terraform
apply. It creates the required `production` environment variables automatically.
There are no static-Hosting GitHub secrets and no service-account JSON key:

```text
No FIREBASE_TOKEN
No Google service-account key
No Google OAuth client secret
No Apple HealthKit secret
```

The deployment workflow uses GitHub OIDC and a narrow Google service account.

## Apple Developer and HealthKit

For the current on-device HealthKit milestone, follow
[Apple HealthKit device validation](apple-healthkit-device-test.md) before
creating TestFlight credentials.

The identifiers are already configured as:

```text
iPhone/iPad: com.eojgroup.robur
Watch app:   com.eojgroup.robur.watchkitapp
```

Enable these capabilities in Apple Developer:

```text
HealthKit
App Groups only if a future iPhone/watch shared-store design needs it
Push Notifications only when server-side push delivery is implemented
```

Create the App Store Connect app manually:

```text
Name: Robur
SKU: robur-ios
Primary bundle ID: com.eojgroup.robur
Platform: iOS
```

### Apple delivery secrets, only when TestFlight is enabled

The TestFlight workflow is deliberately separate from static web launch. It
needs these `production` GitHub secrets only once signing/distribution is ready:

```text
MATCH_PASSWORD
APP_STORE_CONNECT_API_KEY_ID
APP_STORE_CONNECT_API_ISSUER_ID
APP_STORE_CONNECT_API_KEY  (base64-encoded .p8 contents)
```

It also needs these environment variables:

```text
APPLE_TEAM_ID
MATCH_GIT_URL
```

Create a private Fastlane match repository and populate it from a trusted Mac:

```bash
cd apps/mobile/ios
bundle install
MATCH_GIT_URL=git@github.com:eojgroup/robur-apple-certificates.git \
MATCH_PASSWORD=<new-password> \
APPLE_TEAM_ID=<team-id> \
bundle exec fastlane match appstore \
  --app_identifier com.eojgroup.robur,com.eojgroup.robur.watchkitapp
```

Before external TestFlight/App Store review, an administrator must complete the
privacy policy, HealthKit purpose strings/disclosures, app privacy labels,
export compliance, age rating, screenshots, support URL, and review metadata.

## Future server-side HealthKit sync

The current iPhone app reads HealthKit only on device. It does not upload health
data and the static web mock-up has no API connection. Do not add a shared
HealthKit ingest token to an iOS app, watch app, Firebase config, or GitHub
secret. Before enabling a backend, implement per-user authentication, consent,
ownership checks, rate limiting, audit logging, retention/deletion, and an
updated security review.

## CI Repair Agent

The agent has no third-party AI key or GitHub secret. Repository administrators
should review its configuration and decide whether its GitHub App/GITHUB_TOKEN
may create draft branches and pull requests. Its scope, safeguards, and recipe
extension process are documented in [CI Repair Agent](ci-repair-agent.md).
