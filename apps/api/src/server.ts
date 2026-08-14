import cors from "cors";
import express, { type Express } from "express";
import { type ApiConfig } from "./config.js";
import type { FitnessStore } from "./db.js";
import { buildTodayResponse, parseHealthKitPayload } from "./healthkit.js";
import { parsePushDeviceRegistration } from "./push.js";

export function createServer(config: ApiConfig, store: FitnessStore): Express {
  const app = express();

  app.use(cors({ origin: config.corsOrigin }));
  app.use(express.json({ limit: "256kb" }));

  app.get("/healthz", (_req, res) => {
    res.status(200).json({ ok: true, service: "robur-api" });
  });

  app.get("/readyz", async (_req, res) => {
    try {
      await store.latestSnapshot();
      res.status(200).json({ ok: true });
    } catch {
      res.status(503).json({ ok: false });
    }
  });

  app.get("/api/fitness/today", async (_req, res, next) => {
    try {
      const latest = await store.latestSnapshot();
      res.status(200).json(buildTodayResponse(latest));
    } catch (error) {
      next(error);
    }
  });

  app.post("/api/healthkit/sync", async (req, res, next) => {
    try {
      if (config.healthkitIngestToken) {
        const token = req.header("x-healthkit-token");
        if (token !== config.healthkitIngestToken) {
          res.status(401).json({ error: "Unauthorized HealthKit sync." });
          return;
        }
      }

      const payload = parseHealthKitPayload(req.body);
      await store.saveHealthKitSync(payload);
      res.status(202).json({ accepted: true, sourceDeviceId: payload.sourceDeviceId });
    } catch (error) {
      next(error);
    }
  });

  app.post("/api/push/register", async (req, res, next) => {
    try {
      const payload = parsePushDeviceRegistration(req.body);
      await store.savePushDeviceRegistration(payload);
      res.status(202).json({ accepted: true, installationId: payload.installationId });
    } catch (error) {
      next(error);
    }
  });

  app.use((error: unknown, _req: express.Request, res: express.Response, _next: express.NextFunction) => {
    const message = error instanceof Error ? error.message : "Unexpected error.";
    res.status(400).json({ error: message });
  });

  return app;
}
