import pg from "pg";
import type { HealthKitSyncPayload, PushDeviceRegistration } from "@robur/core";

const { Pool } = pg;

export interface FitnessStore {
  latestSnapshot(): Promise<HealthKitSyncPayload | null>;
  saveHealthKitSync(payload: HealthKitSyncPayload): Promise<void>;
  savePushDeviceRegistration(payload: PushDeviceRegistration): Promise<void>;
}

export class InMemoryFitnessStore implements FitnessStore {
  private current: HealthKitSyncPayload | null = null;

  async latestSnapshot(): Promise<HealthKitSyncPayload | null> {
    return this.current;
  }

  async saveHealthKitSync(payload: HealthKitSyncPayload): Promise<void> {
    this.current = payload;
  }

  async savePushDeviceRegistration(_payload: PushDeviceRegistration): Promise<void> {
    return;
  }
}

export class PostgresFitnessStore implements FitnessStore {
  private readonly pool: pg.Pool;

  constructor(databaseUrl: string) {
    this.pool = new Pool({
      connectionString: databaseUrl
    });
  }

  async latestSnapshot(): Promise<HealthKitSyncPayload | null> {
    const result = await this.pool.query<{
      source_device_id: string;
      captured_at: Date;
      snapshot: HealthKitSyncPayload["snapshot"];
    }>(
      `select source_device_id, captured_at, snapshot
       from healthkit_sync_event
       order by captured_at desc
       limit 1`
    );

    const row = result.rows[0];
    if (!row) {
      return null;
    }

    return {
      sourceDeviceId: row.source_device_id,
      capturedAt: row.captured_at.toISOString(),
      snapshot: row.snapshot
    };
  }

  async saveHealthKitSync(payload: HealthKitSyncPayload): Promise<void> {
    await this.pool.query(
      `insert into healthkit_sync_event (source_device_id, captured_at, snapshot)
       values ($1, $2, $3)`,
      [payload.sourceDeviceId, payload.capturedAt, payload.snapshot]
    );
  }

  async savePushDeviceRegistration(payload: PushDeviceRegistration): Promise<void> {
    await this.pool.query(
      `insert into push_device_registration
        (installation_id, platform, device_token, bundle_id, environment, registered_at)
       values ($1, $2, $3, $4, $5, $6)
       on conflict (installation_id, platform, environment)
       do update set
         device_token = excluded.device_token,
         bundle_id = excluded.bundle_id,
         registered_at = excluded.registered_at,
         updated_at = now()`,
      [
        payload.installationId,
        payload.platform,
        payload.deviceToken,
        payload.bundleId,
        payload.environment,
        payload.registeredAt
      ]
    );
  }
}

export function createFitnessStore(databaseUrl?: string): FitnessStore {
  return databaseUrl ? new PostgresFitnessStore(databaseUrl) : new InMemoryFitnessStore();
}
