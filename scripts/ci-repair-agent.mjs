#!/usr/bin/env node

import { execFileSync, spawnSync } from "node:child_process";
import { mkdirSync, readFileSync, writeFileSync } from "node:fs";
import { dirname, resolve } from "node:path";
import { pathToFileURL } from "node:url";

const MAX_SAFE_COMMAND_LENGTH = 500;

export function redactSensitive(value) {
  return String(value)
    .replace(/-----BEGIN [A-Z ]*PRIVATE KEY-----[\s\S]*?-----END [A-Z ]*PRIVATE KEY-----/g, "[REDACTED PRIVATE KEY]")
    .replace(/\b(?:ghp|gho|ghu|ghs|ghr)_[A-Za-z0-9_]{20,}\b/g, "[REDACTED GITHUB TOKEN]")
    .replace(/\bgithub_pat_[A-Za-z0-9_]{20,}\b/g, "[REDACTED GITHUB TOKEN]")
    .replace(/\bAIza[A-Za-z0-9_-]{20,}\b/g, "[REDACTED GOOGLE API KEY]")
    .replace(/\bya29\.[A-Za-z0-9._-]+\b/g, "[REDACTED GOOGLE TOKEN]")
    .replace(/\bBearer\s+[A-Za-z0-9._~+\/-]+=*\b/gi, "Bearer [REDACTED]")
    .replace(/\b(password|passwd|secret|token|api[_-]?key)\s*[=:]\s*[^\s'"`]+/gi, "$1=[REDACTED]");
}

export function truncateText(value, maxBytes) {
  const input = Buffer.from(String(value));
  if (input.length <= maxBytes) return input.toString("utf8");
  return `${input.subarray(0, maxBytes).toString("utf8")}\n[truncated by CI Repair Agent]`;
}

export function selectRecipe(config, log) {
  const normalizedLog = String(log).toLowerCase();
  return config.recipes.find((recipe) => recipe.matchAll.every((needle) => normalizedLog.includes(needle.toLowerCase()))) ?? null;
}

export function isTrustedRun(run, config, expectedRepository = config.repository) {
  const workflowName = run.name ?? run.workflow_name ?? "";
  const repository = run.head_repository?.full_name ?? run.repository?.full_name ?? "";

  return (
    run.status === "completed" &&
    run.conclusion === "failure" &&
    ["push", "workflow_dispatch"].includes(run.event) &&
    run.head_branch === config.baseBranch &&
    repository === expectedRepository &&
    config.monitoredWorkflows.includes(workflowName)
  );
}

export function pathMatches(path, pattern) {
  let expression = "^";
  for (let index = 0; index < pattern.length; index += 1) {
    const character = pattern[index];
    const next = pattern[index + 1];
    if (character === "*" && next === "*") {
      if (pattern[index + 2] === "/") {
        expression += "(?:.*/)?";
        index += 2;
      } else {
        expression += ".*";
        index += 1;
      }
    } else if (character === "*") {
      expression += "[^/]*";
    } else {
      expression += character.replace(/[|\\{}()[\]^$+?.]/g, "\\$&");
    }
  }
  return new RegExp(`${expression}$`).test(path);
}

export function validateDiff({ files, numstat, recipe, limits }) {
  if (files.length === 0) return { valid: true, changedLines: 0 };
  if (files.length > limits.maxChangedFiles) {
    return { valid: false, reason: `Changed ${files.length} files; limit is ${limits.maxChangedFiles}.` };
  }

  const unexpected = files.filter((file) => !recipe.allowPaths.some((pattern) => pathMatches(file, pattern)));
  if (unexpected.length > 0) {
    return { valid: false, reason: `Changed paths outside recipe allowlist: ${unexpected.join(", ")}.` };
  }

  let changedLines = 0;
  for (const line of numstat) {
    const [added, deleted] = line.split("\t");
    if (!/^\d+$/.test(added) || !/^\d+$/.test(deleted)) {
      return { valid: false, reason: "Binary or unparsable diff detected." };
    }
    changedLines += Number(added) + Number(deleted);
  }
  if (changedLines > limits.maxChangedLines) {
    return { valid: false, reason: `Changed ${changedLines} lines; limit is ${limits.maxChangedLines}.` };
  }
  return { valid: true, changedLines };
}

function readJson(path) {
  try {
    return JSON.parse(readFileSync(path, "utf8"));
  } catch (error) {
    throw new Error(`Could not parse ${path}: ${error.message}`);
  }
}

function assertConfig(config) {
  if (!config || typeof config !== "object") throw new Error("Config must be an object.");
  if (!Array.isArray(config.recipes) || !Array.isArray(config.monitoredWorkflows)) {
    throw new Error("Config must include recipes and monitoredWorkflows arrays.");
  }
  if (!/^[A-Za-z0-9_.-]+\/[A-Za-z0-9_.-]+$/.test(config.repository ?? "")) {
    throw new Error("Config repository must be in owner/repository form.");
  }
  if (!/^[A-Za-z0-9._/-]+$/.test(config.baseBranch ?? "")) throw new Error("Config baseBranch is invalid.");
  for (const recipe of config.recipes) {
    if (!/^[a-z0-9-]+$/.test(recipe.id ?? "")) throw new Error("Recipe ID is invalid.");
    for (const field of ["matchAll", "repair", "validate", "allowPaths"]) {
      if (!Array.isArray(recipe[field]) || recipe[field].length === 0) {
        throw new Error(`Recipe ${recipe.id} requires a non-empty ${field} array.`);
      }
    }
    if (!recipe.repair.concat(recipe.validate).every((command) => typeof command === "string" && command.length <= MAX_SAFE_COMMAND_LENGTH)) {
      throw new Error(`Recipe ${recipe.id} contains an unsafe command.`);
    }
  }
}

function argumentValue(argumentsList, name, required = true) {
  const index = argumentsList.indexOf(name);
  if (index === -1) {
    if (!required) return undefined;
    throw new Error(`Missing required argument ${name}.`);
  }
  const value = argumentsList[index + 1];
  if (!value || value.startsWith("--")) throw new Error(`${name} requires a value.`);
  return value;
}

function getRecipe(config, id) {
  const recipe = config.recipes.find((candidate) => candidate.id === id);
  if (!recipe) throw new Error(`Unknown recipe: ${id}`);
  return recipe;
}

function runCommands(commands) {
  for (const command of commands) {
    const result = spawnSync(command, {
      cwd: process.cwd(),
      env: { ...process.env, CI: "true" },
      shell: true,
      stdio: "inherit"
    });
    if (result.status !== 0) throw new Error(`Command failed: ${command}`);
  }
}

function writeOutput(path, values) {
  if (!path) return;
  const content = Object.entries(values)
    .map(([key, value]) => `${key}=${String(value).replace(/[\r\n]/g, " ")}`)
    .join("\n");
  writeFileSync(path, `${content}\n`, { flag: "a" });
}

function reportFor({ run, trusted, recipe, reason }) {
  const safeName = redactSensitive(run.name ?? run.workflow_name ?? "unknown workflow");
  const safeUrl = redactSensitive(run.html_url ?? "");
  const lines = [
    "# CI Repair Agent report",
    "",
    `- Workflow: ${safeName}`,
    `- Run: ${Number.isSafeInteger(run.id) ? run.id : "unknown"}`,
    `- Source event: ${redactSensitive(run.event ?? "unknown")}`,
    `- Trusted source: ${trusted ? "yes" : "no"}`
  ];
  if (safeUrl) lines.push(`- Failed-run URL: ${safeUrl}`);
  if (recipe) {
    lines.push(`- Selected recipe: \`${recipe.id}\``, `- Diagnosis: ${recipe.diagnosis}`);
  }
  if (reason) lines.push(`- Result: ${redactSensitive(reason)}`);
  lines.push("", "The agent uses only the reviewed recipe configuration from the default branch. It does not execute text from workflow logs and it never auto-merges.");
  return `${lines.join("\n")}\n`;
}

function commandDiagnose(argumentsList) {
  const configPath = argumentValue(argumentsList, "--config");
  const runPath = argumentValue(argumentsList, "--run");
  const logPath = argumentValue(argumentsList, "--log");
  const reportPath = argumentValue(argumentsList, "--report");
  const githubOutput = argumentValue(argumentsList, "--github-output", false);
  const config = readJson(configPath);
  const run = readJson(runPath);
  assertConfig(config);

  const expectedRepository = process.env.GITHUB_REPOSITORY ?? config.repository;
  const trusted = isTrustedRun(run, config, expectedRepository);
  const rawLog = readFileSync(logPath, "utf8");
  const log = redactSensitive(truncateText(rawLog, config.limits.maxLogBytes));
  const recipe = trusted ? selectRecipe(config, log) : null;
  const reason = !trusted
    ? "Run does not meet the trusted default-branch push or manual-dispatch policy; no repair was attempted."
    : recipe
      ? "A bounded recipe is available for local repair and validation."
      : "No safe recipe matched the sanitized failure log; no repair was attempted.";

  mkdirSync(dirname(resolve(reportPath)), { recursive: true });
  writeFileSync(reportPath, reportFor({ run, trusted, recipe, reason }));
  writeOutput(githubOutput, {
    should_repair: recipe ? "true" : "false",
    recipe_id: recipe?.id ?? "",
    validation_workflow: recipe?.validationWorkflow ?? "",
    reason
  });
  process.stdout.write(`${reason}\n`);
}

function commandRunRecipe(argumentsList, mode) {
  const config = readJson(argumentValue(argumentsList, "--config"));
  assertConfig(config);
  const recipe = getRecipe(config, argumentValue(argumentsList, "--recipe"));
  runCommands(mode === "repair" ? recipe.repair : recipe.validate);
}

function commandVerifyDiff(argumentsList) {
  const config = readJson(argumentValue(argumentsList, "--config"));
  assertConfig(config);
  const recipe = getRecipe(config, argumentValue(argumentsList, "--recipe"));
  const files = execFileSync("git", ["diff", "--name-only"], { encoding: "utf8" })
    .split("\n")
    .filter(Boolean);
  const numstat = execFileSync("git", ["diff", "--numstat"], { encoding: "utf8" })
    .split("\n")
    .filter(Boolean);
  const result = validateDiff({ files, numstat, recipe, limits: config.limits });
  if (!result.valid) throw new Error(result.reason);
  process.stdout.write(`Diff is within the ${recipe.id} safety boundary (${result.changedLines} changed lines).\n`);
}

function main() {
  const [command, ...argumentsList] = process.argv.slice(2);
  if (command === "diagnose") return commandDiagnose(argumentsList);
  if (command === "repair") return commandRunRecipe(argumentsList, "repair");
  if (command === "validate") return commandRunRecipe(argumentsList, "validate");
  if (command === "verify-diff") return commandVerifyDiff(argumentsList);
  throw new Error("Usage: ci-repair-agent.mjs <diagnose|repair|validate|verify-diff> ...");
}

if (process.argv[1] && import.meta.url === pathToFileURL(resolve(process.argv[1])).href) {
  try {
    main();
  } catch (error) {
    process.stderr.write(`CI Repair Agent: ${redactSensitive(error.message)}\n`);
    process.exitCode = 1;
  }
}
