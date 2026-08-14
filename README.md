# Robur

Robur is a fitness product scaffold with a native Apple HealthKit client and a
responsive web dashboard. The current web release is intentionally static: it
lets us evaluate the complete dashboard mock-up without creating an API,
database, container, cluster, or load-balancer footprint.

## Repository layout

- `apps/web` — Vite + React Robur dashboard.
- `apps/mobile` — SwiftUI iPhone, iPad, and Watch app with on-device HealthKit
  reading.
- `apps/api` — future Node/Express API shell; not deployed during static web
  evaluation.
- `packages/core` — shared fitness-domain models and demo snapshot.
- `infra/gcp/hosting` — Firebase Hosting, keyless GitHub OIDC, and optional
  budget-alert Terraform.
- `infra/gcp/terraform`, `infra/k8s` — deferred GKE/Cloud SQL backend design,
  hard-gated by a protected production variable.
- `.github/workflows` — CI, Apple build, static Hosting deploy, deferred
  backend workflows, and the CI Repair Agent.

## Local validation

```bash
pnpm install
pnpm typecheck
pnpm test
pnpm build
```

Run the web dashboard locally:

```bash
pnpm dev:web
```

## Static web launch

The production web target is Firebase Hosting in GCP project `robur-505508`.
Deployment uses GitHub OIDC—there is no Firebase token, Google service-account
key, or web runtime secret.

Follow [static web hosting onboarding](docs/gcp-project-onboarding.md) for the
small Terraform apply, GitHub environment setup, budget-alert option, first
manual release, and `robur.fit` DNS handoff. The only external manual work is
choosing production reviewers/billing-alert recipients and adding the exact
Firebase DNS records at the domain registrar.

The old GKE/Cloud SQL deployment workflows remain unavailable unless an
administrator deliberately sets the protected `ENABLE_FUTURE_BACKEND=true`
variable and manually confirms the workflow input. Do not enable that path for
the static mock-up.

## Native app status

The iPhone/iPad app reads permitted HealthKit data on-device. Start real-device
validation with [Apple HealthKit device validation](docs/apple-healthkit-device-test.md).
The web dashboard currently uses demo data; it does not sync private HealthKit
data to GCP.

## CI Repair Agent

The repository includes a secure, configuration-driven CI Repair Agent. It
diagnoses selected failed `main` CI runs, makes only explicit deterministic
repairs, validates the bounded diff, and opens a draft PR for human review.
See [CI Repair Agent](docs/ci-repair-agent.md) for the trust model, recipe
allowlist, and operating guide.
