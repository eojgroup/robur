# Robur

Robur is a fitness application scaffold prepared for web, API, iOS, iPadOS, and watchOS deployment.

This repository is structured as a deployment-ready monorepo:

- `apps/web`: Vite + React web app for the Robur fitness dashboard.
- `apps/api`: Node.js/Express API shell for HealthKit sync, readiness metrics, and future ingestion jobs.
- `apps/mobile`: Native SwiftUI app targeting iPhone, iPad, and Apple Watch.
- `packages/core`: Shared Robur fitness domain models and calculations for app surfaces.
- `infra/gcp`: Terraform, Cloud SQL migrations, and Google Cloud deployment infrastructure.
- `infra/k8s`: Kubernetes manifests for GKE workloads.
- `infra/scripts`: Deployment helpers.
- `.github/workflows`: CI, GKE deploy, Terraform deploy, and Apple TestFlight deploy pipelines.
- `docs`: Architecture and administrator setup runbooks.

## Local Setup

```bash
pnpm install
pnpm typecheck
pnpm test
pnpm build
```

Run the web app locally:

```bash
pnpm dev:web
```

## Deployment Readiness

The automated pieces are in place, but first deployment still requires administrator setup in Google Cloud, GitHub, Apple Developer, App Store Connect, and DNS.

Start with [docs/admin-manual-tasks.md](docs/admin-manual-tasks.md), then use:

- `.github/workflows/terraform-deploy.yml` to apply Google Cloud infrastructure once OIDC is configured.
- `.github/workflows/gke-deploy.yml` to build web/API containers, push them to Artifact Registry, and deploy to GKE.
- `.github/workflows/apple-build.yml` to compile iOS/iPadOS/watchOS and upload to TestFlight when signing is configured.

## Claritas Baseline

Claritas is a private repository. The GitHub connector inspection showed it uses a GCP monorepo structure with `apps/web`, `apps/mobile`, `apps/api`, `infra/gcp`, `infra/k8s`, GKE, Cloud SQL PostgreSQL, Artifact Registry, Workload Identity, and GitHub Actions OIDC. Robur now follows that structure with fitness-domain naming.
