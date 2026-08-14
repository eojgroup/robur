# Robur static web hosting onboarding

Robur’s first public web deployment is deliberately static. The dashboard is a
React build containing mock Apple Health data; it makes no browser API calls and
does not need a database, container registry, Cloud Run, GKE, Cloud SQL, load
balancer, Google OAuth client, Firebase web config, or service-account key.

The production footprint is Firebase Hosting on the existing GCP project:

```text
Project: robur-505508
Region for project operations: europe-west2
Firebase Hosting site: robur-505508
Temporary public URL: https://robur-505508.web.app
Custom domain: robur.fit
```

Firebase Hosting provides the CDN and TLS certificate. Its default `web.app`
URL is usable before DNS is complete. The deferred GKE/Cloud SQL workflows are
hard-gated by the protected `ENABLE_FUTURE_BACKEND` environment variable and
must remain unset for this static-only milestone.

## Cost boundary

The Terraform root at `infra/gcp/hosting` creates only:

- Firebase added to this project and one Hosting site;
- a GitHub OIDC workload-identity pool/provider and a narrow Hosting deployer
  service account; and
- optionally, a project-scoped billing-budget alert.

It does **not** create a VM, GKE cluster, Cloud SQL instance, container image,
load balancer, NAT gateway, or background worker. The Terraform state bucket
retains current history but deletes archived versions after 90 days. Production
web builds do not publish source maps and no longer ship the former 2 MB photo.

A budget is an alert, not a hard cap. Firebase/Google charges and budget alerts
can lag, so keep the expensive future-backend guardrail in place even when an
alert exists.

## What must be done manually

These choices affect external accounts or ownership and should not be guessed
by automation:

1. Confirm the correct billing-account owner can receive budget alerts. The
   project is already linked to an active billing account, but project Owner
   alone may not grant Billing Account Costs Manager/Budget Manager permission.
2. Add any required reviewers to GitHub’s `production` environment. The setup
   script can safely enforce `main` as the deployment branch, but it cannot
   choose people who should approve production deployments.
3. At the DNS registrar for `robur.fit`, add the exact records emitted by
   Firebase after Terraform creates the custom-domain request. Do not substitute
   guessed A/TXT records: Firebase can require both ownership verification and
   serving records, and they may change.

No Google or Firebase secret belongs in GitHub for this deployment. GitHub
Actions exchanges its short-lived OIDC token for the restricted service account.
Do not create a JSON key, set `FIREBASE_TOKEN`, or put the supplied OAuth
authorization codes in a repository secret.

## One-time infrastructure apply

Install Google Cloud CLI, Terraform 1.8+, and GitHub CLI. Authenticate with a
project administrator; Application Default Credentials are required by the
Google Terraform provider:

```bash
gcloud auth login
gcloud auth application-default login
gh auth login
```

The state bucket already exists. Create the ignored local variables file from
the example and keep the billing budget blank on the first Hosting apply if
you have not verified billing-account IAM:

```bash
cp infra/gcp/hosting/terraform.tfvars.example infra/gcp/hosting/terraform.tfvars
```

Set the file to these non-secret values:

```hcl
project_id        = "robur-505508"
region            = "europe-west2"
hosting_site_id   = "robur-505508"
domain_name       = "robur.fit"
github_repository = "eojgroup/robur"
github_branch     = "main"

# Leave blank if Billing Budget IAM has not been granted yet.
billing_account_id = ""
```

Then apply the small Hosting root, using the existing state bucket:

```bash
export TF_STATE_BUCKET="robur-tf-state-robur-505508"
./infra/scripts/terraform-init-retry.sh infra/gcp/hosting
terraform -chdir=infra/gcp/hosting plan
terraform -chdir=infra/gcp/hosting apply
```

Adding Firebase to a GCP project is irreversible. Terraform uses
`prevent_destroy` for the Firebase association and `ABANDON` deletion policies
for Hosting resources rather than trying to remove them on a future destroy.

If Billing Budget IAM is available, set the actual billing-account ID and apply
again. The default alert threshold is 100 SEK/month, with alerts at 50%, 80%,
100%, and forecasted 100%:

```hcl
billing_account_id   = "<billing-account-id-with-budget-access>"
budget_currency      = "SEK"
monthly_budget_units = 100
```

## Configure GitHub deployment without secrets

After the Hosting apply, run the repository helper. It reads Terraform outputs,
creates/updates the `production` environment, restricts deployments to `main`,
and writes only non-secret environment variables.

```bash
./infra/scripts/configure-github-hosting.sh \
  --project-id robur-505508 \
  --state-bucket robur-tf-state-robur-505508 \
  --repository eojgroup/robur
```

It sets:

| Variable | Purpose |
| --- | --- |
| `GCP_PROJECT_ID` | Hosting project ID |
| `GCP_REGION`, `GCP_TF_STATE_BUCKET` | Terraform/project context |
| `GCP_HOSTING_WORKLOAD_IDENTITY_PROVIDER` | GitHub OIDC provider path |
| `GCP_HOSTING_DEPLOY_SERVICE_ACCOUNT` | Narrow Hosting deployer identity |
| `FIREBASE_HOSTING_SITE`, `FIREBASE_HOSTING_URL` | Hosting deployment and health-check target |
| `WEB_DOMAIN_NAME` | Intended custom domain |

The workflow has no cloud credential in GitHub secrets. Its service account has
only `roles/firebasehosting.admin`, the Firebase CLI’s read-only
`roles/serviceusage.apiKeysViewer`, and
`roles/serviceusage.serviceUsageConsumer`; it cannot administer the project or
provision the deferred backend.

## First public release and DNS

1. From `main`, manually run the **Deploy web mock-up** GitHub Actions workflow
   and explicitly set `deploy_web` to true. It builds the web app from the
   locked dependencies, uses OIDC, publishes Firebase Hosting, and checks the
   default public URL for Robur’s HTML title.
2. Open the default URL from Terraform output or the GitHub environment:

   ```bash
   terraform -chdir=infra/gcp/hosting output -raw default_url
   ```

3. Get the registrar records produced by Firebase:

   ```bash
   terraform -chdir=infra/gcp/hosting output -json custom_domain_dns_updates
   terraform -chdir=infra/gcp/hosting output -raw custom_domain_ownership_state
   terraform -chdir=infra/gcp/hosting output -raw custom_domain_host_state
   ```

4. Create those exact records at the `robur.fit` registrar. Wait for DNS
   propagation and for the Terraform state values to advance to verified/active.
   Firebase provisions TLS automatically; do not create a separate load
   balancer or certificate.
5. Open `https://robur.fit` and confirm the dashboard loads over HTTPS.

## Future backend boundary

The existing GKE/Cloud SQL Terraform and workflows are kept for a separately
reviewed product phase. They are intentionally unavailable unless an
administrator adds `ENABLE_FUTURE_BACKEND=true` to the protected `production`
environment *and* manually supplies the existing boolean workflow input. That
second architecture review must cover user authentication, HealthKit data
minimization, retention/deletion, API rate limiting, database backups, and a
revised cost budget before any backend resource is created.
