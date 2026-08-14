# Robur technical structure

Robur is a monorepo for a native Apple HealthKit experience and a web dashboard.
Its web release is deployed on GKE with a small Node/Express API and private
Cloud SQL database. This is an evaluation-scale architecture with explicit cost
and availability trade-offs, not a scale-to-zero static-hosting setup.

## Applications

### Web

`apps/web` is a Vite + React operational dashboard. Its styling takes the
operational hierarchy, tokenized surfaces, data typography, focus handling,
reduced-motion behavior, and mobile safe-area care of Claritas as principles,
without reusing Claritas branding, content, or assets.

The web image is served by Nginx in GKE. The current dashboard still renders
the shared demo snapshot; deploying the API does not by itself authorize or
implement HealthKit upload from an Apple device.

### API and data services

`apps/api` is a Node/Express service behind the same GKE Ingress as the web
application. The Ingress routes `/api` to the API and `/` to the web service.
The API uses a Cloud SQL Auth Proxy sidecar to reach a private-IP Postgres 15
instance. It has a workload-specific Google service account for Cloud SQL,
Pub/Sub publishing, and read access to the server-side HealthKit ingest token.

The token is mounted from Secret Manager through the GKE Secret Manager CSI
driver. It is a server credential only: it must never be embedded in the iOS
app, Watch app, browser bundle, source repository, or a command line.

### Apple clients

`apps/mobile/ios` contains the SwiftUI iPhone/iPad app
(`com.eojgroup.robur`) and embedded watchOS app
(`com.eojgroup.robur.watchkitapp`). The clients request HealthKit read access
and calculate workouts, sleep, resting heart rate, HRV, and training totals on
device. The Watch is a local companion surface; it is not a server-synced
HealthKit client.

## Deployment and identity flow

```text
GitHub Actions on trusted main
  -> GitHub OIDC, short-lived credentials only
  -> Artifact Registry (web and API images)
  -> regional GKE control plane / one-zone workload node
      -> Nginx web pod
      -> API pod + Cloud SQL Auth Proxy
          -> private Cloud SQL Postgres
          -> Secret Manager and Pub/Sub through workload identity
  -> GKE Ingress + Google-managed certificate
  -> robur.fit after the registrar A-record cutover
```

`infra/gcp/terraform` declares the cloud resources and identities;
`infra/k8s` declares workloads, services, migrations, the managed certificate,
and Ingress. GitHub Actions authenticates using Workload Identity Federation,
not a downloaded Google service-account key. The state bucket is versioned for
recovery and deletes archived state versions after 90 days.

## Deliberate cost and availability boundary

The GKE cluster control plane is regional (`europe-west2`), but its sole node
pool is pinned to one zone (`europe-west2-b`) and contains one preemptible
custom E2 node with two vCPUs and 4 GB of memory (`e2-custom-2-4096`). That is
the important cost boundary: a normal regional node pool would create workload
capacity across three zones. A one-zone Spot/preemptible pool is cheaper but
can be interrupted and is not highly available.

Cloud SQL is `db-custom-1-3840`, zonal, private-IP only, encrypted in transit,
backed up with point-in-time recovery, and configured `ALWAYS` on. It is a
fixed recurring cost even with no traffic. The first Ingress also creates an
external Application Load Balancer, which is another recurring/usage-based
cost. Artifact Registry keeps five recent images and deletes images older than
14 days; the event topic has one-day retention.

There is no automatic scale-to-zero or automatic cost shutdown in this design.
Cloud Billing budgets must be created manually by a billing-account
administrator and are alerts, not hard caps. GKE and Cloud SQL deletion
protection intentionally make a later teardown a reviewed operational change.

## Domain and TLS

The GKE deploy workflow creates the Ingress and its `ManagedCertificate`. It
prints the allocated external IP in its run summary. The DNS owner must replace
the root `A` record for `robur.fit` with that exact IP and preserve unrelated
DNS records. Google-managed TLS becomes active only after public DNS resolves
to the Ingress. Treat the IP as a deployment output: if the Ingress is deleted
and recreated, obtain the new output and repeat the cutover.

## Legacy Firebase state

The GCP project has an irreversible, dormant Firebase association/default
site from an earlier static-hosting experiment. It is not part of the active
architecture: no Firebase configuration, Terraform root, GitHub workflow, or
runtime resource remains in this repository. Its unverified `robur.fit`
custom-domain mapping and dedicated GitHub deploy identity have been removed.
Do not use a Firebase URL, token, service-account key, or DNS record for this
deployment.

## CI/CD

The repository has exactly three workflows:

- **Build Apple clients** (`apple-build.yml`) compiles the Apple targets on
  relevant push/PR changes. TestFlight distribution is a separate manual
  `main` dispatch.
- **Terraform Infrastructure Deployment** (`terraform-deploy.yml`) validates
  and applies infrastructure on trusted `main` infrastructure changes, or on
  an explicit production dispatch. It also hosts the CI Repair Agent job.
- **Build and Deploy to GKE** (`gke-deploy.yml`) validates deployable changes
  on PRs and builds/deploys web/API images on relevant trusted `main` pushes.

The repair job is deliberately integrated into the Terraform workflow so it
does not add a fourth workflow. It receives only a failed-run reference,
revalidates that the referenced run is a trusted failed `main` push or manual
dispatch, and can open a draft PR using a reviewed mechanical recipe. Details are in
[CI Repair Agent](ci-repair-agent.md).
