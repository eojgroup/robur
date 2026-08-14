#!/usr/bin/env bash

set -euo pipefail

terraform_dir="${1:?Usage: terraform-init-retry.sh <terraform-directory>}"
attempts="${TERRAFORM_INIT_ATTEMPTS:-5}"
base_delay_seconds="${TERRAFORM_INIT_RETRY_DELAY_SECONDS:-15}"

for attempt in $(seq 1 "$attempts"); do
  echo "Running terraform init (attempt ${attempt}/${attempts})..."
  if terraform -chdir="$terraform_dir" init -input=false -backend=true; then
    exit 0
  fi

  if [ "$attempt" -eq "$attempts" ]; then
    echo "::error::Terraform init failed after ${attempts} attempts." >&2
    exit 1
  fi

  delay_seconds=$((attempt * base_delay_seconds))
  echo "::warning::Terraform init attempt ${attempt}/${attempts} failed; retrying in ${delay_seconds}s." >&2
  sleep "$delay_seconds"
done
