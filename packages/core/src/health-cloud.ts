/** Versioned transport only. Scores are calculated on device, never re-scored by the web. */
export const healthConsentVersion = "health-sync-v1";
export type HealthRecordKind = "daily" | "workout" | "fitness" | "score" | "quantity" | "sleep";
export type JsonValue = string | number | boolean | null | JsonValue[] | { [key: string]: JsonValue };
export interface HealthRecord {
  kind: HealthRecordKind;
  id: string;
  observedAt: string;
  data: { [key: string]: JsonValue };
}
export interface HealthSyncBatch {
  schemaVersion: 1;
  sourceDeviceId: string;
  capturedAt: string;
  records: HealthRecord[];
  deleted?: { kind: HealthRecordKind; id: string }[];
}
export interface HealthConsent {
  version: string;
  detailedSamples: boolean;
  workoutReviews: boolean;
  grantedAt: string;
}
export interface HealthDashboard {
  records: HealthRecord[];
  counts: Partial<Record<HealthRecordKind, number>>;
  lastSyncedAt: string | null;
  consent: HealthConsent | null;
  truncated: boolean;
}
