#!/usr/bin/env bash

set -euo pipefail

usage() {
  cat <<'EOF'
Usage: add-secret-version.sh PROJECT_ID SECRET_ID

Reads the secret value from standard input and adds a Secret Manager version.
The secret value is never echoed, logged, committed, or stored in Terraform
state. Example:

  openssl rand -base64 48 | ./infra/scripts/add-secret-version.sh \
    my-project robur-healthkit-ingest-token
EOF
}

project_id="${1:-}"
secret_id="${2:-}"

if [[ -z "$project_id" || -z "$secret_id" || $# -ne 2 ]]; then
  usage >&2
  exit 1
fi

if ! command -v gcloud >/dev/null 2>&1; then
  echo "Required command is not installed: gcloud" >&2
  exit 1
fi

if [[ -t 0 ]]; then
  echo "Pass the secret through standard input; refusing to place it on a command line." >&2
  usage >&2
  exit 1
fi

gcloud secrets versions add "$secret_id" --project="$project_id" --data-file=- >/dev/null
echo "Added a new version of $secret_id in $project_id."
