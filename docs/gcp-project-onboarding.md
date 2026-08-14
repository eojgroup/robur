# Robur Google Cloud project onboarding

This guide sets up one isolated production Google Cloud project for Robur. It
keeps infrastructure in Terraform, uses keyless federation for GitHub Actions
and GKE workloads, and keeps runtime HealthKit-ingest material in Secret
Manager. Do not create a Google service-account JSON key.

## What an administrator must decide or authorize

These are account-level actions that code cannot safely decide:

1. Select the Google Cloud organization/folder, a globally unique project ID,
   and a billing account. Create or designate a small administrator group rather
   than using a personal account as the only project owner.
2. Confirm the production region (`europe-west2` is the current default), the
   public domain, and the GitHub repository and deployment branch.
3. Approve GKE and Cloud SQL spend, quotas, and organization policies. This
   project creates GKE, a Cloud SQL Enterprise instance, Artifact Registry,
   Cloud Storage, Pub/Sub, Secret Manager, and their networking components.
4. Configure GitHub's `production` environment with the required reviewers and
   deployment-branch protection appropriate to the organization. The setup
   script creates the environment and variables but deliberately cannot choose
   reviewers on your behalf.
5. Create the public DNS record after the GKE ingress has an IP address. DNS can
   be managed in another project or registrar; its ownership is a business
   decision, so it is not declared in this repository.

## One-time bootstrap

Install the Google Cloud CLI, Terraform 1.8 or newer, and GitHub CLI. Authenticate
with the administrator account that can create/link projects and manage IAM:

```bash
gcloud auth login
gcloud auth application-default login
```

Find the billing account ID (this is read-only):

```bash
gcloud billing accounts list --filter='open=true'
```

The bootstrap script can create the project, attach billing, create a globally
unique versioned state bucket, and initialize the main Terraform backend. It
does not create any service-account key.

```bash
./infra/scripts/bootstrap-gcp.sh \
  --project-id robur-prod-123456 \
  --billing-account 000000-000000-000000 \
  --create-project
```

For an existing, already billed project, omit `--create-project`; the script
will link the supplied billing account. Pass `--organization ORGANIZATION_ID`
when a newly created project must live in a specific organization, or
`--folder FOLDER_ID` when it belongs in a folder.

The state bucket defaults to `robur-tf-state-<project-id>`. This is intentional:
Cloud Storage bucket names are globally scoped, so the old fixed bucket name
would collide with another project. Bootstrap state stays local and ignored by
Git; Robur's actual infrastructure state is in the new versioned bucket.

## Apply the Robur infrastructure

Copy the example values, set the project/repository/domain fields, and keep the
resulting file uncommitted:

```bash
cp infra/gcp/terraform/terraform.tfvars.example infra/gcp/terraform/terraform.tfvars
terraform -chdir=infra/gcp/terraform plan
terraform -chdir=infra/gcp/terraform apply
```

Terraform enables the required APIs and creates:

- an isolated VPC/subnetwork, Artifact Registry, Pub/Sub, Cloud SQL PostgreSQL,
  private-service networking, and GKE with the Secret Manager add-on;
- a GitHub Actions OIDC workload-identity pool and deployer service account;
- dedicated GKE node, API, and migration identities;
- the Cloud SQL and Pub/Sub permissions required by the API and migrations; and
- the `robur-healthkit-ingest-token` Secret Manager container (not its value).

The first apply must use your trusted administrator credentials because the
GitHub OIDC identity does not exist yet. After it succeeds, GitHub Actions uses
OIDC instead of a downloaded key. The provider trust restricts tokens to the
configured GitHub organization, repository, and deployment branch.

## Configure GitHub Actions (automated)

Authenticate the GitHub CLI as a repository administrator, then write the
non-secret production variables from Terraform outputs:

```bash
gh auth login
./infra/scripts/configure-github-production.sh \
  --project-id robur-prod-123456 \
  --state-bucket robur-tf-state-robur-prod-123456 \
  --domain robur.fit \
  --repository eojgroup/robur
```

The script creates/updates these GitHub `production` environment variables:

| Variable | Value source |
| --- | --- |
| `GCP_PROJECT_ID` | project ID |
| `GCP_REGION`, `GCP_ZONE` | chosen deployment location |
| `GCP_TF_STATE_BUCKET` | bootstrap output/default name |
| `GCP_WORKLOAD_IDENTITY_PROVIDER` | Terraform output |
| `GCP_TERRAFORM_SERVICE_ACCOUNT` | Terraform output |
| `GKE_CLUSTER` | Terraform output |
| `WEB_DOMAIN_NAME` | chosen public domain |

Then manually set the `production` environment's required reviewers and limit
deployments to `main`. Do this before enabling or dispatching production
workflows.

## Runtime secret: HealthKit ingest token

Create one opaque 48-byte token without placing it on a command line or in a
Terraform variable/state file:

```bash
openssl rand -base64 48 | ./infra/scripts/add-secret-version.sh \
  robur-prod-123456 robur-healthkit-ingest-token
```

GKE mounts this Secret Manager value into only the API pod. The API workload
identity has `roles/secretmanager.secretAccessor` on this one secret. It is not
a GitHub secret and must never be put in an iOS or watchOS build: a static token
inside a client application can be extracted.

The current Apple client reads HealthKit only on device and does not upload
HealthKit data yet. Before enabling the real `/api/healthkit/sync` flow for
users, replace this temporary shared-token design with per-user authentication
(for example, Sign in with Apple plus server-issued sessions/tokens), ownership
checks, rate limiting, and audit logging. Apple HealthKit itself uses on-device
user consent; it does not require a Google OAuth client ID, Google API key,
Firebase configuration, or Google service-account credential.

## DNS, deployment, and verification

1. Manually dispatch `Terraform Infrastructure Deployment` from GitHub with
   `apply_production` set to `true` once the production variables and protection
   rules are ready.
2. Manually dispatch `Build and Deploy to GKE` with `deploy_production` set to
   `true`.
3. Retrieve the ingress address:

   ```bash
   gcloud container clusters get-credentials robur-cluster \
     --region europe-west2 --project robur-prod-123456
   kubectl -n robur get ingress robur
   ```

4. Create an `A`/`AAAA` record for `robur.fit` at the DNS provider. Wait for
   `robur-web-cert` to become `Active`, then verify `/healthz` and `/readyz`.

The DNS record is the last expected manual infrastructure action. All Robur
GCP resources, APIs, identities, and runtime wiring are declared in code.

## Secret inventory

The Google deployment itself needs no GitHub secret or service-account JSON key.
The one Robur runtime secret is the Secret Manager value above. The following
Apple delivery credentials are separate from Google Cloud and remain GitHub
`production` secrets because the existing TestFlight workflow consumes them:

- `MATCH_PASSWORD`
- `APP_STORE_CONNECT_API_KEY_ID`
- `APP_STORE_CONNECT_API_ISSUER_ID`
- `APP_STORE_CONNECT_API_KEY` (base64-encoded `.p8` file)

Do not add an APNs key until server-side push delivery is implemented. The
current iOS MVP neither registers device tokens nor sends APNs pushes.
