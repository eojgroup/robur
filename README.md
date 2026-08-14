# Robur

Robur is a fitness product with a native Apple HealthKit client, a responsive
web dashboard, and a small production web/API deployment. The Apple apps keep
their current HealthKit reads on the device; the web dashboard continues to use
the shared demo snapshot until a separately approved, consented sync feature is
introduced.

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
workload node in `europe-west2-b`: a preemptible `e2-small`. This avoids a
three-zone node multiplier while retaining a regional control plane. It also
means a node preemption or that zone's outage can make the web/API temporarily
unavailable. Do not describe this configuration as HA.

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
| `apple-build.yml` | Compiles iPhone, iPad, and Watch targets when Apple sources change. | TestFlight upload requires a manual `main` dispatch with its boolean input enabled. |
| `terraform-deploy.yml` | Validates and applies reviewed infrastructure changes pushed to `main`; a manual production apply is also available. | Creates or changes GKE, Cloud SQL, IAM, networking, and related infrastructure. |
| `gke-deploy.yml` | Validates PRs; relevant `main` pushes build, push, and deploy the web/API containers. | Uses Artifact Registry, GKE workloads, migrations, Ingress, and managed TLS. |

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
