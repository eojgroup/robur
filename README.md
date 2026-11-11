# Robur

Robur combines native iPhone, iPad and Watch clients with a private health
analytics dashboard. Explore metric overlays, score components, personal
baselines, lagged relationships and highlighted periods. The same versioned
recovery and fitness analyses power the native app and optional cloud export.

The beta web/API is deployed on **Cloud Run + PostgreSQL**, entirely within
**`robur-505508`**, in `europe-west2`:
[Open Robur](https://robur-health-ydne76eqcq-nw.a.run.app).
Google sign-in and one-use device pairing keep Health data account-scoped.
Uploads require a separate opt-in; detailed samples and workout reviews have
separate choices. The public analytics example is explicitly synthetic and is
never uploaded.

The planning ceiling is **$25/month**; the SEK billing account has an early
**200 SEK/month** project budget alert. This is a low-volume, single-zone beta,
not a highly available deployment or a hard spending cap. Cloud Run scales to
zero; the small Cloud SQL instance remains running. GKE is unused and its
workflows remain gated off. See [deployment and operations](docs/cloud-health-deployment.md),
[score methodology](docs/recovery-methodology.md), and
[Apple release setup](docs/apple-testflight-release.md).

## Repository layout

- `apps/web` — Vite + React analytics dashboard, served with the API in one container.
- `apps/api` — Node/Express API with authenticated, consented Health sync.
- `apps/mobile` — SwiftUI iPhone, iPad, and embedded Watch app with on-device
  HealthKit reading.
- `packages/core` — shared fitness-domain models and demo snapshot.
- `infra/gcp/bootstrap` — versioned Terraform state-bucket bootstrap.
- `infra/gcp/cloud-run` — active cost-bounded Cloud Run + PostgreSQL configuration.
- `infra/gcp/terraform` — legacy, undeployed GKE, Cloud SQL, networking, Artifact Registry,
  Secret Manager, Pub/Sub, GitHub OIDC, and runtime identities.
- `infra/k8s` — workload, ingress, managed-certificate, migration, and
  runtime-secret manifests.
- `.github/workflows` — the delivery workflows described below.

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

One request-billed Cloud Run service serves web and API, with a maximum of one
instance and no load balancer, NAT or VPC connector. PostgreSQL 17 uses
`db-f1-micro`, fixed 10GB SSD storage and seven daily backups. Separate migration
and runtime identities, encrypted Cloud SQL sockets and Secret Manager protect
the database. Terraform state lives in the Robur project, outside the repository.

Expect roughly $11–20/month for light beta use, subject to actual traffic,
regional prices and shared free-tier credits. Budget alerts at 50/80/100% do not
stop spending. The fixed disk has an 80% monitoring alert; add an operator
notification channel in Cloud Monitoring. See the operations guide before
changing capacity or applying the separate legacy GKE configuration.

## Delivery workflows

Cloud application releases are currently performed with the reviewed Cloud Build/Terraform procedure in the operations guide. Source pushes validate cloud changes without deploying. The Apple release path remains automatic:

| Workflow | Normal behavior | Cost-bearing action |
| --- | --- | --- |
| `apple-build.yml` | Compiles iPhone, iPad, and Watch targets when Apple sources change. | Relevant `main` pushes and manual release dispatches sign and upload to TestFlight; PRs compile and test only. |
| `cloud-run-deploy.yml` | Runs type checks, tests, build and infrastructure validation. | None; cloud releases use the documented manual procedure. |
| `terraform-deploy.yml` | Production apply is paused; requires repository variable `GCP_DEPLOYMENTS_ENABLED=true` and manual opt-in. | Creates or changes GKE, Cloud SQL, IAM, networking, and related infrastructure. |
| `gke-deploy.yml` | Validates changes; container publishing and deployment are paused behind the same repository variable and manual opt-in. | Uses Artifact Registry, GKE workloads, migrations, Ingress, and managed TLS. |

The CI Repair Agent is a job inside `terraform-deploy.yml`, not a separate
workflow. It can only create a bounded draft repair PR; it never runs a
Terraform apply in its repair path. See [CI Repair Agent](docs/ci-repair-agent.md).

## Legacy Firebase association

Firebase was previously associated with `robur-505508`. That project
association/default site is irreversible and remains dormant, but the
repository contains no Firebase Hosting configuration, deployment workflow, or
Firebase runtime resource. Do not deploy the web app to Firebase or create
Firebase credentials. The unverified Firebase custom-domain mapping has been
removed; existing `robur.fit` DNS was deliberately left untouched until the
a separately reviewed custom-domain setup is chosen.

## Native app status

The iPhone/iPad app reads permitted HealthKit data on device. Start real-device
validation with [Apple HealthKit device validation](docs/apple-healthkit-device-test.md).
The App IDs are `com.eojgroup.robur` and
`com.eojgroup.robur.watchkitapp`; the Apple Developer Team ID is `VTBJTFDTQY`.

For the complete GCP and manual-account sequence, see:

- [GCP project onboarding](docs/gcp-project-onboarding.md)
- [Administrator manual tasks](docs/admin-manual-tasks.md)
