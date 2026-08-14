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
    healthkitIngestToken: env.HEALTHKIT_INGEST_TOKEN,
    corsOrigin: env.CORS_ORIGIN ?? "*"
  };
}
