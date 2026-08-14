#!/usr/bin/env bash

set -euo pipefail

namespace="${1:?Usage: wait-for-k8s-job.sh <namespace> <job-name>}"
job_name="${2:?Usage: wait-for-k8s-job.sh <namespace> <job-name>}"
timeout="${K8S_JOB_TIMEOUT:-300s}"

kubectl -n "$namespace" wait --for=condition=complete "job/${job_name}" --timeout="$timeout"
