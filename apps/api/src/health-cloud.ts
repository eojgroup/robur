import { healthConsentVersion, type HealthRecord, type HealthRecordKind, type HealthSyncBatch, type JsonValue } from "@robur/core";

const kinds = new Set<HealthRecordKind>(["daily", "workout", "fitness", "score", "quantity", "sleep"]);
export class HttpError extends Error {
  constructor(public readonly status: number, message: string) { super(message); }
}
export function object(value: unknown): value is Record<string, unknown> {
  return typeof value === "object" && value !== null && !Array.isArray(value);
}
export function text(value: unknown, label: string, max = 255): string {
  if (typeof value !== "string" || !value.trim() || value.length > max) throw new HttpError(400, `${label} is invalid.`);
  return value.trim();
}
function timestamp(value: unknown, label: string): string {
  const result = text(value, label, 40);
  if (!/^\d{4}-\d\d-\d\dT/.test(result) || !Number.isFinite(Date.parse(result))) throw new HttpError(400, `${label} must be an ISO timestamp.`);
  return new Date(result).toISOString();
}
function kind(value: unknown): HealthRecordKind {
  if (!kinds.has(value as HealthRecordKind)) throw new HttpError(400, "Unknown health record kind.");
  return value as HealthRecordKind;
}
function json(value: unknown, depth = 0): JsonValue {
  if (depth > 8) throw new HttpError(400, "Health data nesting is too deep.");
  if (value === null || typeof value === "boolean") return value;
  if (typeof value === "number" && Number.isFinite(value)) return value;
  if (typeof value === "string" && value.length <= 4000) return value;
  if (Array.isArray(value) && value.length <= 5000) return value.map(item => json(item, depth + 1));
  if (object(value) && Object.keys(value).length <= 100) {
    const result: Record<string, JsonValue> = {};
    for (const [key, item] of Object.entries(value)) {
      if (key.length > 100 || ["__proto__", "constructor", "prototype", "ownerId", "userId"].includes(key)) throw new HttpError(400, "Invalid health data key.");
      result[key] = json(item, depth + 1);
    }
    return result;
  }
  throw new HttpError(400, "Health data must contain bounded JSON values and finite numbers.");
}
function score(value: unknown) { return value === null || value === undefined || (typeof value === "number" && Number.isFinite(value) && value >= 0 && value <= 100); }
export function parseSyncBatch(input: unknown): HealthSyncBatch {
  if (!object(input) || input.schemaVersion !== 1 || !Array.isArray(input.records) || input.records.length > 500) throw new HttpError(400, "Expected schemaVersion 1 and up to 500 records.");
  if (input.deleted !== undefined && (!Array.isArray(input.deleted) || input.deleted.length > 500)) throw new HttpError(400, "Too many deleted records.");
  const records = input.records.map((item): HealthRecord => {
    if (!object(item) || !object(item.data)) throw new HttpError(400, "Invalid health record.");
    const data = json(item.data) as HealthRecord["data"];
    const record = { kind: kind(item.kind), id: text(item.id, "record id"), observedAt: timestamp(item.observedAt, "observedAt"), data };
    if (record.kind === "score") {
      text(data.methodologyVersion, "methodologyVersion", 100);
      if (!score(data.recovery) || !score(data.fitness)) throw new HttpError(400, "Scores must be missing or between 0 and 100.");
    }
    return record;
  });
  const deleted = (input.deleted as unknown[] | undefined)?.map(item => {
    if (!object(item)) throw new HttpError(400, "Invalid deleted record.");
    return { kind: kind(item.kind), id: text(item.id, "record id") };
  });
  return { schemaVersion: 1, sourceDeviceId: text(input.sourceDeviceId, "sourceDeviceId"), capturedAt: timestamp(input.capturedAt, "capturedAt"), records, deleted };
}
export function parseConsent(input: unknown) {
  if (!object(input) || input.version !== healthConsentVersion || typeof input.detailedSamples !== "boolean") throw new HttpError(400, "Review and accept the current health sync consent.");
  if (input.workoutReviews !== undefined && typeof input.workoutReviews !== "boolean") throw new HttpError(400, "workoutReviews must be a boolean.");
  return { version: healthConsentVersion, detailedSamples: input.detailedSamples, workoutReviews: input.workoutReviews === true };
}
export function containsDetailedSamples(batch: HealthSyncBatch): boolean {
  return batch.records.some(record => record.kind === "quantity" || record.kind === "sleep" ||
    ["heartRateSamples", "rawSamples", "samples"].some(key => Array.isArray(record.data[key]) && (record.data[key] as JsonValue[]).length > 0));
}

export function containsWorkoutReviews(batch: HealthSyncBatch): boolean {
  return batch.records.some(record => record.kind === "workout" && ["notes", "muscles", "muscleGroups", "quickReview", "review", "annotation"].some(key => {
    const value = record.data[key];
    return typeof value === "string" ? value.trim().length > 0 : Array.isArray(value) ? value.length > 0 : object(value) ? Object.keys(value).length > 0 : false;
  }));
}
