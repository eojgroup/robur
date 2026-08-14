# Robur Admin Manual Tasks

These tasks require administrator access and cannot be completed safely from code alone.

## 1. GitHub Repository

Create a `production` environment in `eojgroup/robur`.

Add repository variables:

```text
GCP_PROJECT_ID=<google-cloud-project-id>
GCP_REGION=europe-west2
GCP_ZONE=europe-west2-b
GCP_WORKLOAD_IDENTITY_PROVIDER=<terraform output workload_identity_provider>
GCP_TERRAFORM_SERVICE_ACCOUNT=<terraform output github_deploy_service_account>
GKE_CLUSTER=robur-cluster
WEB_DOMAIN_NAME=app.robur.app
APPLE_TEAM_ID=<apple developer team id>
APPLE_ID=<apple developer account email>
APP_STORE_CONNECT_TEAM_ID=<app store connect team id>
MATCH_GIT_URL=<private fastlane match certificates repo>
```

Add repository secrets:

```text
HEALTHKIT_INGEST_TOKEN=<admin-generated random token>
MATCH_PASSWORD=<fastlane match encryption password>
APP_STORE_CONNECT_API_KEY_ID=<app store connect api key id>
APP_STORE_CONNECT_API_ISSUER_ID=<app store connect issuer id>
APP_STORE_CONNECT_API_KEY=<base64 encoded .p8 key contents>
```

Recommended repository controls:

- Require pull requests before merging to `main`.
- Require `Robur CI` before merge.
- Require approval for the `production` environment.
- Limit who can edit repository variables and secrets.

## 2. Google Cloud

Create or choose the production Google Cloud project.

Before Terraform can use the GCS backend, an admin must bootstrap state once:

```bash
gcloud services enable storage.googleapis.com --project <project-id>
gcloud storage buckets create gs://robur-tf-state --project <project-id> --location europe-west2
gcloud storage buckets update gs://robur-tf-state --versioning
```

Create the initial GitHub OIDC bootstrap identity or run the first Terraform apply locally with owner credentials. After Terraform creates `workload_identity_provider` and `github_deploy_service_account`, store those outputs as GitHub variables.

Run first infrastructure apply:

```bash
cd infra/gcp/terraform
cp terraform.tfvars.example terraform.tfvars
terraform init
terraform plan
terraform apply
```

Copy these outputs to GitHub variables:

```text
workload_identity_provider -> GCP_WORKLOAD_IDENTITY_PROVIDER
github_deploy_service_account -> GCP_TERRAFORM_SERVICE_ACCOUNT
gke_cluster_name -> GKE_CLUSTER
```

## 3. DNS And GKE Ingress

For `app.robur.app`:

1. Create or identify the managed DNS zone.
2. Run `Terraform Infrastructure Deployment`.
3. Run `Build and Deploy to GKE`.
4. Get the GKE ingress IP:

```bash
kubectl -n robur get ingress robur
```

5. Create an `A` record for `app.robur.app` pointing to that IP.
6. Wait for the GKE managed certificate `robur-web-cert` to become active.

## 4. Apple Developer And HealthKit

In Apple Developer, create these identifiers:

```text
com.eojgroup.robur
com.eojgroup.robur.watchkitapp
```

Enable capabilities:

```text
HealthKit
App Groups, only if future iPhone/watch shared storage requires it
Push Notifications, only when notifications are implemented
```

Create the App Store Connect app:

```text
Name: Robur
SKU: robur-ios
Primary bundle ID: com.eojgroup.robur
Platforms: iOS
```

HealthKit review preparation:

- Write clear App Store copy explaining why Robur reads workouts, sleep, resting heart rate, HRV, running distance, and cycling distance.
- Keep HealthKit data on device unless the user explicitly syncs it.
- Do not use HealthKit data for advertising or sell it.
- Provide a privacy policy that names every HealthKit data category used.

## 5. Apple Code Signing

Create a private certificates repository for Fastlane match, for example:

```text
git@github.com:eojgroup/robur-apple-certificates.git
```

From a trusted Mac with Apple admin access:

```bash
cd apps/mobile/ios
bundle install
MATCH_GIT_URL=git@github.com:eojgroup/robur-apple-certificates.git \
MATCH_PASSWORD=<new-password> \
APPLE_TEAM_ID=<team-id> \
bundle exec fastlane match appstore \
  --app_identifier com.eojgroup.robur,com.eojgroup.robur.watchkitapp
```

Add `MATCH_GIT_URL` as a GitHub variable and `MATCH_PASSWORD` as a GitHub secret.

Make sure the GitHub Actions runner can read the match repository. Use a deploy key or machine user with read access.

## 6. App Store Connect API Key

Create an App Store Connect API key with access to app management. Base64 encode the `.p8` file:

```bash
base64 -i AuthKey_<KEY_ID>.p8 | pbcopy
```

Store:

```text
APP_STORE_CONNECT_API_KEY_ID
APP_STORE_CONNECT_API_ISSUER_ID
APP_STORE_CONNECT_API_KEY
```

## 7. App Store Review Metadata

Before external TestFlight or App Store review, an admin must complete:

- Final production app icon and screenshots.
- Privacy policy URL.
- Health data collection and use disclosures.
- App privacy nutrition labels.
- Export compliance answers.
- Age rating.
- Test account details if authenticated areas are added.
- Support URL and marketing URL.

The current icons are valid placeholders for initial builds, not final brand artwork.

## 8. First Deployment Sequence

Run local validation:

```bash
pnpm install
pnpm typecheck
pnpm test
pnpm build
```

Generate placeholder icons if needed:

```bash
pnpm generate:icons
```

Apply infrastructure:

```bash
cd infra/gcp/terraform
terraform init
terraform apply
```

Deploy runtime:

1. Confirm GitHub variables/secrets are populated.
2. Run `Terraform Infrastructure Deployment`.
3. Run `Build and Deploy to GKE`.
4. Open `https://app.robur.app` after DNS and certificate provisioning finish.

Deploy Apple:

1. Confirm Apple identifiers, HealthKit capability, App Store Connect app, API key, and match signing are ready.
2. Run `Build Apple clients`.
3. Confirm the build appears in TestFlight.

## 9. Current Environment Limits

This Codespace validated Node, TypeScript, tests, and web/API builds. It cannot locally run Terraform, XcodeGen, Xcode, Fastlane, or GKE deploys because those tools or cloud credentials are not installed here. GitHub Actions are prepared to run those checks on the proper runners once admin credentials are configured.
