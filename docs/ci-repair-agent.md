# CI Repair Agent

The CI Repair Agent is repository-local, configuration-driven GitHub Actions
automation. It inspects a selected failed run, matches it only against reviewed
mechanical recipes, applies at most one bounded change, validates it, and opens
a **draft** pull request. It never auto-merges.

It is integrated into `terraform-deploy.yml`; there is no standalone fourth
repair workflow. This keeps the delivery surface to three workflow files:
`apple-build.yml`, `gke-deploy.yml`, and `terraform-deploy.yml`.

## Trigger and trust boundary

The repair job is isolated from the Terraform deploy job. For a
`repository_dispatch` event, the Terraform apply job does not run; only the
repair job is eligible.

- A failed trusted `main` push or manual run of **Build Apple clients**, **Build
  and Deploy to GKE**, or **Terraform Infrastructure Deployment** sends a
  `ci-repair` `repository_dispatch` with the failed run ID.
- Before any recipe is selected, the Node agent fetches the referenced run and
  independently requires: `completed`, `failure`, a `push` or
  `workflow_dispatch` event, `main` as the head branch, repository
  `eojgroup/robur`, and a workflow name in the committed allowlist.

Consequently, a fork, pull request, arbitrary dispatch payload, feature branch,
unknown workflow, or successful/incomplete run cannot select a repair. The job
checks out the current trusted default branch, not the failed revision, so its
configuration cannot be supplied by a failed feature branch or log.

## Safe operating sequence

```text
failed monitored run
  -> trusted event delivers a run ID to terraform-deploy.yml's repair job
  -> fetch run metadata and failed-step log
  -> cap to 256 KiB and redact common secrets
  -> match one default-branch recipe, or report no repair
  -> execute only that recipe's committed commands
  -> enforce path, file-count, line-count, and binary-diff limits
  -> run its local validation
  -> create a unique draft PR and dispatch validate-only GKE checks
```

The agent never evaluates shell code, filenames, URLs, or instructions from
workflow logs. Logs are redacted for common GitHub/Google tokens, bearer tokens,
private keys, and secret-like assignments before matching and reporting. The
draft PR body contains metadata and the diagnosis, not raw failed logs.

It refuses to overwrite the branch for an already processed failed run. Unknown
failures are reported without a repository change.

## Current recipe allowlist

`.github/ci-repair-agent.json` is the source of truth. The current reviewed
recipes are:

| ID | Failure signature | Allowed change | Local validation |
| --- | --- | --- | --- |
| `pnpm-lockfile-out-of-date` | `ERR_PNPM_OUTDATED_LOCKFILE` | `pnpm-lock.yaml` only | locked install, typecheck, tests, build |
| `terraform-format` | `terraform fmt -check` | `infra/gcp/**/*.tf` only | Terraform formatting checks for bootstrap and production roots |

The diff guard rejects more than five changed files, more than 300 changed
lines, binary changes, and every path outside the selected recipe's allowlist.
The repair route never runs Terraform plan/apply, changes cloud IAM, creates
secrets, changes GitHub protection, retries billing, uploads artifacts, or
merges a pull request.

## Adding a recipe safely

Treat every recipe as production automation code.

1. Add a stable, exact `matchAll` signature to
   `.github/ci-repair-agent.json`.
2. Limit repair commands to deterministic repository commands in that committed
   configuration. Never interpolate a log, issue, branch, URL, or event value
   into a command.
3. Use the smallest viable path allowlist and retain the global diff limits.
4. Add focused tests to `scripts/ci-repair-agent.test.mjs`, including rejected
   trust and diff cases.
5. Supply a local validation command and a validate-only dispatchable workflow.
6. Review a generated draft PR before relying on the recipe for routine use.

Do not add repair recipes for infrastructure deployment failures, credentials,
IAM, secrets, billing, production configuration, or artifact publication.
Those require explicit human authority.

## Operations and observability

Every repair job writes a concise report to its Actions summary. If it makes a
change, the same report becomes the draft PR body and `gke-deploy.yml` is
dispatched on that branch with deployment disabled. A human still owns review,
normal CI approval, merge, and any subsequent production deployment.

Inspect the integrated workflow and the source failure with:

```bash
gh run list --workflow terraform-deploy.yml --repo eojgroup/robur
gh run view <repair-workflow-run-id> --repo eojgroup/robur --log-failed
gh run view <failed-run-id> --repo eojgroup/robur --log-failed
```

A trusted administrator may use the repository's `ci-repair` dispatch route to
re-investigate a numeric failed run ID, but that only queues observation. The
agent repeats the same run-metadata trust checks and cannot use the request to
bypass them.

## Cost and data handling

The agent uses GitHub-hosted minutes only after a monitored failure. It has no
LLM, third-party runtime, database, webhook, cloud resource, or new secret.
It fetches only the selected failure log, caps it before use, and does not
upload it outside GitHub. Integrating it into the Terraform workflow avoids a
separate workflow while preserving a distinct repair-only execution path.
