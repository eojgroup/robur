# Robur administrator manual tasks

Automation owns repeatable infrastructure, deployment wiring, and CI checks.
The following remain manual because they select external account owners,
approval policy, DNS ownership, or Apple credentials. The full GCP command
sequence is in [GCP project onboarding](gcp-project-onboarding.md).

## Before the first GCP apply

1. A billing-account administrator must confirm billing for `robur-505508` and
   approve the initial billable footprint: regional GKE, one preemptible node,
   zonal always-on Cloud SQL, Artifact Registry, and an external load balancer
   once Ingress is deployed.
2. The same administrator should create a Cloud Billing budget and select alert
   recipients. A budget is a notification mechanism, not a hard spending cap,
   and it may lag actual usage.
3. A repository administrator must select human reviewers for GitHub's
   `production` environment and restrict deployments to `main`. Do not rely on
   the setup script to choose approvers or branch policy.
4. The DNS owner must approve a cutover of `robur.fit`. Its existing root DNS
   may point at another live site, so replacing it is an external change rather
   than a harmless additional record.

## GitHub production configuration

After the trusted keyless-identity bootstrap and before the first full
workflow apply, run:

```bash
./infra/scripts/configure-github-production.sh \
  --project-id robur-505508 \
  --state-bucket robur-tf-state-robur-505508 \
  --domain robur.fit \
  --repository eojgroup/robur
```

The helper writes these non-secret `production` environment variables:

| Variable | Required by |
| --- | --- |
| `GCP_PROJECT_ID` | Terraform and GKE deployment. |
| `GCP_REGION`, `GCP_ZONE` | Terraform and GKE deployment. |
| `GCP_TF_STATE_BUCKET` | Terraform deployment. |
| `GCP_WORKLOAD_IDENTITY_PROVIDER` | Keyless Google authentication. |
| `GCP_TERRAFORM_SERVICE_ACCOUNT` | Terraform, image publishing, and GKE deployment. |
| `GKE_CLUSTER` | GKE application deployment. |
| `WEB_DOMAIN_NAME` | Ingress and managed certificate. |

No Google service-account JSON key, Firebase token, Google OAuth client secret,
or Firebase configuration belongs in GitHub. The workflows use GitHub OIDC.

### Runtime secret

Before the API is deployed, seed Secret Manager directly:

```bash
openssl rand -base64 48 | ./infra/scripts/add-secret-version.sh \
  robur-505508 robur-healthkit-ingest-token
```

Alternatively, set the protected `production` GitHub secret
`HEALTHKIT_INGEST_TOKEN`; the Terraform workflow reconciles it without logging
the value. Robur currently uses this workflow-driven path. If the secret is
later removed, the workflow keeps the already enabled Secret Manager version.
Never place this value in an Apple client, browser build, source file, or
command line.

## DNS and legacy Firebase cleanup

1. The unverified Firebase `robur.fit` mapping and dedicated deploy identity
   have already been removed. The Firebase project association/default site
   cannot be undone, but it is dormant and no repository workflow deploys to it.
2. Run the first successful GKE deploy and obtain the Ingress IP from its
   Actions summary or:

   ```bash
   kubectl -n robur get ingress robur
   ```

3. At the DNS registrar, replace—not supplement—the root `A` record for
   `robur.fit` with that exact IP. Preserve unrelated MX, TXT, and subdomain
   records. Do not add Firebase DNS records.
4. Wait for DNS propagation and for `robur-web-cert` to report active, then
   check `https://robur.fit`. If the Ingress is later recreated, repeat this
   handoff with its newly allocated IP.

## Apple Developer and HealthKit

First complete [Apple HealthKit device validation](apple-healthkit-device-test.md)
on a real iPhone and, when testing Watch data, a paired Apple Watch. The
confirmed identifiers are:

```text
Apple Developer Team ID: VTBJTFDTQY
iPhone/iPad App ID:     com.eojgroup.robur
Watch companion App ID: com.eojgroup.robur.watchkitapp
```

In Apple Developer, create or confirm the two explicit App IDs and enable
**HealthKit** for each. Use Xcode automatic signing for device testing and
regenerate provisioning profiles after capability changes. Do not enable App
Groups, Push Notifications, or HealthKit Background Delivery for the current
local-read MVP.

When the device test passes, confirm the existing App Store Connect iOS app:

```text
Name: Robur Health
Apple ID: 6801487531
Primary bundle ID: com.eojgroup.robur
Platform: iOS
```

The watch app is embedded in that iOS product; do not create a second App Store
Connect product for it.

### TestFlight delivery, only when approved

TestFlight uses direct signing in GitHub Actions. It does not use Fastlane,
Match, a certificate repository, an Apple ID password, or a downloaded
provisioning-profile secret.

Before manually dispatching **Build Apple clients** with
`distribute_to_testflight=true` on `main`:

1. In App Store Connect, have an Account Holder enable API access. An Account
   Holder or Admin must create a **Team** API key that can provision profiles
   and upload builds. Do not use an Individual key: the workflow creates or
   reuses the two App Store provisioning profiles through the provisioning API.
2. Export one active **Apple Distribution** certificate and its private key as
   a password-protected `.p12` file. It must belong to Team `VTBJTFDTQY` and
   remain active in Apple Developer.
3. Create one internal TestFlight group, such as `Robur Test Group`. Its exact
   name is required because the workflow waits for processing and assigns the
   uploaded build to that group.
4. Add the following configuration to GitHub's protected `production`
   environment:

| Type | Name | Value / purpose |
| --- | --- | --- |
| Variable | `APPLE_TEAM_ID` | `VTBJTFDTQY` |
| Variable | `APP_STORE_CONNECT_APP_ID` | `6801487531` for Robur Health |
| Variable | `TESTFLIGHT_GROUP_NAME` | Exact pre-created internal beta-group name |
| Secret | `APP_STORE_CONNECT_KEY_ID` | Team API key ID |
| Secret | `APP_STORE_CONNECT_ISSUER_ID` | Team API key issuer ID |
| Secret | `APP_STORE_CONNECT_PRIVATE_KEY_P8` | Literal `.p8` file contents; do not base64 encode it |
| Secret | `APPLE_DISTRIBUTION_CERTIFICATE_P12` | Base64-encoded password-protected `.p12` |
| Secret | `APPLE_DISTRIBUTION_CERTIFICATE_PASSWORD` | Password used for that `.p12` |

On a trusted Mac, copy the P12 in the format required by GitHub Secrets:

```bash
base64 -i RoburDistribution.p12 | pbcopy
```

The workflow imports the certificate into an isolated temporary keychain,
creates or renews only the two matching App Store profiles, archives and exports
the IPA, uploads it, then removes signing material. It derives a unique build
number from the GitHub workflow run, so repeated TestFlight uploads do not
collide with the local version number.

Before external TestFlight or App Store review, complete the privacy policy,
HealthKit purpose disclosures, App Privacy labels, export compliance, age
rating, screenshots, support URL, and review metadata. HealthKit data must not
be used for advertising or sale.

## CI Repair Agent oversight

The repair agent has no LLM service, third-party webhook, database, or added
secret. It runs as a repair-only job inside `terraform-deploy.yml`, creates only
a draft PR, and never auto-merges or applies Terraform in its repair path.
Administrators should review changes to `.github/ci-repair-agent.json` like
production automation code. Its trust boundary and recipe process are in
[CI Repair Agent](ci-repair-agent.md).
