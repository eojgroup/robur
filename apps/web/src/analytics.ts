import { metricColor, type HealthRecord, type JsonValue } from "@robur/core";
import { components, day, number, points, workoutLoad, type Point, type Series } from "./data";

export interface Highlight { id: string; start: string; end: string; title: string; detail: string; kind: "effort" | "recovery" | "signals" | "coverage" }
export interface ComparedPoint extends Point { raw: number; baseline: number; observations: number }
export const metricSpecs = [
  ["score", "recovery", "Recovery", "/100"], ["score", "fitness", "Fitness", "/100"],
  ["score", "acuteLoad", "Acute load · 7d", "AU/day"], ["score", "chronicLoad", "Chronic load · 42d", "AU/day"],
  ["daily", "sleepMinutes", "Sleep", "min"], ["daily", "hrv", "HRV · SDNN", "ms"],
  ["daily", "restingHR", "Resting heart rate", "bpm"], ["daily", "respiratoryRate", "Respiratory rate", "breaths/min"],
  ["daily", "oxygenSaturation", "Blood oxygen", "%"], ["daily", "steps", "Steps", "steps"],
  ["daily", "exerciseMinutes", "Exercise", "min"], ["daily", "standMinutes", "Stand time", "min"],
  ["daily", "activeEnergyKcal", "Active energy", "kcal"], ["daily", "vo2Max", "VO₂ max", "mL/kg/min"],
  ["daily", "weightKg", "Weight", "kg"], ["daily", "bodyFatPercent", "Body fat", "%"],
  ["daily", "bmi", "BMI", "kg/m²"], ["workout", "sessionLoad", "Workout effort load", "AU"]
] as const;

export function analyticsSeries(records: HealthRecord[]): Series[] {
  return metricSpecs.map(([kind, key, title, unit]) => ({ key, title, unit, color: metricColor(key),
    points: key === "sessionLoad" ? workoutLoad(records) : points(records, kind, key) }));
}
const timestamp = (date: string) => Date.parse(`${date}T12:00:00Z`);
const dateAfter = (date: string, days: number) => new Date(timestamp(date) + days * 86400000).toISOString().slice(0,10);

/** Compare only with observed values in the prior 30 calendar days, excluding today. */
export function comparePoints(values: Point[], mode: "percent" | "zscore"): ComparedPoint[] {
  const sorted = [...new Map(values.filter(p=>Number.isFinite(p.value)).map(p=>[p.date,p])).values()].sort((a,b) => a.date.localeCompare(b.date));
  const result: ComparedPoint[]=[];
  let start=0,sum=0,squared=0;
  for (let i=0;i<sorted.length;i++) {
    const point=sorted[i];
    while(start<i && timestamp(sorted[start].date)<timestamp(point.date)-30*86400000) {
      sum-=sorted[start].value;squared-=sorted[start].value**2;start++;
    }
    const count=i-start,baseline=count ? sum/count : 0;
    const variance=count ? Math.max(0,squared/count-baseline**2) : 0;
    const stableVariance=variance>Number.EPSILON*Math.max(1,baseline**2)*32;
    const value = mode === "percent" ? baseline !== 0 ? (point.value/baseline-1)*100 : undefined
      : stableVariance ? (point.value-baseline)/Math.sqrt(variance) : Math.abs(point.value-baseline)<1e-9?0:undefined;
    if(count>=7 && value!==undefined && Number.isFinite(value)) result.push({...point,value,raw:point.value,baseline,observations:count});
    sum+=point.value;squared+=point.value**2;
  }
  return result;
}

export function correlation(a: Point[], b: Point[], lagDays = 0): { r: number; n: number } | undefined {
  const other = new Map(b.map(point => [point.date,point.value]));
  if(!Number.isInteger(lagDays)||Math.abs(lagDays)>30)return undefined;
  const pairs = [...new Map(a.map(p=>[p.date,p])).values()].flatMap(point => {
    const value = other.get(dateAfter(point.date,lagDays));
    return value === undefined || !Number.isFinite(point.value) || !Number.isFinite(value) ? [] : [[point.value,value]];
  });
  if (pairs.length < 14) return undefined;
  const meanA = pairs.reduce((s,p)=>s+p[0],0)/pairs.length, meanB = pairs.reduce((s,p)=>s+p[1],0)/pairs.length;
  const ssA = pairs.reduce((s,p)=>s+(p[0]-meanA)**2,0), ssB = pairs.reduce((s,p)=>s+(p[1]-meanB)**2,0);
  if (!ssA || !ssB) return undefined;
  return { r: Math.max(-1,Math.min(1,pairs.reduce((s,p)=>s+(p[0]-meanA)*(p[1]-meanB),0)/Math.sqrt(ssA*ssB))), n: pairs.length };
}

export function contributionHistory(records: HealthRecord[], fitness: boolean) {
  return records.filter(r=>r.kind==="score" && number(r.data[fitness ? "fitness" : "recovery"]) !== undefined)
    .sort((a,b)=>a.observedAt.localeCompare(b.observedAt)).map(record => ({ date: day(record), record,
      score: number(record.data[fitness ? "fitness" : "recovery"])!,
      parts: components(record,fitness ? "fitnessComponents" : "components").flatMap(part => {
        const value = number(part.contribution);
        return typeof part.key === "string" && typeof part.title === "string" && value !== undefined && value >= 0
          ? [{ key: part.key, title: part.title, value, weight: number(part.effectiveWeight) ?? 0 }] : [];
      }) }));
}

/** Bound SVG marks for long histories; daily source records stay unchanged. */
export function aggregateContributions(values: ReturnType<typeof contributionHistory>, period: "day"|"week"|"month") {
  if(period==="day")return values;
  const groups=new Map<string,typeof values>();
  for(const point of values){
    const date=new Date(`${point.date}T12:00:00Z`);
    if(period==="week")date.setUTCDate(date.getUTCDate()-(date.getUTCDay()+6)%7);
    const key=period==="month"?`${point.date.slice(0,7)}-01`:date.toISOString().slice(0,10);
    const bucket=groups.get(key)??[];bucket.push(point);groups.set(key,bucket);
  }
  return [...groups].sort(([a],[b])=>a.localeCompare(b)).map(([date,bucket])=>{
    const parts=new Map<string,typeof values[number]["parts"][number]>();
    for(const point of bucket)for(const part of point.parts){
      const prior=parts.get(part.key);
      parts.set(part.key,{...part,value:(prior?.value??0)+part.value/bucket.length,weight:(prior?.weight??0)+part.weight/bucket.length});
    }
    return {date,record:bucket[bucket.length-1].record,score:bucket.reduce((s,p)=>s+p.score,0)/bucket.length,parts:[...parts.values()]};
  });
}

/** Binary lookup keeps pointer inspection independent of total history length. */
export function nearestDate(dates:string[],target:number):string|undefined {
  if(!dates.length||!Number.isFinite(target))return undefined;
  let low=0,high=dates.length;
  while(low<high){const mid=(low+high)>>>1;if(timestamp(dates[mid])<target)low=mid+1;else high=mid;}
  if(low===0)return dates[0];if(low===dates.length)return dates[dates.length-1];
  return target-timestamp(dates[low-1])<=timestamp(dates[low])-target?dates[low-1]:dates[low];
}

export function interestingPeriods(records: HealthRecord[]): Highlight[] {
  const result: Highlight[] = [];
  const recovery = comparePoints(points(records,"score","recovery"),"percent");
  for (const point of recovery) if (point.raw <= point.baseline-15) result.push({ id: `recovery-${point.date}`,start:point.date,end:point.date,
    kind:"recovery",title:"Recovery below recent baseline",detail:`${point.raw.toFixed(0)}/100 versus ${point.baseline.toFixed(0)} across ${point.observations} prior recorded dates. At least 15 points lower; a descriptive Robur highlight.` });
  const deviations = ["sleepMinutes","hrv","restingHR"].map(key => new Map(comparePoints(points(records,"daily",key),"percent").map(p=>[p.date,p])));
  const dates = new Set(deviations.flatMap(values=>[...values.keys()]));
  for (const date of dates) {
    const changes = deviations.map(values=>values.get(date));
    const flags = [changes[0] && changes[0].value <= -20 ? "sleep ≥20% lower" : undefined,
      changes[1] && changes[1].value <= -20 ? "HRV ≥20% lower" : undefined,
      changes[2] && changes[2].value >= 10 ? "resting HR ≥10% higher" : undefined].filter(Boolean);
    if (flags.length >= 2) result.push({id:`signals-${date}`,start:date,end:date,kind:"signals",title:"Several recovery signals shifted",detail:`${flags.join("; ")}, compared with the preceding 30-day observed baseline. These readings can have many causes.`});
  }
  for (const record of records.filter(r=>r.kind==="workout")) {
    const minutes = number(record.data.minutes) ?? 0, effort = number(record.data.appleEffort), km = number(record.data.distanceKm);
    if (minutes >= 120 || (effort ?? 0) >= 8 || (record.data.activityType === "running" && (km ?? 0) >= 42.195)) {
      const date = day(record);
      result.push({id:`effort-${record.id}`,start:date,end:date,kind:"effort",title:String(record.data.title??"Large session"),
        detail:`${minutes.toFixed(0)} minutes${effort === undefined ? "" : ` · Apple effort ${effort.toFixed(1)}/10`}${km === undefined ? "" : ` · ${km.toFixed(1)} km`}. Marked for duration ≥120 min, effort ≥8, or a marathon-distance run.`});
    }
  }
  for (const record of records.filter(r=>r.kind==="score" && (number(r.data.coverage) ?? 1) < .5)) {
    const date=day(record);result.push({id:`coverage-${date}`,start:date,end:date,kind:"coverage",title:"Limited recovery data",detail:`${((number(record.data.coverage)??0)*100).toFixed(0)}% of configured input weights are available. Missing data does not imply poor recovery.`});
  }
  const merged: Highlight[] = [];
  for (const item of result.sort((a,b)=>a.kind.localeCompare(b.kind)||a.start.localeCompare(b.start))) {
    const prior=merged.at(-1);
    if (item.kind !== "effort" && prior?.kind === item.kind && item.start === dateAfter(prior.end,1)) {
      prior.end=item.end;prior.detail=`Consecutive dates with this pattern. Latest: ${item.detail}`;
    } else merged.push({...item});
  }
  return merged.sort((a,b)=>b.end.localeCompare(a.end));
}

export function scoreVersions(records: HealthRecord[]): string[] {
  return [...new Set(records.filter(r=>r.kind==="score").map(r=>r.data.methodologyVersion).filter((v):v is string=>typeof v==="string"))]
    .sort((a,b)=>b.localeCompare(a,undefined,{numeric:true}));
}

export function downloadableRows(records: HealthRecord[]): string {
  const escape=(value: JsonValue | undefined) => {let text=value===undefined?"":typeof value==="object"?JSON.stringify(value):String(value);if(/^[=+@\-\t\r]/.test(text))text=`'${text}`;return `"${text.replaceAll('"','""')}"`;};
  return ["kind,id,observedAt,data",...records.map(record=>[record.kind,record.id,record.observedAt,record.data].map(escape).join(","))].join("\n");
}
