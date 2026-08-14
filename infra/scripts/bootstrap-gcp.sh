#!/usr/bin/env bash

set -euo pipefail

usage() {
  cat <<'EOF'
Usage: bootstrap-gcp.sh --project-id PROJECT_ID --billing-account BILLING_ACCOUNT [options]

Creates the Google Cloud project when requested, links billing, creates the
versioned Terraform state bucket, and initializes the production Terraform backend.

Options:
  --project-id ID          Required Google Cloud project ID.
  --billing-account ID     Required Cloud Billing account ID.
  --region REGION          Bucket region (default: europe-west2).
  --state-bucket NAME      Globally unique state bucket name
                           (default: robur-tf-state-PROJECT_ID).
  --organization ID        Organization numeric ID, used only with --create-project.
  --folder ID              Folder numeric ID, used only with --create-project.
  --create-project         Create PROJECT_ID if it does not already exist.
  --help                   Show this help.

Authentication:
  Run `gcloud auth login` and `gcloud auth application-default login` first.
  The principal must be allowed to create/link the project and manage storage.
EOF
}

project_id=""
billing_account=""
region="europe-west2"
state_bucket=""
organization=""
folder=""
create_project=false

while [[ $# -gt 0 ]]; do
  case "$1" in
    --project-id)
      project_id="${2:?--project-id requires a value}"
      shift 2
      ;;
    --billing-account)
      billing_account="${2:?--billing-account requires a value}"
      shift 2
      ;;
    --region)
      region="${2:?--region requires a value}"
      shift 2
      ;;
    --state-bucket)
      state_bucket="${2:?--state-bucket requires a value}"
      shift 2
      ;;
    --organization)
      organization="${2:?--organization requires a value}"
      shift 2
      ;;
    --folder)
      folder="${2:?--folder requires a value}"
      shift 2
      ;;
    --create-project)
      create_project=true
      shift
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

if [[ -z "$project_id" || -z "$billing_account" ]]; then
  usage >&2
  exit 1
fi

if [[ -n "$organization" && -n "$folder" ]]; then
  echo "Use only one of --organization or --folder." >&2
  exit 1
fi

for command in gcloud terraform; do
  if ! command -v "$command" >/dev/null 2>&1; then
    echo "Required command is not installed: $command" >&2
    exit 1
  fi
done

if ! gcloud auth application-default print-access-token >/dev/null 2>&1; then
  echo "Application Default Credentials are required. Run: gcloud auth application-default login" >&2
  exit 1
fi

if ! gcloud projects describe "$project_id" >/dev/null 2>&1; then
  if [[ "$create_project" != true ]]; then
    echo "Project $project_id does not exist. Create it first, or rerun with --create-project." >&2
    exit 1
  fi

  create_args=(projects create "$project_id" --name="Robur production")
  if [[ -n "$organization" ]]; then
    create_args+=(--organization="$organization")
  fi
  if [[ -n "$folder" ]]; then
    create_args+=(--folder="$folder")
  fi
  gcloud "${create_args[@]}"
fi

linked_billing_account="$(gcloud billing projects describe "$project_id" --format='value(billingAccountName)' 2>/dev/null || true)"
linked_billing_account="${linked_billing_account#billingAccounts/}"

if [[ "$linked_billing_account" == "$billing_account" ]]; then
  echo "Billing is already linked to $billing_account; leaving it unchanged."
else
  gcloud billing projects link "$project_id" --billing-account="$billing_account"
fi
gcloud config set project "$project_id" >/dev/null
gcloud services enable cloudresourcemanager.googleapis.com serviceusage.googleapis.com --project="$project_id"

if [[ -z "$state_bucket" ]]; then
  state_bucket="robur-tf-state-${project_id}"
fi

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
infra_dir="$(cd "$script_dir/.." && pwd)"
bootstrap_dir="$infra_dir/gcp/bootstrap"
terraform_dir="$infra_dir/gcp/terraform"

terraform -chdir="$bootstrap_dir" init -input=false
terraform -chdir="$bootstrap_dir" apply -input=false -auto-approve \
  -var="project_id=$project_id" \
  -var="region=$region" \
  -var="state_bucket_name=$state_bucket"

TF_STATE_BUCKET="$state_bucket" "$script_dir/terraform-init-retry.sh" "$terraform_dir"

cat <<EOF

Bootstrap complete.

State bucket: $state_bucket
Next: create $terraform_dir/terraform.tfvars from its example, then run:
  terraform -chdir="$terraform_dir" plan
  terraform -chdir="$terraform_dir" apply

The production root declares the cost-bounded GKE, Cloud SQL, Artifact Registry,
private networking, workload identity, and runtime service accounts.
EOF
