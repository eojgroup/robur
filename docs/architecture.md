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

The API accepts an optional `x-healthkit-token` header when `HEALTHKIT_INGEST_TOKEN` is configured. Server-side HealthKit access is not possible; Apple Health data must be read on-device and synced by the iOS app with user permission.

### Apple

`apps/mobile/ios` contains the SwiftUI app for:

- Universal iPhone/iPad target: `com.eojgroup.robur`
- Embedded watchOS app: `com.eojgroup.robur.watchkitapp`

The current native shell includes:

- HealthKit entitlement.
- HealthKit authorization request flow.
- Push Notifications entitlement and APNs registration shell.
- Placeholder Today snapshot aggregation shell.
- iPhone/iPad Today screen matching the mock-up.
- watchOS compact Today/recommendation glance.

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
- GCS Terraform state bucket.
- Artifact Registry repository: `robur-app`.
- GKE cluster: `robur-cluster`.
- Cloud SQL PostgreSQL instance: `robur-sql`.
- Postgres database/user for Robur.
- Pub/Sub topic: `robur-fitness-events`.
- Secret Manager secret for HealthKit ingest token.
- Workload Identity service account for GKE Cloud SQL access.
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
- `Terraform Infrastructure Deployment`: applies GCP Terraform and upserts cluster config/secrets.
- `Build and Deploy to GKE`: builds API/web containers, pushes to Artifact Registry, runs migrations, and deploys manifests.
- `Build Apple clients`: compiles iPhone, iPad, Watch, then uploads to TestFlight when signing is configured.
