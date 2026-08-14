import {
  type HealthKitSyncPayload,
  normalizeHealthKitSync,
  recommendationLabel,
  todaySnapshot
} from "@robur/core";

export interface HealthKitResponse {
  snapshot: HealthKitSyncPayload["snapshot"];
  recommendationLabel: string;
  source: "mock" | "healthkit";
}

export function buildTodayResponse(payload: HealthKitSyncPayload | null): HealthKitResponse {
  const snapshot = payload?.snapshot ?? todaySnapshot;

  return {
    snapshot,
    recommendationLabel: recommendationLabel(snapshot.recommendation),
    source: payload ? "healthkit" : "mock"
  };
}

export function parseHealthKitPayload(input: unknown): HealthKitSyncPayload {
  if (!isRecord(input)) {
    throw new Error("Payload must be a JSON object.");
  }

  if (typeof input.sourceDeviceId !== "string" || input.sourceDeviceId.trim() === "") {
    throw new Error("sourceDeviceId is required.");
  }

  if (typeof input.capturedAt !== "string" || Number.isNaN(Date.parse(input.capturedAt))) {
    throw new Error("capturedAt must be an ISO timestamp.");
  }

  if (!isRecord(input.snapshot)) {
    throw new Error("snapshot is required.");
  }

  return normalizeHealthKitSync({
    sourceDeviceId: input.sourceDeviceId,
    capturedAt: input.capturedAt,
    snapshot: input.snapshot as unknown as HealthKitSyncPayload["snapshot"]
  });
}

function isRecord(value: unknown): value is Record<string, unknown> {
  return typeof value === "object" && value !== null && !Array.isArray(value);
}
