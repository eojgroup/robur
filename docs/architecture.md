# Robur Technical Structure

Robur now follows the Claritas GCP pattern inspected through the private GitHub connector.

## Claritas Patterns Applied

Claritas uses:

- `apps/web` for React + Vite.
- `apps/mobile` for native SwiftUI iPhone, iPadOS, and watchOS clients.
- `apps/api` for the Node.js API.
- `infra/gcp/terraform` for Google Cloud infrastructure.
- `infra/k8s` for GKE manifests.
- `infra/scripts` for deployment helpers.
- GKE, Artifact Registry, Cloud SQL PostgreSQL, Pub/Sub, Secret Manager, Workload Identity, and GitHub Actions OIDC.

Robur mirrors that shape with fitness-domain resources and naming.

## Applications

### Web

`apps/web` is a Vite + React dashboard. The current screen implements the supplied Today mock-up:

- Recovery and training load scores.
- Sleep, resting heart rate, and HRV.
- Today's recommendation.
- Weekly running, cycling, strength, and training totals.

The web app is containerized with `apps/web/Dockerfile` and served by Nginx with `/healthz` and `/readyz` probes.

### API

`apps/api` is a Node.js/Express API shell for fitness data and HealthKit sync.

Endpoints:

- `GET /healthz`
- `GET /readyz`
- `GET /api/fitness/today`
- `POST /api/healthkit/sync`
- `POST /api/push/register`

The API accepts an optional `x-healthkit-token` header when its server-only
HealthKit ingest token is configured. In GKE the token is mounted from Google
Secret Manager; no static token is shipped to an Apple client. Server-side
HealthKit access is not possible; Apple Health data must be read on-device and
synced by the iOS app with user permission.

### Apple

`apps/mobile/ios` contains the SwiftUI app for:

- Universal iPhone/iPad target: `com.eojgroup.robur`
- Embedded watchOS app: `com.eojgroup.robur.watchkitapp`

The current native MVP includes:

- HealthKit entitlement on both targets.
- HealthKit authorization and on-device query flow for workouts, sleep, resting
  heart rate, HRV, and training totals.
- Explicit empty states when a user has no available data or has not granted
  read access.
- iPhone/iPad Today screen and watchOS Today/recommendation glance backed by
  real device data.

## Shared Code

`packages/core` contains the TypeScript source of truth for:

- Today fitness snapshot.
- Week totals.
- Recommendation label formatting.
- HealthKit sync payload normalization.
- Starter training-plan calculations.

The Apple app mirrors the initial model in Swift under `apps/mobile/ios/Sources/RoburShared`.

## Infrastructure

`infra/gcp/terraform` provisions the GCP baseline:

- Required Google APIs.
- GCS Terraform state bucket, created by the separate bootstrap root because a
  backend must exist before the main Terraform state can be initialized.
- Artifact Registry repository: `robur-app`.
- GKE cluster: `robur-cluster`.
- Cloud SQL PostgreSQL instance: `robur-sql`.
- Postgres database/user for Robur.
- Pub/Sub topic: `robur-fitness-events`.
- Secret Manager secret for the server-only HealthKit ingest token, mounted into
  the API with the GKE Secret Manager add-on.
- Dedicated node, API, and migration workload identities with only the required
  Cloud SQL, Pub/Sub, image-pull, logging, monitoring, and secret-access roles.
- GitHub Actions Workload Identity Pool/provider and deploy service account.

`infra/gcp/sql` contains SQL migrations for HealthKit sync events and daily fitness snapshots.

`infra/k8s` contains:

- Namespace and service accounts.
- Robur config map.
- API and web deployments/services.
- Flyway migration job.
- GKE managed certificate and ingress.

## CI/CD

Workflows:

- `Robur CI`: Node typecheck/test/build, Terraform validation, Kubernetes script checks, and unsigned Apple compile on macOS.
- `Terraform Infrastructure Deployment`: manually gated; applies GCP Terraform and upserts cluster config/secrets only when `apply_production` is enabled.
- `Build and Deploy to GKE`: manually gated; builds API/web containers, pushes to Artifact Registry, runs migrations, and deploys manifests only when `deploy_production` is enabled.
- `Build Apple clients`: compiles iPhone, iPad, Watch, then uploads to TestFlight only when manually dispatched with its distribution input enabled.
