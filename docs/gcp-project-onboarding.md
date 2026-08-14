# Robur GKE and Cloud SQL onboarding

This document is the production onboarding path for the web/API release in
GCP project `robur-505508`.

```text
Region:                 europe-west2
Single workload zone:   europe-west2-b
Public domain:          robur.fit
Terraform state bucket: robur-tf-state-robur-505508
GitHub repository:      eojgroup/robur
Deployment branch:      main
```

The first main Terraform apply is intentionally billable: it provisions a
regional GKE cluster, one preemptible workload node, private networking, Cloud
SQL, Artifact Registry, Secret Manager, Pub/Sub, and GitHub OIDC. The first
GKE application deployment also creates an external Ingress/load balancer.
Read the [cost boundary](#cost-boundary) before applying.

## Manual prerequisites and decisions

The following cannot safely be chosen by repository automation:

1. A GCP/billing administrator must confirm the existing billing account is
   linked to `robur-505508`, approve the first billable apply, and create the
   Cloud Billing budget alert. A project role alone may not grant billing-budget
   access; the alert is not a hard cap.
2. A GitHub repository administrator must select the human reviewers for the
   `production` environment and restrict deployments to `main`. The helper can
   create the environment and set its variables, but it deliberately does not
   choose reviewers or branch-protection policy.
3. The DNS owner for `robur.fit` must approve replacing its existing root
   record. The domain may currently route to a separate site; this is a visible
   production cutover, not a record that should be added alongside an old A
   record.
4. The old unverified Firebase custom-domain mapping and its dedicated GitHub
   deploy identity have already been removed. The Firebase project
   association/default site itself is irreversible and remains dormant; it is
   not an active Robur deployment and has no repository workflow or resource.

Install Google Cloud CLI, Terraform 1.8+, and GitHub CLI, then authenticate a
trusted administrator locally:

```bash
gcloud auth login
gcloud auth application-default login
gh auth login
```

Never create a Google service-account JSON key for GitHub Actions. Production
workflows exchange GitHub OIDC tokens for a short-lived Google identity.

## Bootstrap and Terraform configuration

The project and the state bucket named above already exist. Do not rerun the
bootstrap script just to recreate an existing bucket that is not in the local
bootstrap state: a fresh bootstrap state would attempt to create the bucket
again. Verify the bucket and use it as the Terraform backend:

```bash
gcloud storage buckets describe gs://robur-tf-state-robur-505508
export TF_STATE_BUCKET="robur-tf-state-robur-505508"
./infra/scripts/terraform-init-retry.sh infra/gcp/terraform
```

For a genuinely new project or a recovered bootstrap state, the repeatable
bootstrap command is:

```bash
./infra/scripts/bootstrap-gcp.sh \
  --project-id robur-505508 \
  --billing-account <existing-billing-account-id> \
  --region europe-west2 \
  --state-bucket robur-tf-state-robur-505508
```

Create the ignored non-secret variables file and set the approved deployment
values:

```bash
cp infra/gcp/terraform/terraform.tfvars.example \
  infra/gcp/terraform/terraform.tfvars
```

```hcl
project_id        = "robur-505508"
region            = "europe-west2"
zone              = "europe-west2-b"
environment       = "prod"
github_repository = "eojgroup/robur"
github_branch     = "main"
k8s_namespace     = "robur"
domain_name       = "robur.fit"
cloud_sql_tier    = "db-custom-1-3840"
```

The only unavoidable local bootstrap is the keyless GitHub identity: a workflow
cannot create the identity that it needs in order to authenticate. Use the
reviewed Terraform configuration from an administrator workstation to apply
only the OIDC pool/provider, deploy service account, and its declared roles:

```bash
terraform -chdir=infra/gcp/terraform fmt -check -recursive
terraform -chdir=infra/gcp/terraform validate
terraform -chdir=infra/gcp/terraform plan \
  -target=google_iam_workload_identity_pool_provider.github \
  -target=google_service_account_iam_binding.github_deploy_workload_identity_user \
  -target=google_project_iam_member.github_deploy_roles \
  -out=identity-bootstrap.tfplan
terraform -chdir=infra/gcp/terraform apply identity-bootstrap.tfplan
```

Terraform targeting is used only to break this initial authentication cycle;
normal operations must use a complete plan. In this project the identity
bootstrap and GitHub variable configuration are already complete. Do not
commit `terraform.tfvars` or any plan file.

## Configure GitHub production

After the targeted identity bootstrap and before the first full apply, run the
repository helper. It reads the identity outputs and writes only non-secret
`production` environment variables:

```bash
./infra/scripts/configure-github-production.sh \
  --project-id robur-505508 \
  --state-bucket robur-tf-state-robur-505508 \
  --domain robur.fit \
  --repository eojgroup/robur
```

It sets the following variables:

| Variable | Purpose |
| --- | --- |
| `GCP_PROJECT_ID` | GCP project used by the deployment. |
| `GCP_REGION`, `GCP_ZONE` | GKE/Artifact Registry region and the single node-pool zone. |
| `GCP_TF_STATE_BUCKET` | Terraform remote-state bucket. |
| `GCP_WORKLOAD_IDENTITY_PROVIDER` | GitHub OIDC provider resource name. |
| `GCP_TERRAFORM_SERVICE_ACCOUNT` | Keyless Google deployment identity. |
| `GKE_CLUSTER` | GKE cluster name. |
| `WEB_DOMAIN_NAME` | `robur.fit`, used by the Ingress and certificate. |

Then, in GitHub **Settings → Environments → production**, manually choose
required reviewers and set the deployment branch policy to `main`. A merge to
`main` that changes `infra/gcp/terraform` runs Terraform plan/apply, so protect
that branch and review infrastructure pull requests accordingly.

## Seed the runtime HealthKit-ingest secret

Terraform creates the Secret Manager container
`robur-healthkit-ingest-token`. Before the first workload deployment, provide
an enabled value either directly or through the protected workflow secret. The
direct path keeps the value out of GitHub:

```bash
openssl rand -base64 48 | ./infra/scripts/add-secret-version.sh \
  robur-505508 robur-healthkit-ingest-token
```

The deployed API reads that value through workload identity and the GKE Secret
Manager CSI driver. It is not an Apple HealthKit credential and must not be put
in an iOS/Watch app or browser build.

The Terraform workflow also accepts the protected `production` GitHub secret
`HEALTHKIT_INGEST_TOKEN` and reconciles it into Secret Manager. Robur currently
uses that workflow-driven path. The workflow preserves an existing matching
version and stops if neither a GitHub value nor an enabled Secret Manager
version exists.

## First release and DNS handoff

1. From `main`, manually run **Terraform Infrastructure Deployment** with
   `apply_production=true`. This reconciles the initial cloud state and creates
   the runtime Kubernetes configuration without a Google key.
2. From `main`, manually run **Build and Deploy to GKE** with
   `deploy_production=true`. It validates the repository, builds/pushes the web
   and API images, runs migrations, deploys workloads, creates the managed
   certificate and Ingress, and writes the allocated ingress IP to the Actions
   summary.
3. Inspect the Ingress after it has an IP. The GKE workflow waits for it, but
   allocation can take longer than a run:

   ```bash
   gcloud container clusters get-credentials robur-cluster \
     --region europe-west2 \
     --project robur-505508
   kubectl -n robur get ingress robur
   kubectl -n robur describe managedcertificate robur-web-cert
   ```

4. At the registrar, replace the root `A` record for `robur.fit` with the
   exact Ingress IP from the summary or `kubectl` output. Preserve MX, TXT,
   mail, and unrelated subdomain records. Do not add Firebase verification or
   serving records, and remove stale Firebase-specific records only after
   confirming they are not used by another service.
5. Wait for public DNS and the managed certificate to become active, then
   verify the actual domain:

   ```bash
   dig +short A robur.fit
   kubectl -n robur describe managedcertificate robur-web-cert
   curl --fail --location https://robur.fit/
   ```

Google-managed TLS activates after DNS points at the Ingress. If the Ingress is
ever deleted and recreated, obtain its new IP and repeat the DNS handoff rather
than assuming the previous address remains valid.

## Cost boundary

The low-cost design choices are deliberate:

- the regional GKE control plane has a single `e2-small` preemptible node in
  `europe-west2-b`, rather than a three-zone workload node pool;
- API and web deployments each start with one small replica;
- Artifact Registry retains five recent images and deletes images older than
  14 days; and
- Pub/Sub retains messages for one day.

The non-zero baseline remains material: Cloud SQL is an always-on
`db-custom-1-3840` instance with backups/PITR, and GKE Ingress creates an
external Application Load Balancer. A preemptible single-zone node can be lost
at any time. Budget alerts provide notification only; they cannot prevent
overage or automatically destroy protected resources. Any pause or teardown of
GKE/Cloud SQL requires a reviewed operational plan because deletion protection
is enabled.
