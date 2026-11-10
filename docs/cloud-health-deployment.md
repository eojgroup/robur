# Low-cost private health cloud

## Deployment choice and budget

The existing Robur project (`robur-505508`) currently has no running GKE cluster,
Cloud SQL instance, VM or load balancer. Its old regional-GKE Terraform is a
different deployment profile and must remain paused for a $25/month budget.
Google charges $0.10/hour for regional GKE management before node, database,
disk or ingress charges; the zonal/Autopilot free-tier credit does not cover a
regional cluster. The unrelated Claritas cluster has active workloads and little
memory headroom; this deployment neither changes nor reuses it.

The prepared small-beta profile uses one Cloud Run service for both web and API,
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
are shared by billing account. The $25 project budget alerts at 50%, 80% and
100%; budget alerts do not stop spending. The resource settings bound instance
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
production variable `GOOGLE_WEB_CLIENT_ID`; no OAuth client secret belongs in the
browser or iOS app. Verify that API sign-in accepts tokens for this exact client
and rejects different audiences. Pair the native app through the web account's
one-time code, choose data categories, and explicitly enable sync. Health data
must remain local before that choice.

## Subsequent application releases

After the initial reviewed infrastructure rollout, set GitHub's production
variables `GCP_DEPLOYMENT_PLATFORM=cloud-run` and `GCP_DEPLOYMENTS_ENABLED=true`,
along with the existing project, region and GitHub Workload Identity variables.
The GitHub deploy identity needs Artifact Registry writer, Cloud Run admin and
service-account impersonation for the runtime/migration accounts, not permanent
database-administrator credentials.

**Validate and deploy low-cost health cloud** validates on relevant pushes;
deploying requires an explicit workflow dispatch with `deploy_production=true`.
It pushes an immutable combined image, executes migrations before replacing the
live service image, retains the zero-to-one instance envelope, and verifies the
HTTPS/authentication boundary. It does not reapply Terraform or create GKE.

Legacy GKE and Terraform workflows require `GCP_DEPLOYMENT_PLATFORM=gke`, the
deployment opt-in, and an explicit dispatch. Merely enabling Cloud Run deployment
cannot trigger the old expensive stack.
