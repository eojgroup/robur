import pg from "pg";
import { randomBytes, randomInt } from "node:crypto";
import { type HealthConsent, type HealthDashboard, type HealthRecord, type HealthRecordKind, type HealthSyncBatch } from "@robur/core";
import { type Principal, tokenHash } from "./auth.js";
import { containsDetailedSamples, containsWorkoutReviews, HttpError } from "./health-cloud.js";

const { Pool } = pg;
interface Pairing { code: string; expiresAt: string }
interface PairedDevice { deviceToken: string; expiresAt: string; userId: string }
export interface FitnessStore {
  ping(): Promise<void>;
  authenticateDevice(hash: string): Promise<Principal | null>;
  createPairing(owner: string): Promise<Pairing>;
  redeemPairing(code: string, sourceDeviceId: string, deviceName: string): Promise<PairedDevice>;
  getConsent(owner: string): Promise<HealthConsent | null>;
  setConsent(owner: string, value: Omit<HealthConsent, "grantedAt">): Promise<HealthConsent>;
  revokeConsent(owner: string): Promise<void>;
  deleteHealthData(owner: string): Promise<void>;
  saveBatch(owner: string, batch: HealthSyncBatch): Promise<void>;
  dashboard(owner: string, since: string): Promise<HealthDashboard>;
}
const pairCode = () => Array.from({ length: 10 }, () => "ABCDEFGHJKLMNPQRSTUVWXYZ23456789"[randomInt(32)]).join("");
const tenMinutes = () => new Date(Date.now() + 10 * 60_000).toISOString();
const deviceExpiry = () => new Date(Date.now() + 90 * 86_400_000).toISOString();
function assertConsent(consent: HealthConsent | null, batch: HealthSyncBatch) {
  if (!consent) throw new HttpError(403, "Health sync consent is required. Review the sync settings on your device.");
  if (!consent.detailedSamples && containsDetailedSamples(batch)) throw new HttpError(403, "Detailed Health samples require separate consent.");
  if (!consent.workoutReviews && containsWorkoutReviews(batch)) throw new HttpError(403, "Workout notes and muscle tags require separate consent.");
}
function compactRecord(record: HealthRecord): HealthRecord {
  const { heartRateSamples: _hr, rawSamples: _raw, samples: _samples, ...data } = record.data;
  return { ...record, data };
}

/** Explicit local/test adapter; production startup rejects a missing database URL. */
export class InMemoryFitnessStore implements FitnessStore {
  private readonly consents = new Map<string, HealthConsent>();
  private readonly data = new Map<string, Map<string, { record: HealthRecord; capturedAt: string }>>();
  private readonly pairings = new Map<string, { owner: string; expiresAt: string }>();
  private readonly devices = new Map<string, Principal & { expiresAt: string }>();
  private readonly lastSync = new Map<string, string>();
  async ping() {}
  async authenticateDevice(hash: string) {
    const device = this.devices.get(hash);
    return device && device.expiresAt > new Date().toISOString() ? device : null;
  }
  async createPairing(owner: string) {
    const code = pairCode(), expiresAt = tenMinutes();
    this.pairings.set(tokenHash(code), { owner, expiresAt });
    return { code, expiresAt };
  }
  async redeemPairing(code: string, sourceDeviceId: string, _deviceName: string) {
    const hash = tokenHash(code), pairing = this.pairings.get(hash);
    if (!pairing || pairing.expiresAt <= new Date().toISOString()) throw new HttpError(400, "Pairing code is invalid, expired or already used.");
    this.pairings.delete(hash);
    const deviceToken = `rbr_${randomBytes(32).toString("base64url")}`, expiresAt = deviceExpiry();
    this.devices.set(tokenHash(deviceToken), { ownerId: pairing.owner, kind: "device", sourceDeviceId, expiresAt });
    return { deviceToken, expiresAt, userId: pairing.owner };
  }
  async getConsent(owner: string) { return this.consents.get(owner) ?? null; }
  async setConsent(owner: string, value: Omit<HealthConsent, "grantedAt">) {
    const consent = { ...value, grantedAt: new Date().toISOString() };
    this.consents.set(owner, consent); return consent;
  }
  async revokeConsent(owner: string) { this.consents.delete(owner); }
  async deleteHealthData(owner: string) {
    this.consents.delete(owner); this.data.delete(owner); this.lastSync.delete(owner);
    for (const [key, device] of this.devices) if (device.ownerId === owner) this.devices.delete(key);
    for (const [key, pairing] of this.pairings) if (pairing.owner === owner) this.pairings.delete(key);
  }
  async saveBatch(owner: string, batch: HealthSyncBatch) {
    assertConsent(this.consents.get(owner) ?? null, batch);
    const data = this.data.get(owner) ?? new Map<string, { record: HealthRecord; capturedAt: string }>();
    for (const record of batch.records) {
      const key = `${record.kind}:${record.id}`, prior = data.get(key);
      if (!prior || prior.capturedAt <= batch.capturedAt) data.set(key, { record: structuredClone(record), capturedAt: batch.capturedAt });
    }
    for (const deleted of batch.deleted ?? []) {
      const key = `${deleted.kind}:${deleted.id}`, prior = data.get(key);
      if (!prior || prior.capturedAt <= batch.capturedAt) data.delete(key);
    }
    this.data.set(owner, data); this.lastSync.set(owner, new Date().toISOString());
  }
  async dashboard(owner: string, since: string): Promise<HealthDashboard> {
    const all = [...(this.data.get(owner)?.values() ?? [])].map(item => item.record);
    const counts: HealthDashboard["counts"] = {};
    for (const record of all) counts[record.kind] = (counts[record.kind] ?? 0) + 1;
    const visible = all.filter(record => record.observedAt >= since && !["quantity", "sleep"].includes(record.kind))
      .sort((a, b) => a.observedAt.localeCompare(b.observedAt) || a.id.localeCompare(b.id));
    return { records: visible.slice(-10000).map(compactRecord), counts, consent: await this.getConsent(owner),
      lastSyncedAt: this.lastSync.get(owner) ?? null, truncated: visible.length > 10000 };
  }
}

export class PostgresFitnessStore implements FitnessStore {
  private readonly pool: pg.Pool;
  constructor(databaseUrl: string) {
    this.pool = new Pool({ connectionString: databaseUrl, max: 4, idleTimeoutMillis: 30000,
      connectionTimeoutMillis: 10000, statement_timeout: 20000 });
  }
  async ping() { await this.pool.query("select 1"); }
  async authenticateDevice(hash: string): Promise<Principal | null> {
    const result = await this.pool.query<{ owner_id: string; source_device_id: string }>(
      "select owner_id, source_device_id from health_sync_device where token_hash = $1 and expires_at > now()", [hash]);
    const row = result.rows[0];
    return row ? { ownerId: row.owner_id, sourceDeviceId: row.source_device_id, kind: "device" } : null;
  }
  async createPairing(owner: string): Promise<Pairing> {
    await this.pool.query("insert into health_account (owner_id) values ($1) on conflict do nothing", [owner]);
    const code = pairCode(), expiresAt = tenMinutes();
    await this.pool.query("delete from health_pairing where expires_at < now()");
    await this.pool.query("insert into health_pairing(code_hash,owner_id,expires_at) values($1,$2,$3)", [tokenHash(code), owner, expiresAt]);
    return { code, expiresAt };
  }
  async redeemPairing(code: string, sourceDeviceId: string, deviceName: string): Promise<PairedDevice> {
    const client = await this.pool.connect();
    try {
      await client.query("begin");
      const result = await client.query<{ owner_id: string }>("delete from health_pairing where code_hash=$1 and expires_at > now() returning owner_id", [tokenHash(code)]);
      const owner = result.rows[0]?.owner_id;
      if (!owner) throw new HttpError(400, "Pairing code is invalid, expired or already used.");
      const deviceToken = `rbr_${randomBytes(32).toString("base64url")}`, expiresAt = deviceExpiry();
      await client.query("insert into health_sync_device(token_hash,owner_id,source_device_id,device_name,expires_at) values($1,$2,$3,$4,$5)",
        [tokenHash(deviceToken), owner, sourceDeviceId, deviceName, expiresAt]);
      await client.query("commit");
      return { deviceToken, expiresAt, userId: owner };
    } catch (error) { await client.query("rollback"); throw error; } finally { client.release(); }
  }
  async getConsent(owner: string): Promise<HealthConsent | null> {
    const result = await this.pool.query<{ consent_version: string | null; detailed_samples: boolean; workout_reviews: boolean; consent_granted_at: Date | null }>(
      "select consent_version,detailed_samples,workout_reviews,consent_granted_at from health_account where owner_id=$1", [owner]);
    const row = result.rows[0];
    return row?.consent_version && row.consent_granted_at ? { version: row.consent_version, detailedSamples: row.detailed_samples, workoutReviews: row.workout_reviews, grantedAt: row.consent_granted_at.toISOString() } : null;
  }
  async setConsent(owner: string, value: Omit<HealthConsent, "grantedAt">): Promise<HealthConsent> {
    const result = await this.pool.query<{ consent_granted_at: Date }>(
      `insert into health_account(owner_id,consent_version,detailed_samples,workout_reviews,consent_granted_at) values($1,$2,$3,$4,now())
       on conflict(owner_id) do update set consent_version=$2,detailed_samples=$3,workout_reviews=$4,consent_granted_at=now() returning consent_granted_at`,
      [owner, value.version, value.detailedSamples, value.workoutReviews]);
    return { ...value, grantedAt: result.rows[0].consent_granted_at.toISOString() };
  }
  async revokeConsent(owner: string) {
    await this.pool.query("update health_account set consent_version=null,detailed_samples=false,workout_reviews=false,consent_granted_at=null where owner_id=$1", [owner]);
  }
  async deleteHealthData(owner: string) {
    // Foreign-key cascades erase all records, device tokens and unused pairing codes.
    await this.pool.query("delete from health_account where owner_id=$1", [owner]);
  }
  async saveBatch(owner: string, batch: HealthSyncBatch) {
    const client = await this.pool.connect();
    try {
      await client.query("begin");
      const result = await client.query<{ consent_version: string | null; detailed_samples: boolean; workout_reviews: boolean; consent_granted_at: Date | null }>(
        "select consent_version,detailed_samples,workout_reviews,consent_granted_at from health_account where owner_id=$1 for update", [owner]);
      const row = result.rows[0];
      assertConsent(row?.consent_version && row.consent_granted_at ? { version: row.consent_version, detailedSamples: row.detailed_samples, workoutReviews: row.workout_reviews, grantedAt: row.consent_granted_at.toISOString() } : null, batch);
      for (const record of batch.records) {
        await client.query(`insert into health_record(owner_id,record_kind,record_id,observed_at,source_device_id,captured_at,payload)
          values($1,$2,$3,$4,$5,$6,$7) on conflict(owner_id,record_kind,record_id) do update set
          observed_at=excluded.observed_at,source_device_id=excluded.source_device_id,captured_at=excluded.captured_at,payload=excluded.payload,updated_at=now()
          where excluded.captured_at >= health_record.captured_at`,
        [owner, record.kind, record.id, record.observedAt, batch.sourceDeviceId, batch.capturedAt, record.data]);
      }
      for (const record of batch.deleted ?? []) await client.query(
        "delete from health_record where owner_id=$1 and record_kind=$2 and record_id=$3 and captured_at <= $4", [owner, record.kind, record.id, batch.capturedAt]);
      await client.query("update health_account set last_synced_at=now() where owner_id=$1", [owner]);
      await client.query("commit");
    } catch (error) { await client.query("rollback"); throw error; } finally { client.release(); }
  }
  async dashboard(owner: string, since: string): Promise<HealthDashboard> {
    const [records, counts, account, consent] = await Promise.all([
      this.pool.query<{ record_kind: HealthRecordKind; record_id: string; observed_at: Date; payload: HealthRecord["data"] }>(
        `select record_kind,record_id,observed_at,payload - 'heartRateSamples' - 'rawSamples' - 'samples' as payload from health_record
         where owner_id=$1 and observed_at >= $2 and record_kind not in ('quantity','sleep') order by observed_at desc,record_id limit 10001`, [owner, since]),
      this.pool.query<{ record_kind: HealthRecordKind; count: string }>("select record_kind,count(*) from health_record where owner_id=$1 group by record_kind", [owner]),
      this.pool.query<{ last_synced_at: Date | null }>("select last_synced_at from health_account where owner_id=$1", [owner]), this.getConsent(owner)
    ]);
    return { records: records.rows.slice(0,10000).map(row => ({ kind: row.record_kind, id: row.record_id, observedAt: row.observed_at.toISOString(), data: row.payload })).reverse(),
      counts: Object.fromEntries(counts.rows.map(row => [row.record_kind, Number(row.count)])), lastSyncedAt: account.rows[0]?.last_synced_at?.toISOString() ?? null,
      consent, truncated: records.rows.length > 10000 };
  }
}
export function createFitnessStore(databaseUrl?: string): FitnessStore {
  if (!databaseUrl && process.env.NODE_ENV === "production") throw new Error("DATABASE_URL is required in production; in-memory health storage is disabled.");
  return databaseUrl ? new PostgresFitnessStore(databaseUrl) : new InMemoryFitnessStore();
}
