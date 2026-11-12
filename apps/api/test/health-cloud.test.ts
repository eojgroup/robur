import { afterEach, describe, expect, it } from "vitest";
import type { Server } from "node:http";
import { createServer } from "../src/server";
import { InMemoryFitnessStore } from "../src/db";
import { HttpError } from "../src/health-cloud";
import { tokenHash } from "../src/auth";

const servers: Server[] = [];
afterEach(async () => { await Promise.all(servers.splice(0).map(server => new Promise<void>((resolve, reject) => server.close(error => error ? reject(error) : resolve())))); });

async function fixture() {
  const store = new InMemoryFitnessStore();
  const app = createServer({ port: 0, corsOrigin: "" }, store, async token => {
    if (token === "web-a" || token === "web-b") return { ownerId: token, kind: "google" };
    const device = await store.authenticateDevice(tokenHash(token));
    if (!device) throw new HttpError(401, "Invalid device");
    return device;
  });
  const server = await new Promise<Server>(resolve => { const listening = app.listen(0, "127.0.0.1", () => resolve(listening)); });
  servers.push(server);
  const address = server.address() as { port: number };
  async function request(path: string, token?: string, method = "GET", data?: unknown) {
    return fetch(`http://127.0.0.1:${address.port}${path}`, { method,
      headers: { ...(token ? { Authorization: `Bearer ${token}` } : {}), ...(data ? { "Content-Type": "application/json" } : {}) },
      body: data ? JSON.stringify(data) : undefined });
  }
  async function pair() {
    const creation = await request("/api/pairings", "web-a", "POST");
    expect(creation.status).toBe(201);
    const { code } = await creation.json() as { code: string };
    const redemption = await request("/api/pairings/redeem", undefined, "POST", { code, sourceDeviceId: "device-a", deviceName: "Test device" });
    expect(redemption.status).toBe(201);
    return { code, ...await redemption.json() as { deviceToken: string } };
  }
  return { request, pair };
}

const consent = { version: "health-sync-v1", detailedSamples: false, workoutReviews: false };
const batch = () => ({ schemaVersion: 1, sourceDeviceId: "device-a", capturedAt: new Date().toISOString(),
  records: [{ kind: "daily", id: "today", observedAt: new Date().toISOString(), data: { steps: 9000 } }] });

describe("private Health sync boundary", () => {
  it("compresses larger dashboards while preserving private cache controls and record content", async () => {
    const { request, pair } = await fixture(), { deviceToken } = await pair();
    await request("/api/health/consent", deviceToken, "POST", consent);
    const payload = batch();
    payload.records = Array.from({length:100},(_,i)=>({ ...payload.records[0], id:`day-${i}`, data:{steps:9000+i} }));
    await request("/api/health/sync", deviceToken, "POST", payload);
    const response = await request("/api/health/dashboard?days=all", "web-a");
    expect(response.status).toBe(200);
    expect(response.headers.get("content-encoding")).toBe("gzip");
    expect(response.headers.get("cache-control")).toBe("no-store");
    expect((await response.json()).records).toHaveLength(100);
    expect((await request("/api/health/dashboard")).status).toBe(401);
  });
  it("rejects anonymous reads, one-use code replay, mismatched devices and unconsented samples", async () => {
    const { request, pair } = await fixture();
    expect((await request("/api/status/live")).status).toBe(200);
    expect((await request("/api/status/ready")).status).toBe(200);
    expect((await request("/api/health/dashboard")).status).toBe(401);
    const { code, deviceToken } = await pair();
    expect((await request("/api/pairings/redeem", undefined, "POST", { code, sourceDeviceId: "other", deviceName: "Test" })).status).toBe(400);
    expect((await request("/api/pairings", deviceToken, "POST")).status).toBe(403);
    expect((await request("/api/health/sync", deviceToken, "POST", batch())).status).toBe(403);
    expect((await request("/api/health/consent", deviceToken, "POST", consent)).status).toBe(200);
    expect((await request("/api/health/sync", deviceToken, "POST", { ...batch(), sourceDeviceId: "other" })).status).toBe(403);
    for (const record of [{ kind: "quantity", data: { value: 120 } }, { kind: "workout", data: { review: { notes: "Private note" } } }]) {
      expect((await request("/api/health/sync", deviceToken, "POST", { ...batch(), records: [{ ...record, id: "detail", observedAt: new Date().toISOString() }] })).status).toBe(403);
    }
  });

  it("isolates owners, updates idempotently, ignores stale batches and revokes device access", async () => {
    const { request, pair } = await fixture(), { deviceToken } = await pair();
    await request("/api/health/consent", deviceToken, "POST", consent);
    const payload = batch();
    expect((await request("/api/health/sync", deviceToken, "POST", payload)).status).toBe(202);
    expect((await request("/api/health/sync", deviceToken, "POST", payload)).status).toBe(202);
    const older = { ...payload, capturedAt: new Date(Date.now() - 60_000).toISOString(), records: [{ ...payload.records[0], data: { steps: 1 } }] };
    await request("/api/health/sync", deviceToken, "POST", older);
    const owner = await (await request("/api/health/dashboard?days=all", "web-a")).json();
    expect(owner.counts.daily).toBe(1); expect(owner.records[0].data.steps).toBe(9000);
    const other = await (await request("/api/health/dashboard?days=all", "web-b")).json();
    expect(other.records).toEqual([]); expect(other.consent).toBeNull();
    expect((await request("/api/health/device", "web-a", "DELETE")).status).toBe(403);
    expect((await request("/api/health/device", deviceToken, "DELETE")).status).toBe(204);
    expect((await request("/api/health/status", deviceToken)).status).toBe(401);
    expect((await (await request("/api/health/dashboard?days=all", "web-a")).json()).counts.daily).toBe(1);
  });

  it("pauses consent and deletes saved data plus all connected devices", async () => {
    const { request, pair } = await fixture(), { deviceToken } = await pair();
    await request("/api/health/consent", deviceToken, "POST", consent);
    await request("/api/health/sync", deviceToken, "POST", batch());
    expect((await request("/api/health/consent", "web-a", "DELETE")).status).toBe(204);
    expect((await request("/api/health/sync", deviceToken, "POST", batch())).status).toBe(403);
    expect((await request("/api/health/data", "web-a", "DELETE")).status).toBe(204);
    expect((await request("/api/health/status", deviceToken)).status).toBe(401);
    const cleared = await (await request("/api/health/dashboard?days=all", "web-a")).json();
    expect(cleared.records).toEqual([]); expect(cleared.counts).toEqual({});
  });
});
