#!/usr/bin/env bash

set -euo pipefail

usage() {
  cat <<'EOF'
Usage: configure-github-production.sh --project-id PROJECT_ID --state-bucket BUCKET --domain DOMAIN [options]

Creates the GitHub production environment when absent and writes the non-secret
Google Cloud Actions variables from the current Terraform outputs. Configure
environment reviewers and deployment branch protection in GitHub afterwards.

Options:
  --project-id ID          Required Google Cloud project ID.
  --state-bucket NAME      Required Terraform state bucket name.
  --domain DOMAIN          Required public web domain.
  --region REGION          GKE/Artifact Registry region (default: europe-west2).
  --zone ZONE              Default compute zone (default: europe-west2-b).
  --repository OWNER/REPO  GitHub repository (default: current repository).
  --help                   Show this help.

Run this after the one-time keyless GitHub identity bootstrap and before the
first workflow-driven Terraform apply. It requires an authenticated GitHub CLI
user with repository administration permissions.
EOF
}

project_id=""
state_bucket=""
domain=""
region="europe-west2"
zone="europe-west2-b"
repository=""

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
    --domain)
      domain="${2:?--domain requires a value}"
      shift 2
      ;;
    --region)
      region="${2:?--region requires a value}"
      shift 2
      ;;
    --zone)
      zone="${2:?--zone requires a value}"
      shift 2
      ;;
    --repository)
      repository="${2:?--repository requires a value}"
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

if [[ -z "$project_id" || -z "$state_bucket" || -z "$domain" ]]; then
  usage >&2
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

gh auth status >/dev/null

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
terraform_dir="$(cd "$script_dir/../gcp/terraform" && pwd)"

TF_STATE_BUCKET="$state_bucket" "$script_dir/terraform-init-retry.sh" "$terraform_dir"

workload_identity_provider="$(terraform -chdir="$terraform_dir" output -raw workload_identity_provider)"
terraform_service_account="$(terraform -chdir="$terraform_dir" output -raw github_deploy_service_account)"
# The keyless GitHub identity is bootstrapped before the first billable apply,
# so the cluster output may not exist yet. The cluster name is intentionally
# stable in the Terraform configuration and is reconciled on every later run.
cluster_name="$(terraform -chdir="$terraform_dir" output -raw gke_cluster_name 2>/dev/null || true)"
cluster_name="${cluster_name:-robur-cluster}"

# This only creates the environment. Reviewer and branch-protection policy are
# organization decisions and must be configured in GitHub by an administrator.
gh api --method PUT "repos/$repository/environments/production" >/dev/null

set_variable() {
  gh variable set "$1" --repo "$repository" --env production --body "$2"
}

set_variable GCP_PROJECT_ID "$project_id"
set_variable GCP_REGION "$region"
set_variable GCP_ZONE "$zone"
set_variable GCP_TF_STATE_BUCKET "$state_bucket"
set_variable GCP_WORKLOAD_IDENTITY_PROVIDER "$workload_identity_provider"
set_variable GCP_TERRAFORM_SERVICE_ACCOUNT "$terraform_service_account"
set_variable GKE_CLUSTER "$cluster_name"
set_variable WEB_DOMAIN_NAME "$domain"

echo "Configured Google Cloud production variables for $repository."
