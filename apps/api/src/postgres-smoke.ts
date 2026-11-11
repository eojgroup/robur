import assert from "node:assert/strict";
import { randomUUID } from "node:crypto";
import pg from "pg";
import { PostgresFitnessStore } from "./db.js";
import { tokenHash } from "./auth.js";
import { HttpError } from "./health-cloud.js";
import type { HealthSyncBatch } from "@robur/core";

// Run explicitly in an isolated job, with the runtime role. Uses synthetic data
// only, never reads another account's records, and deletes its fixtures on exit.
const url = process.env.DATABASE_URL;
if (!url) throw new Error("DATABASE_URL is required.");
const pool = new pg.Pool({ connectionString: url, max: 1 });
const store = new PostgresFitnessStore(url);
const owner = `deployment-smoke:${randomUUID()}`, other = `deployment-smoke:${randomUUID()}`;
const capturedAt = new Date().toISOString();
const batch: HealthSyncBatch = { schemaVersion: 1, sourceDeviceId: "synthetic-smoke", capturedAt, records: [
  { kind: "daily", id: "day", observedAt: capturedAt, data: { steps: 9000 } },
  { kind: "score", id: "score", observedAt: capturedAt, data: { methodologyVersion: "synthetic-smoke", recovery: 70 } },
  { kind: "workout", id: "workout", observedAt: capturedAt, data: { minutes: 30, appleEffort: 5, heartRateSamples: [{ bpm: 120 }] } },
  { kind: "quantity", id: "quantity", observedAt: capturedAt, data: { value: 120 } },
  { kind: "fitness", id: "fitness", observedAt: capturedAt, data: { value: 45 } }
] };
try {
  const result = await pool.query<{ admin: boolean; createdb: boolean; createrole: boolean; ddl: boolean; dml: boolean }>(
    `select pg_has_role(current_user,'cloudsqlsuperuser','MEMBER') as admin,
     rolcreatedb as createdb, rolcreaterole as createrole,
     has_schema_privilege(current_user,'public','CREATE') as ddl,
     has_table_privilege(current_user,'health_record','INSERT,SELECT,UPDATE,DELETE') as dml
     from pg_roles where rolname=current_user`);
  assert.deepEqual(result.rows[0], { admin: false, createdb: false, createrole: false, ddl: false, dml: true });
  await store.ping();
  const { code } = await store.createPairing(owner);
  const device = await store.redeemPairing(code, batch.sourceDeviceId, "Synthetic smoke test");
  assert.equal((await store.authenticateDevice(tokenHash(device.deviceToken)))?.ownerId, owner);
  await assert.rejects(store.redeemPairing(code, "other", "Replay"), e => e instanceof HttpError && e.status === 400);
  await assert.rejects(store.saveBatch(owner, batch), e => e instanceof HttpError && e.status === 403);
  await store.setConsent(owner, { version: "health-sync-v1", detailedSamples: true, workoutReviews: false });
  await store.saveBatch(owner, batch); await store.saveBatch(owner, batch);
  await store.saveBatch(owner, { ...batch, capturedAt: new Date(Date.now() - 60_000).toISOString(), records: [{ ...batch.records[0], data: { steps: 1 } }] });
  const dashboard = await store.dashboard(owner, "1970-01-01T00:00:00Z");
  assert.equal(dashboard.counts.daily, 1); assert.equal(dashboard.counts.quantity, 1); assert.equal(dashboard.counts.fitness, 1);
  assert.equal(dashboard.records.length, 3);
  assert.equal(dashboard.records.find(r => r.kind === "daily")?.data.steps, 9000);
  assert.equal(dashboard.records.find(r => r.kind === "workout")?.data.heartRateSamples, undefined);
  assert.deepEqual((await store.dashboard(other, "1970-01-01T00:00:00Z")).records, []);
  await store.revokeConsent(owner);
  await assert.rejects(store.saveBatch(owner, batch), e => e instanceof HttpError && e.status === 403);
  await store.deleteHealthData(owner);
  assert.equal(await store.authenticateDevice(tokenHash(device.deviceToken)), null);
  assert.equal(await store.getConsent(owner), null);
  assert.deepEqual((await store.dashboard(owner, "1970-01-01T00:00:00Z")).records, []);
  console.log("PostgreSQL smoke passed: runtime privileges, pairing, consent, idempotency, owner isolation, compact analytics and cascading deletion.");
} finally {
  await store.deleteHealthData(owner);
  await store.deleteHealthData(other);
  await store.close(); await pool.end();
}
