#!/usr/bin/env bash

set -euo pipefail

usage() {
  cat <<'EOF'
Usage: configure-github-hosting.sh --project-id PROJECT_ID --state-bucket BUCKET [options]

Reads the static Firebase Hosting Terraform outputs and configures only the
non-secret GitHub production-environment variables used by web-hosting-deploy.
It also limits the production environment to the main branch. No service-account
key, Firebase token, or GitHub secret is created.

Options:
  --project-id ID          Required Google Cloud project ID.
  --state-bucket NAME      Required Terraform state bucket name.
  --repository OWNER/REPO  GitHub repository (default: current repository).
  --region REGION          Project region (default: europe-west2).
  --help                   Show this help.

Run after applying infra/gcp/hosting. It requires an authenticated GitHub CLI
principal with repository-administration permission.
EOF
}

project_id=""
state_bucket=""
repository=""
region="europe-west2"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --project-id)
      project_id="${2:?--project-id requires a value}"
      shift 2
      ;;
    --state-bucket)
      state_bucket="${2:?--state-bucket requires a value}"
      shift 2
      ;;
    --repository)
      repository="${2:?--repository requires a value}"
      shift 2
      ;;
    --region)
      region="${2:?--region requires a value}"
      shift 2
      ;;
    --help)
      usage
      exit 0
      ;;
    *)
      echo "Unknown option: $1" >&2
      usage >&2
      exit 1
      ;;
  esac
done

if [[ -z "$project_id" || -z "$state_bucket" ]]; then
  usage >&2
  exit 1
fi

if [[ ! "$project_id" =~ ^[a-z][a-z0-9-]{4,28}[a-z0-9]$ ]]; then
  echo "--project-id must be a Google Cloud project ID." >&2
  exit 1
fi

for command in gh terraform; do
  if ! command -v "$command" >/dev/null 2>&1; then
    echo "Required command is not installed: $command" >&2
    exit 1
  fi
done

if [[ -z "$repository" ]]; then
  repository="$(gh repo view --json nameWithOwner --jq .nameWithOwner)"
fi

if [[ ! "$repository" =~ ^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$ ]]; then
  echo "--repository must be in OWNER/REPOSITORY form." >&2
  exit 1
fi

gh auth status >/dev/null

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
terraform_dir="$(cd "$script_dir/../gcp/hosting" && pwd)"

TF_STATE_BUCKET="$state_bucket" "$script_dir/terraform-init-retry.sh" "$terraform_dir"

workload_identity_provider="$(terraform -chdir="$terraform_dir" output -raw workload_identity_provider)"
deploy_service_account="$(terraform -chdir="$terraform_dir" output -raw github_deploy_service_account)"
hosting_site="$(terraform -chdir="$terraform_dir" output -raw hosting_site_id)"
hosting_url="$(terraform -chdir="$terraform_dir" output -raw default_url)"

if [[ "$hosting_url" != https://*.web.app ]]; then
  echo "Terraform returned an unexpected Firebase Hosting URL: $hosting_url" >&2
  exit 1
fi

# Create or update only the branch rule. Reviewer and self-review policy are an
# organization approval decision; GitHub rejects self-review protection without a reviewer.
gh api --method PUT "repos/$repository/environments/production" --input - >/dev/null <<'JSON'
{"deployment_branch_policy":{"protected_branches":false,"custom_branch_policies":true}}
JSON

existing_policy_names="$(gh api "repos/$repository/environments/production/deployment-branch-policies" --paginate --jq '.[].name' || true)"
while IFS= read -r policy_name; do
  [[ -z "$policy_name" ]] && continue
  if [[ "$policy_name" != "main" ]]; then
    echo "Refusing to alter existing production deployment policy '$policy_name'. Review it manually." >&2
    exit 1
  fi
done <<< "$existing_policy_names"

if ! grep -qx "main" <<< "$existing_policy_names"; then
  gh api --method POST "repos/$repository/environments/production/deployment-branch-policies" \
    -f name=main \
    -f type=branch >/dev/null
fi

set_variable() {
  gh variable set "$1" --repo "$repository" --env production --body "$2"
}

set_variable GCP_PROJECT_ID "$project_id"
set_variable GCP_REGION "$region"
set_variable GCP_TF_STATE_BUCKET "$state_bucket"
set_variable GCP_HOSTING_WORKLOAD_IDENTITY_PROVIDER "$workload_identity_provider"
set_variable GCP_HOSTING_DEPLOY_SERVICE_ACCOUNT "$deploy_service_account"
set_variable FIREBASE_HOSTING_SITE "$hosting_site"
set_variable FIREBASE_HOSTING_URL "$hosting_url"
set_variable WEB_DOMAIN_NAME "robur.fit"

cat <<EOF
Configured static Hosting production variables for $repository.

Default URL: $hosting_url
Branch policy: main only

The production environment still has no reviewers configured. Add reviewers in
GitHub if your organization requires a human approval gate before deployment.
EOF
