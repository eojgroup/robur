import cors from "cors";
import express, { type Express, type RequestHandler } from "express";
import { existsSync } from "node:fs";
import { resolve } from "node:path";
import { fileURLToPath } from "node:url";
import { type ApiConfig } from "./config.js";
import type { FitnessStore } from "./db.js";
import { createAuthenticator, type Authenticator, type Principal } from "./auth.js";
import { HttpError, object, parseConsent, parseSyncBatch, text } from "./health-cloud.js";

export function createServer(config: ApiConfig, store: FitnessStore, authenticate: Authenticator = createAuthenticator(config.googleWebClientId, store)): Express {
  const app = express();
  app.disable("x-powered-by");
  app.set("trust proxy", 1);
  if (config.corsOrigin) app.use(cors({ origin: config.corsOrigin, methods: ["GET", "POST", "DELETE"], allowedHeaders: ["Authorization", "Content-Type"] }));
  app.use((_req, res, next) => {
    res.setHeader("X-Content-Type-Options", "nosniff");
    res.setHeader("Referrer-Policy", "no-referrer");
    res.setHeader("Cache-Control", "no-store");
    res.setHeader("Content-Security-Policy", "default-src 'self'; script-src 'self' https://accounts.google.com; style-src 'self' 'unsafe-inline' https://accounts.google.com; frame-src https://accounts.google.com; connect-src 'self' https://accounts.google.com; img-src 'self' data: https://*.googleusercontent.com; object-src 'none'; base-uri 'self'; frame-ancestors 'none'");
    next();
  });
  app.use(express.json({ limit: "4mb" }));

  const buckets = new Map<string, { count: number; reset: number }>();
  function rateLimit(key: string, limit: number) {
    const now = Date.now();
    if (buckets.size > 5000) for (const [id, bucket] of buckets) if (bucket.reset <= now) buckets.delete(id);
    const bucket = buckets.get(key);
    if (!bucket || bucket.reset <= now) { buckets.set(key, { count: 1, reset: now + 60_000 }); return; }
    if (++bucket.count > limit) throw new HttpError(429, "Too many requests. Try again in a minute.");
  }
  const auth: RequestHandler = async (req, res, next) => {
    try {
      const header = req.header("authorization") ?? "";
      if (!/^Bearer \S+$/.test(header)) throw new HttpError(401, "Sign in or pair your device to continue.");
      rateLimit(`auth:${req.ip}`, 180);
      const principal = await authenticate(header.slice(7));
      rateLimit(`owner:${principal.ownerId}`, 240);
      res.locals.principal = principal;
      next();
    } catch (error) { next(error); }
  };
  const principal = (res: express.Response) => res.locals.principal as Principal;

  app.get("/healthz", (_req, res) => { res.status(200).json({ ok: true, service: "robur-api" }); });
  app.get("/readyz", async (_req, res) => {
    try { await store.ping(); res.status(200).json({ ok: true }); }
    catch { res.status(503).json({ ok: false }); }
  });
  app.get("/api/config", (_req, res) => {
    res.json({ googleWebClientId: config.googleWebClientId ?? null, consentVersion: "health-sync-v1", schemaVersion: 1 });
  });
  app.post("/api/pairings/redeem", async (req, res, next) => {
    try {
      rateLimit(`pair:${req.ip}`, 10);
      if (!object(req.body)) throw new HttpError(400, "Invalid pairing request.");
      const code = text(req.body.code, "code", 16).replace(/[-\s]/g, "").toUpperCase();
      if (!/^[A-Z2-9]{10}$/.test(code)) throw new HttpError(400, "Enter the 10-character pairing code from Robur web.");
      const result = await store.redeemPairing(code, text(req.body.sourceDeviceId, "sourceDeviceId"), text(req.body.deviceName, "deviceName", 100));
      res.status(201).json(result);
    } catch (error) { next(error); }
  });
  app.post("/api/pairings", auth, async (_req, res, next) => {
    try {
      const identity = principal(res);
      if (identity.kind !== "google") throw new HttpError(403, "Create pairing codes from your signed-in web account.");
      rateLimit(`new-pair:${identity.ownerId}`, 5);
      res.status(201).json(await store.createPairing(identity.ownerId));
    } catch (error) { next(error); }
  });
  app.get("/api/health/status", auth, async (_req, res, next) => {
    try {
      const dashboard = await store.dashboard(principal(res).ownerId, new Date().toISOString());
      res.json({ consent: dashboard.consent, counts: dashboard.counts, lastSyncedAt: dashboard.lastSyncedAt });
    } catch (error) { next(error); }
  });
  app.post("/api/health/consent", auth, async (req, res, next) => {
    try { res.json({ consent: await store.setConsent(principal(res).ownerId, parseConsent(req.body)) }); }
    catch (error) { next(error); }
  });
  app.delete("/api/health/consent", auth, async (_req, res, next) => {
    try { await store.revokeConsent(principal(res).ownerId); res.status(204).end(); }
    catch (error) { next(error); }
  });
  app.delete("/api/health/data", auth, async (_req, res, next) => {
    try { await store.deleteHealthData(principal(res).ownerId); res.status(204).end(); }
    catch (error) { next(error); }
  });
  app.post("/api/health/sync", auth, async (req, res, next) => {
    try {
      const identity = principal(res), batch = parseSyncBatch(req.body);
      if (identity.kind !== "device" || identity.sourceDeviceId !== batch.sourceDeviceId) throw new HttpError(403, "This device token cannot upload for another device.");
      if (Date.parse(batch.capturedAt) > Date.now() + 5 * 60_000) throw new HttpError(400, "Device capture time is in the future. Check your clock.");
      await store.saveBatch(identity.ownerId, batch);
      res.status(202).json({ accepted: true, records: batch.records.length, deleted: batch.deleted?.length ?? 0 });
    } catch (error) { next(error); }
  });
  app.get("/api/health/dashboard", auth, async (req, res, next) => {
    try {
      const days = req.query.days ?? "90";
      if (!["30", "90", "365", "all"].includes(days as string)) throw new HttpError(400, "Choose 30, 90, 365 or all days.");
      const since = days === "all" ? new Date(0) : new Date(Date.now() - Number(days) * 86_400_000);
      res.json(await store.dashboard(principal(res).ownerId, since.toISOString()));
    } catch (error) { next(error); }
  });
  // Retire the public/shared-secret demo endpoints rather than exposing legacy unowned data.
  app.all(["/api/fitness/today", "/api/healthkit/sync", "/api/push/register"], (_req, res) => {
    res.status(410).json({ error: "This demo endpoint is retired. Use authenticated, consented health sync." });
  });
  app.use("/api", (_req, res) => { res.status(404).json({ error: "API route not found." }); });

  const webRoot = resolve(config.webRoot ?? fileURLToPath(new URL("../../web/dist", import.meta.url)));
  if (existsSync(resolve(webRoot, "index.html"))) {
    app.use(express.static(webRoot));
    app.get("*", (_req, res) => { res.sendFile(resolve(webRoot, "index.html")); });
  }
  app.use((error: unknown, _req: express.Request, res: express.Response, _next: express.NextFunction) => {
    const status = error instanceof HttpError ? error.status : object(error) && error.type === "entity.too.large" ? 413 : object(error) && error.type === "entity.parse.failed" ? 400 : 500;
    // SQL/credentials and uploaded payloads are never returned or logged.
    res.status(status).json({ error: error instanceof HttpError ? error.message : status === 413 ? "Upload is larger than 4 MiB. Use smaller batches." : status === 400 ? "Invalid JSON body." : "Request failed. Please retry later." });
  });
  return app;
}
