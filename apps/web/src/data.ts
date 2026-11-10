import type { HealthRecord, JsonValue } from "@robur/core";
export interface Point { date: string; value: number; record: HealthRecord }
export interface Series { key: string; title: string; unit: string; color: string; points: Point[] }
export function number(value: JsonValue | undefined): number | undefined { return typeof value === "number" && Number.isFinite(value) ? value : undefined; }
export function day(record: HealthRecord): string { return typeof record.data.date === "string" ? record.data.date.slice(0,10) : record.observedAt.slice(0,10); }
export function points(records: HealthRecord[], kind: string, key: string): Point[] {
  const result = new Map<string, Point>();
  for (const record of records) {
    const value = number(record.data[key]);
    if (record.kind === kind && value !== undefined) result.set(day(record), { date: day(record), value, record });
  }
  return [...result.values()].sort((a,b) => a.date.localeCompare(b.date));
}
export function groupPoints(values: Point[], grain: "day" | "week" | "month", total = false): Point[] {
  if (grain === "day") return values;
  const groups = new Map<string, Point[]>();
  for (const point of values) {
    const date = new Date(`${point.date}T12:00:00Z`);
    if (grain === "week") date.setUTCDate(date.getUTCDate() - (date.getUTCDay() + 6) % 7);
    const key = grain === "month" ? `${point.date.slice(0,7)}-01` : date.toISOString().slice(0,10);
    const group = groups.get(key) ?? []; group.push(point); groups.set(key, group);
  }
  return [...groups].map(([date, group]) => ({ date, value: group.reduce((sum,p)=>sum+p.value,0) / (total ? 1 : group.length), record: group[group.length-1].record }));
}
export function workoutLoad(records: HealthRecord[]): Point[] {
  const groups = new Map<string, Point>();
  for (const record of records.filter(record => record.kind === "workout")) {
    const effort = number(record.data.appleEffort), minutes = number(record.data.minutes);
    if (effort === undefined || minutes === undefined) continue;
    const key = day(record), prior = groups.get(key)?.value ?? 0;
    groups.set(key, { date: key, value: prior + effort * minutes, record });
  }
  return [...groups.values()].sort((a,b) => a.date.localeCompare(b.date));
}
export function components(record?: HealthRecord, key = "components"): Record<string, JsonValue>[] {
  const value = record?.data[key];
  return Array.isArray(value) ? value.filter(item => typeof item === "object" && item !== null && !Array.isArray(item)) as Record<string, JsonValue>[] : [];
}
