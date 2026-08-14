import { readFileSync } from "node:fs";

export interface ApiConfig {
  port: number;
  databaseUrl?: string;
  healthkitIngestToken?: string;
  corsOrigin: string;
}

export function readConfig(env: NodeJS.ProcessEnv = process.env): ApiConfig {
  return {
    port: parseInt(env.PORT ?? "8080", 10),
    databaseUrl: env.DATABASE_URL,
    healthkitIngestToken: readSecret(env.HEALTHKIT_INGEST_TOKEN, env.HEALTHKIT_INGEST_TOKEN_FILE),
    corsOrigin: env.CORS_ORIGIN ?? "*"
  };
}

function readSecret(value?: string, filePath?: string): string | undefined {
  if (value) {
    return value;
  }

  if (!filePath) {
    return undefined;
  }

  const secret = readFileSync(filePath, "utf8").trim();
  return secret || undefined;
}
