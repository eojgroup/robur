import assert from "node:assert/strict";
import test from "node:test";
import {
  isTrustedRun,
  pathMatches,
  redactSensitive,
  selectRecipe,
  truncateText,
  validateDiff
} from "./ci-repair-agent.mjs";

const config = {
  repository: "eojgroup/robur",
  baseBranch: "main",
  monitoredWorkflows: ["Build and Deploy to GKE"],
  limits: { maxChangedFiles: 2, maxChangedLines: 10 },
  recipes: [
    {
      id: "lockfile",
      matchAll: ["ERR_PNPM_OUTDATED_LOCKFILE"],
      allowPaths: ["pnpm-lock.yaml"]
    },
    {
      id: "terraform-format",
      matchAll: ["terraform fmt -check"],
      allowPaths: ["infra/gcp/**/*.tf"]
    }
  ]
};

const trustedRun = {
  id: 17,
  name: "Build and Deploy to GKE",
  status: "completed",
  conclusion: "failure",
  event: "push",
  head_branch: "main",
  head_repository: { full_name: "eojgroup/robur" }
};

test("redacts common credentials before log matching or reporting", () => {
  const result = redactSensitive("ghp_abcdefghijklmnopqrstuvwxyz123456 Bearer very-secret-token password=hunter2");
  assert.doesNotMatch(result, /abcdefghijklmnopqrstuvwxyz/);
  assert.doesNotMatch(result, /very-secret-token/);
  assert.doesNotMatch(result, /hunter2/);
});

test("truncates failure logs to the configured byte boundary", () => {
  assert.match(truncateText("abcdefgh", 3), /^abc/);
  assert.match(truncateText("abcdefgh", 3), /truncated/);
});

test("selects only a reviewed matching recipe", () => {
  assert.equal(selectRecipe(config, "Failure: ERR_PNPM_OUTDATED_LOCKFILE"), config.recipes[0]);
  assert.equal(selectRecipe(config, "a different failure"), null);
});

test("trust policy accepts default-branch pushes and manual runs but rejects untrusted sources", () => {
  assert.equal(isTrustedRun(trustedRun, config), true);
  assert.equal(isTrustedRun({ ...trustedRun, event: "workflow_dispatch" }, config), true);
  assert.equal(isTrustedRun({ ...trustedRun, event: "pull_request" }, config), false);
  assert.equal(isTrustedRun({ ...trustedRun, head_branch: "feature/x" }, config), false);
  assert.equal(isTrustedRun({ ...trustedRun, head_repository: { full_name: "attacker/robur" } }, config), false);
  assert.equal(isTrustedRun({ ...trustedRun, name: "Unknown workflow" }, config), false);
});

test("glob matching permits expected Terraform paths without allowing unrelated files", () => {
  assert.equal(pathMatches("infra/gcp/terraform/main.tf", "infra/gcp/**/*.tf"), true);
  assert.equal(pathMatches("infra/gcp/main.tf", "infra/gcp/**/*.tf"), true);
  assert.equal(pathMatches("infra/gcp/terraform/terraform.tfvars", "infra/gcp/**/*.tf"), false);
  assert.equal(pathMatches("README.md", "infra/gcp/**/*.tf"), false);
});

test("diff guard limits changed paths, files, lines, and binary output", () => {
  const recipe = config.recipes[1];
  assert.deepEqual(
    validateDiff({ files: ["infra/gcp/terraform/main.tf"], numstat: ["2\t1\tinfra/gcp/terraform/main.tf"], recipe, limits: config.limits }),
    { valid: true, changedLines: 3 }
  );
  assert.equal(
    validateDiff({ files: ["README.md"], numstat: ["1\t0\tREADME.md"], recipe, limits: config.limits }).valid,
    false
  );
  assert.equal(
    validateDiff({ files: ["infra/gcp/terraform/main.tf"], numstat: ["-\t-\tinfra/gcp/terraform/main.tf"], recipe, limits: config.limits }).valid,
    false
  );
});
