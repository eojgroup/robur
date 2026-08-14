# Robur technical structure

Robur is a monorepo for a native Apple HealthKit experience and a web dashboard.
The present release boundary is intentionally small: HealthKit remains on the
device and the web app is a static, deployable product mock-up using shared demo
domain data.

## Applications

### Web

`apps/web` is Vite + React. It is now an operational dashboard rather than a
landing card: a responsive navigation shell, readiness, Health signals,
recommendation, weekly plan, and recovery trend use semantic tokens and
accessible controls. The styling takes the operational hierarchy, tokenized
surfaces, data typography, focus handling, reduced-motion behavior, and mobile
safe-area care of Claritas as principles without reusing its product content,
branding, or assets.

The web build imports no runtime API and can be safely published as static
content. It is served by Firebase Hosting for the current feature-evaluation
phase. The retained Nginx Dockerfile is for a future separately-reviewed backend
architecture; it is not deployed today.

### API

`apps/api` remains a Node/Express API shell with health, readiness, future
HealthKit-sync, and push-registration endpoints. It is not deployed in the
static web phase, and no web client talks to it. A production API requires a
separate authentication, consent, retention, abuse-prevention, and cost review.

### Apple clients

`apps/mobile/ios` contains the SwiftUI iPhone/iPad app
(`com.eojgroup.robur`) and embedded watchOS app
(`com.eojgroup.robur.watchkitapp`). The iPhone/iPad client requests HealthKit
read access and maps workouts, sleep, resting heart rate, HRV, and training
totals on device. The watch UI is a local glance surface; it should not be
described as a synced HealthKit client until a separate data/sync implementation
exists.

## Shared domain model

`packages/core` is the TypeScript source of truth for the static snapshot,
starter plan, week summaries, formatters, and future payload normalization. The
native client has a corresponding Swift model under
`apps/mobile/ios/Sources/RoburShared`.

## Current hosting architecture

```text
GitHub Actions (manual main-only deploy)
  -> GitHub OIDC short-lived token
  -> narrow Firebase Hosting deployer service account
  -> Firebase Hosting CDN + TLS
  -> robur-505508.web.app, then robur.fit after DNS verification
```

`infra/gcp/hosting` declares the Firebase project association, Hosting site,
optional custom-domain request, OIDC identity, narrow IAM grants, and optional
budget alert. No credential key is stored. `firebase.json` supplies cache and
basic security headers for the static release.

The state bucket is provisioned by `infra/gcp/bootstrap`; it keeps versioning
for recovery while removing archived state versions after 90 days.

## Deferred backend architecture

`infra/gcp/terraform`, `infra/k8s`, and the GKE/Cloud SQL workflows remain in
the repository as a future architecture, but are intentionally disabled unless
the protected `production` variable `ENABLE_FUTURE_BACKEND` is explicitly set
to `true`. Those workflows also require a manual boolean input. This makes it
impossible for normal web/UI work to create cluster, database, container, or
load-balancer cost.

## CI/CD

- **Robur CI** runs Node validation and all Terraform roots on Linux. Apple
  compilation lives only in the targeted Apple workflow, avoiding duplicate
  macOS runner cost.
- **Build Apple clients** compiles iPhone, iPad, and Watch when Apple sources
  change; TestFlight remains explicitly gated.
- **Deploy web mock-up** is a manual `main`-only Firebase Hosting release using
  OIDC. It has no GCP secret.
- **Future GKE / Cloud SQL deployment** and **Future GKE application
  deployment** are hard-disabled until a deliberate backend approval.
- **CI Repair Agent** observes selected failed trusted-main runs, uses reviewed
  deterministic recipes, validates a bounded diff, then creates a draft PR.
  See [CI Repair Agent](ci-repair-agent.md).
