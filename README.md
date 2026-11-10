# Robur

Robur is a fitness product with a native Apple HealthKit client, a responsive
web dashboard, and a small production web/API deployment. The Apple apps keep
their current HealthKit reads on the device; the web dashboard continues to use
the shared demo snapshot until a separately approved, consented sync feature is
introduced.

Apple/TestFlight is the active release path. Google Cloud deployments are
paused behind `GCP_DEPLOYMENTS_ENABLED` and an explicit manual dispatch.
Google deployment remains on hold at the user's request. GKE is the selected
future platform; Cloud Run is only an unselected cost proposal. Cloud CI validates
configuration without deploying, and native web sync is disabled in this release.
Recovery and fitness now share a [versioned methodology](docs/recovery-methodology.md).
See [Apple release setup](docs/apple-testflight-release.md) for the remaining
account tasks. Existing GCP resources are not deleted by this pause.

The deployable web stack is GKE and Cloud SQL in GCP project `robur-505508`
(`europe-west2`). It is intentionally a low-volume evaluation environment,
not a highly available production topology.

## Repository layout

- `apps/web` — Vite + React dashboard, packaged as an Nginx container.
- `apps/api` — Node/Express API and future HealthKit-ingest boundary.
- `apps/mobile` — SwiftUI iPhone, iPad, and embedded Watch app with on-device
  HealthKit reading.
- `packages/core` — shared fitness-domain models and demo snapshot.
- `infra/gcp/bootstrap` — versioned Terraform state-bucket bootstrap.
- `infra/gcp/terraform` — GKE, Cloud SQL, networking, Artifact Registry,
  Secret Manager, Pub/Sub, GitHub OIDC, and runtime identities.
- `infra/k8s` — workload, ingress, managed-certificate, migration, and
  runtime-secret manifests.
- `.github/workflows` — the three delivery workflows described below.

## Local validation

```bash
pnpm install
pnpm typecheck
pnpm test
pnpm build
```

Run the dashboard locally with:

```bash
pnpm dev:web
```

## Production boundary and cost posture

The initial GCP apply creates billable resources: a regional GKE control plane,
one workload node, a zonal always-on Cloud SQL Postgres instance, Artifact
Registry, and a GKE Ingress/external Application Load Balancer after the first
application deployment. Cloud SQL does not scale to zero.

To hold the evaluation footprint down, the regional cluster has exactly one
workload node in `europe-west2-b`: a preemptible custom E2 VM with two vCPUs
and 4 GB of memory (`e2-custom-2-4096`). This is the smallest practical shape
for the GKE system pods plus Robur's web/API requests, and avoids a three-zone
node multiplier while retaining a regional control plane. A node preemption or
that zone's outage can make the web/API temporarily unavailable. Do not
describe this configuration as HA.

Artifact Registry removes images older than 14 days while retaining the five
most recent versions; Pub/Sub retains messages for one day. These guardrails
reduce variable storage costs, but do not turn the cluster, database, or load
balancer into a scale-to-zero service. Configure a Cloud Billing budget alert
manually before the first apply; a budget alerts after spend is recorded and is
not a hard spending cap.

## Delivery workflows

There are exactly three workflow files:

| Workflow | Normal behavior | Cost-bearing action |
| --- | --- | --- |
| `apple-build.yml` | Compiles iPhone, iPad, and Watch targets when Apple sources change. | Relevant `main` pushes and manual release dispatches sign and upload to TestFlight; PRs compile and test only. |
| `terraform-deploy.yml` | Production apply is paused; requires repository variable `GCP_DEPLOYMENTS_ENABLED=true` and manual opt-in. | Creates or changes GKE, Cloud SQL, IAM, networking, and related infrastructure. |
| `gke-deploy.yml` | Validates changes; container publishing and deployment are paused behind the same repository variable and manual opt-in. | Uses Artifact Registry, GKE workloads, migrations, Ingress, and managed TLS. |

The CI Repair Agent is a job inside `terraform-deploy.yml`, not a fourth
workflow. It can only create a bounded draft repair PR; it never runs a
Terraform apply in its repair path. See [CI Repair Agent](docs/ci-repair-agent.md).

## Legacy Firebase association

Firebase was previously associated with `robur-505508`. That project
association/default site is irreversible and remains dormant, but the
repository contains no Firebase Hosting configuration, deployment workflow, or
Firebase runtime resource. Do not deploy the web app to Firebase or create
Firebase credentials. The unverified Firebase custom-domain mapping has been
removed; existing `robur.fit` DNS was deliberately left untouched until the
GKE Ingress supplies its replacement address.

## Native app status

The iPhone/iPad app reads permitted HealthKit data on device. Start real-device
validation with [Apple HealthKit device validation](docs/apple-healthkit-device-test.md).
The App IDs are `com.eojgroup.robur` and
`com.eojgroup.robur.watchkitapp`; the Apple Developer Team ID is `VTBJTFDTQY`.

For the complete GCP and manual-account sequence, see:

- [GCP project onboarding](docs/gcp-project-onboarding.md)
- [Administrator manual tasks](docs/admin-manual-tasks.md)
