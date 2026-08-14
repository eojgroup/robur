import { mkdtempSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { afterEach, describe, expect, it } from "vitest";
import { readConfig } from "../src/config";

const temporaryDirectories: string[] = [];

afterEach(() => {
  for (const directory of temporaryDirectories.splice(0)) {
    rmSync(directory, { recursive: true, force: true });
  }
});

describe("API configuration", () => {
  it("reads and trims a secret mounted from a file", () => {
    const directory = mkdtempSync(join(tmpdir(), "robur-api-config-"));
    temporaryDirectories.push(directory);
    const secretFile = join(directory, "healthkit-ingest-token");
    writeFileSync(secretFile, "  server-only-token\n");

    const config = readConfig({ HEALTHKIT_INGEST_TOKEN_FILE: secretFile });

    expect(config.healthkitIngestToken).toBe("server-only-token");
  });

  it("uses an explicitly supplied local token before a mounted file", () => {
    const config = readConfig({
      HEALTHKIT_INGEST_TOKEN: "local-token",
      HEALTHKIT_INGEST_TOKEN_FILE: "/not-used"
    });

    expect(config.healthkitIngestToken).toBe("local-token");
  });
});
