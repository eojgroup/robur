# CI Repair Agent

The CI Repair Agent is a repository-local, configuration-driven GitHub Actions
automation. When a selected workflow fails on a trusted push to the configured
base branch, it retrieves the failed log, diagnoses it against a small reviewed
recipe set, applies at most one bounded mechanical repair, validates it locally,
and opens a **draft** pull request. It never auto-merges.

It is intentionally not an autonomous shell or code-generation system. Unknown
failures are reported without changing the repository. That conservative design
is what makes it safe to leave enabled as the repository grows.

## Trigger and trust boundary

`.github/workflows/ci-repair-agent.yml` listens for completed failures from the
workflow names listed in both that workflow and
`.github/ci-repair-agent.json`.

Before repair, it requires all of the following:

- completed run with a `failure` conclusion;
- `push` event, not `pull_request`, `workflow_dispatch`, or a fork;
- the configured base branch (`main`); and
- the configured repository (`eojgroup/robur`).

It checks out the current trusted default branch, not the failed revision. The
repair configuration therefore cannot come from a failed feature branch or log.
The workflow has write permissions because a repair branch and draft PR need to
be created, but those permissions are unreachable for untrusted PR input.

Manual dispatch accepts a run ID for re-investigation, but the Node agent applies
the exact same trust checks before it can select a repair recipe.

## Safe operating sequence

```text
selected failure on trusted main push
  -> retrieve metadata + failed logs
  -> redact + cap logs to 256 KiB
  -> match one reviewed recipe, or stop
  -> run only commands stored in default-branch configuration
  -> enforce file/path/line diff limits
  -> run recipe-local validation
  -> push a new automation branch and open a draft PR
  -> dispatch the repository CI workflow on that repair branch
```

The agent never evaluates shell code, filenames, URLs, or instructions from
workflow logs. Logs are redacted for common GitHub/Google tokens, bearer tokens,
private keys, and secret-like assignments before matching/reporting. The pull
request body contains the workflow/run metadata and diagnosis, not raw logs.

The workflow uses a unique branch per failed run and refuses to overwrite an
existing one. This makes retries observable and avoids force-pushing a repair a
human may already be reviewing.

## Current recipes

`.github/ci-repair-agent.json` contains the reviewed recipe allowlist:

| ID | Failure signature | Allowed change | Local validation |
| --- | --- | --- | --- |
| `pnpm-lockfile-out-of-date` | `ERR_PNPM_OUTDATED_LOCKFILE` | `pnpm-lock.yaml` only | locked install, typecheck, tests, build |
| `terraform-format` | `terraform fmt -check` | `infra/gcp/**/*.tf` only | Terraform formatting checks |

Both recipes are deterministic and low-risk. The diff guard rejects more than
five changed files, more than 300 changed lines, binary changes, and any path
outside the selected recipe’s allowlist.

## Adding a recipe safely

Treat a new recipe as production automation code. A reviewer should verify that
it is deterministic, reversible through a normal PR revert, and does not
provision infrastructure, alter credentials, change dependencies broadly, or
run untrusted input.

1. Add an exact, stable `matchAll` signature to
   `.github/ci-repair-agent.json`.
2. Limit `repair` commands to known repository commands from the trusted config.
   Never interpolate data from logs, issue text, branch names, or workflow
   event payloads.
3. Give the recipe the smallest viable `allowPaths`, file count, and line count.
4. Add focused tests to `scripts/ci-repair-agent.test.mjs` for matching and
   rejected edge cases.
5. Add a local `validate` sequence and set `validationWorkflow` to a workflow
   with `workflow_dispatch` enabled.
6. Review the generated draft PR process on a non-production failure before
   relying on the recipe.

Do not add a recipe for deployment failures that runs Terraform apply, modifies
cloud IAM, creates secrets, changes GitHub protection, retries billing, or
uploads artifacts. Those failures require human authorization.

## Operations and observability

Each CI Repair Agent run appends a concise report to the Actions job summary.
When it creates a PR, the same report forms the draft PR body and the workflow
dispatches `Robur CI` against the repair branch. The human reviewer still owns
the merge decision and can inspect the normal CI checks.

To inspect a run manually:

```bash
gh run list --workflow ci-repair-agent.yml --repo eojgroup/robur
gh run view <repair-run-id> --repo eojgroup/robur --log-failed
```

To ask it to inspect a known failed run, use the **CI Repair Agent** workflow’s
manual dispatch and provide the numeric failed run ID. A manual request cannot
bypass the source trust policy.

## Cost and data handling

The agent uses GitHub-hosted workflow minutes only when a monitored workflow
fails. It has no LLM service, third-party webhook, database, cloud runtime, or
new secret. Logs are fetched only for the selected failure, capped before use,
and are not uploaded outside GitHub. This keeps the repair mechanism both
repository-agnostic and inexpensive.
