# Prepared private health cloud

The user resumed low-cost Google deployment on 11 November 2026. The active
platform is Cloud Run + Cloud SQL in **`robur-505508`**, with no resources
provisioned in Claritas. The live HTTPS origin is:

**https://robur-health-ydne76eqcq-nw.a.run.app**

The database migration and runtime readiness checks passed. Google Auth Platform
uses a dedicated Robur Web client with this JavaScript origin. The public
example is synthetic; real Health data requires Google sign-in, device pairing
and explicit consent.

## Deployment choice and budget

Legacy regional GKE is unused. Its Terraform and Kubernetes manifests remain
separate and must not be applied within the $25/month ceiling. Repository and
production `GCP_DEPLOYMENTS_ENABLED` gates stay false to prevent those legacy
workflows from provisioning a cluster. Cloud changes on `main` deploy through `cloud-run-deploy.yml`, controlled by
`GCP_HEALTH_DEPLOYMENTS_ENABLED=true`. Pull requests validate only. The separate
legacy deployment gates remain false.

The deployed small-beta profile uses one Cloud Run service for both web and API,
plus a dedicated Cloud SQL PostgreSQL instance. Both stay in `europe-west2`.
The infrastructure is separate from the legacy GKE state:

| Item | Configuration | Planning allowance, USD/month |
| --- | --- | ---: |
| PostgreSQL compute | `db-f1-micro`, single zone, PostgreSQL 17 | $8–12 |
| Database storage | Fixed 10GB SSD; automatic growth disabled | $2–3 |
| Backups | Seven daily backups; no PITR/continuous WAL archive | $1–2 |
| Cloud Run, registry, secrets and light beta traffic | Request billing, minimum zero, maximum one instance | $0–3 |
| Estimated small-beta total | No GKE fee, load balancer, NAT or VPC connector | **$11–20** |

These are conservative planning allowances, not a Google price quote or a hard
billing cap. Cloud Run and egress charges depend on use, and free-tier credits
are shared by billing account. The billing account uses SEK, so an intentionally early 200 SEK/month project
budget alerts at 50%, 80% and 100% (configured as `billing_currency="SEK"`,
`monthly_budget_usd=25`, conservative alert conversion of 8 SEK/USD); budget alerts do not stop spending. The resource settings bound instance
count and disk size, but do not promise a fixed total under arbitrary traffic.
Review billing after initial use before increasing ingestion volume.

Primary pricing references: [GKE](https://cloud.google.com/kubernetes-engine/pricing),
[Cloud SQL](https://cloud.google.com/sql/pricing), and
[Cloud Run](https://cloud.google.com/run/pricing).

`db-f1-micro` has shared CPU and no Cloud SQL SLA. A single-zone beta can have
downtime during maintenance/failure. The fixed disk avoids silent storage-cost
growth; its 80% utilization alert creates a Cloud Monitoring incident. Assign an
operator notification channel to that policy in Cloud Monitoring. At capacity,
sync can fail and must retry after space is recovered or reviewed expansion is
approved. The native device remains the HealthKit source and must retain its
unsent data.

## Security and retention

- The web and API share Google's managed HTTPS `run.app` origin. Custom-domain
  load balancing and DNS are not prerequisites and are not provisioned here.
- Cloud SQL has no authorized client networks. The Cloud Run integration uses
  the Cloud SQL Auth Proxy with IAM authorization and automatic encrypted
  connections. A public SQL IPv4 endpoint without authorized networks is not a
  publicly usable database login. See Google's
  [Cloud SQL connection guidance](https://docs.cloud.google.com/sql/docs/postgres/connect-run).
- The runtime service account can connect to this project's Cloud SQL service
  and read only the runtime connection secret. It cannot read the separate
  administrator/migration connection secret.
- Migrations run under a separate service account and database administrator.
  They remove Cloud SQL's default `cloudsqlsuperuser` membership and role/database
  creation privileges from the `robur_app` runtime login, then grant application
  DML permissions. Schema migration history is not an application-write surface.
- The HTTP service remains IAM-private until that migration succeeds. Its
  eventual public website does not make health endpoints public: the API verifies
  each account/device and scopes records to that owner.
- Database and daily backups remain in London. Cloud SQL encryption at rest is
  provided by Google. Health retention is controlled by the account's consent and
  deletion endpoints. Deleted records can remain in the seven retained daily
  backups until they expire; restoring a backup requires reapplying deletion
  requests before reopening service.
- Terraform state and Secret Manager contain database credentials. State belongs
  in the existing access-controlled GCS state bucket; do not upload state, `.env`,
  keys or local `.tfvars` into source builds or artifacts. `.gcloudignore` excludes
  those files. Neither application logs nor deployment summaries should contain
  health payloads or credentials.

## Reviewed initial rollout

Deploy only after the Cloud Run platform choice and budget are accepted. The
commands below do not apply the old GKE configuration.

1. Initialize the isolated state and prepare a private variable file outside git:

   ```bash
   terraform -chdir=infra/gcp/cloud-run init \
     -backend-config=bucket=robur-tf-state-robur-505508
   ```

   Use `terraform.tfvars.example` for its fields. Select the combined API/web
   immutable commit image; keep `enable_public_service = false`. An empty Google
   web client ID leaves sign-in fail closed until the one-time account setup below.

2. Bootstrap only the APIs and bounded build identity/source bucket, review the
   targeted plan, and apply that plan. Targeted bootstrap is used once because
   Cloud Run requires a real application image at creation:

   ```bash
   terraform -chdir=infra/gcp/cloud-run plan -out=bootstrap.tfplan \
     -target=google_project_service.required \
     -target=google_storage_bucket.build_source \
     -target=google_service_account.build \
     -target=google_storage_bucket_iam_member.build_source \
     -target=google_project_iam_member.build_logs \
     -target=google_artifact_registry_repository_iam_member.build_images
   terraform -chdir=infra/gcp/cloud-run apply bootstrap.tfplan
   ```

3. Build the combined image using Cloud Build (no local Docker daemon needed):

   ```bash
   gcloud builds submit --project robur-505508 --region europe-west2 \
     --config infra/cloudbuild-health.yaml \
     --service-account projects/robur-505508/serviceAccounts/robur-health-build@robur-505508.iam.gserviceaccount.com \
     --gcs-source-staging-dir gs://robur-505508-robur-build-source/sources \
     --substitutions _IMAGE=europe-west2-docker.pkg.dev/robur-505508/robur-app/robur-api:COMMIT_SHA .
   ```

4. Review the complete new-profile plan and apply it with the built image. It
   creates a dedicated database, the private HTTP service, migration job and cost
   controls. Do not use `-target` for this complete deployment.
5. Run `gcloud run jobs execute robur-health-migrate --project robur-505508
   --region europe-west2 --wait`. Check its success, readiness and runtime-role
   privileges without exposing credentials.
6. Set `enable_public_service = true`, review/apply the small IAM change, and
   verify HTTPS health checks plus an unauthenticated health-data request returning
   `401`. Confirm the API never serves a cross-account or demo health dataset.
7. Configure Google sign-in and finish the browser/device consent flow below.

## Google account setup

The deployment cannot invent a Google OAuth web client. In the Robur project's
Google Auth Platform, create or reuse a **Web application** client and add the
deployed HTTPS service URL as an authorized JavaScript origin. Configure the
OAuth consent screen and approved test users for the beta. Only `openid`, profile
and email are used for account identity; HealthKit permission is granted on the
device separately. Do not reuse another app's OAuth client or change its origins.

Set the public client ID in Terraform's `google_web_client_id` and GitHub's
release configuration `GOOGLE_WEB_CLIENT_ID` (if a future deployment workflow uses it); no OAuth client secret belongs in the
browser or iOS app. Verify that API sign-in accepts tokens for this exact client
and rejects different audiences. Pair the native app through the web account's
one-time code, choose data categories, and explicitly enable sync. Health data
must remain local before that choice.

## GitHub Actions delivery

`cloud-run-deploy.yml` is the release path for web, API, database migrations and
this Terraform infrastructure. Relevant pushes to `main` deploy automatically;
manual dispatch redeploys `main`. Pull requests run credential-free validation.
The workflow serializes releases without cancelling a migration in progress.

1. Type checks, tests, production builds, Terraform validation and budget-boundary
   tests pass before cloud credentials are issued.
2. GitHub OIDC impersonates the existing Robur Terraform identity. The provider
   accepts only `eojgroup/robur` on `refs/heads/main`. No long-lived service-account
   key is stored. Production environment variables supply the billing account,
   OAuth public client ID, state bucket and identity-provider identifiers.
3. The workflow initializes the existing `cloud-run/state` backend and verifies
   a complete preflight plan. Docker builds on the GitHub runner and pushes the
   tested image to Robur Artifact Registry, pinned by digest.
4. A complete release plan is checked for the exact Robur project, forbidden
   deletions/replacements, and the approved database/service envelope. The
   migration job is updated first with a targeted, checked plan. Migrations run
   under their separate identity before the new application serves requests.
5. A fresh complete plan is checked and applied, then the workflow verifies
   HTTPS, database readiness, the configured OAuth ID and rejection of anonymous
   and forged credentials. Temporary synthetic PostgreSQL fixtures verify
   consent, pairing, idempotency, owner isolation and cascading deletion.
6. Temporary test jobs and private plan files are removed. Plans/state/credentials
   are never uploaded as artifacts. The Actions summary records the source
   commit and deployed URL. `.dockerignore`/`.gcloudignore` exclude credentials.

The one-time OIDC/permission bootstrap enables GitHub to take over the existing
resources; regular application and infrastructure deployments run in Actions.
The dedicated project budget role grants no billing-account access. The source
Cloud Build recipe remains available for disaster recovery, not routine releases.
Initial provisioning instructions above document the bootstrap already completed.

Native 1.9.0 enables opt-in Cloud sync with the deployed origin. Sign in to the
web dashboard, choose Connect device, then enter the one-use code in Robur →
Settings → Cloud sync, review categories, and upload. Apple builds and TestFlight
releases continue through `apple-build.yml`.

The user verified Google browser sign-in successfully on 11 November 2026.
For future OAuth changes, test interactively with an approved Google account;
CLI login does not provide a browser session. The service verifies issuer,
audience, expiry, signature and verified-email claims. No client secret is used
in the website or native app. No real Health data is uploaded during deployment.

The Terraform provider explicitly charges quota to `robur-505508`, including the
billing-budget API. The billing currency must match the billing account. Google
requires this even when the planning ceiling is expressed in USD. Public website
access does not grant unauthenticated access to private Health routes.

Cloud Run reserves some URL paths ending in `z`; external checks use
`/api/status/live` and `/api/status/ready`. Legacy Kubernetes aliases remain.
See [Google known issues](https://docs.cloud.google.com/run/docs/known-issues#reserved-url-paths).
