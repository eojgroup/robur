import { describe, expect, it } from "vitest";
import type { HealthRecord } from "@robur/core";
import { analyticsSeries, comparePoints, contributionHistory, aggregateContributions, nearestDate, correlation, downloadableRows, interestingPeriods } from "../src/analytics";
import { day, points, workoutLoad } from "../src/data";
import { exampleRecords } from "../src/example";

const date=(i:number)=>new Date(Date.UTC(2026,0,1+i)).toISOString().slice(0,10);
const record=(kind:HealthRecord["kind"],i:number,data:HealthRecord["data"]):HealthRecord=>({kind,id:`${kind}-${i}`,observedAt:`${date(i)}T12:00:00Z`,data:{date:date(i),...data}});
const values=(count:number,fn:(i:number)=>number)=>points(Array.from({length:count},(_,i)=>record("daily",i,{hrv:fn(i)})),"daily","hrv");

describe("personal metric analytics",()=>{
  it("keeps decade-long charts bounded while retaining daily data and component totals",()=>{
    const daily=Array.from({length:3650},(_,i)=>record("score",i,{recovery:70,components:[{key:"sleep",title:"Sleep",contribution:35,effectiveWeight:.5},{key:"hrv",title:"HRV",contribution:35,effectiveWeight:.5}]}));
    const source=contributionHistory(daily,false),monthly=aggregateContributions(source,"month");
    expect(source).toHaveLength(3650);expect(monthly.length).toBeLessThanOrEqual(121);
    for(const point of monthly){expect(point.parts.reduce((s,p)=>s+p.value,0)).toBeCloseTo(point.score);expect(point.parts.reduce((s,p)=>s+p.weight,0)).toBeCloseTo(1);}
    const dates=source.map(p=>p.date);expect(nearestDate(dates,Date.parse(`${date(2000)}T12:00:00Z`))).toBe(date(2000));
    expect(nearestDate(dates,0)).toBe(dates[0]);expect(nearestDate(dates,Date.parse("2100-01-01"))).toBe(dates.at(-1));expect(nearestDate([],0)).toBeUndefined();
  });
  it("excludes the current and future readings and requires seven distinct baseline dates",()=>{
    const source=values(9,i=>i<7?10:i===7?20:1000);
    const result=comparePoints([...source,source[0]],"percent");
    expect(result).toHaveLength(2);expect(result[0]).toMatchObject({date:date(7),raw:20,baseline:10,value:100,observations:7});
    expect(result[1].baseline).toBe(11.25);
    expect(comparePoints(source.slice(0,8),"percent")[0]).toEqual(result[0]);
  });
  it("uses calendar windows, omits invalid readings and does not invent variation",()=>{
    const source=values(40,i=>i===39?20:10);
    const result=comparePoints(source,"percent").at(-1)!;
    expect(result.observations).toBe(30);expect(result.baseline).toBe(10);
    expect(comparePoints(values(8,()=>0),"percent")).toEqual([]);
    expect(comparePoints(values(8,()=>10),"zscore")[0].value).toBe(0);
    expect(comparePoints(values(8,i=>i===7?20:10),"zscore")).toEqual([]);
    expect(comparePoints(values(8,i=>i===1?NaN:10),"percent")).toEqual([]);
    expect(comparePoints([...values(7,()=>10),{...source[39],date:date(90)}],"percent")).toEqual([]);
  });
  it("pairs calendar dates at the chosen lag with no duplicate inflation",()=>{
    const a=values(20,i=>i),b=values(20,i=>i===0?99:(i-1)*2);
    const result=correlation([...a,a[0]],b,1)!;
    expect(result.n).toBe(19);expect(result.r).toBeCloseTo(1);
    expect(correlation(a.slice(0,13),b,1)).toBeUndefined();
    expect(correlation(a,values(20,()=>2),0)).toBeUndefined();
    expect(correlation(a,b,NaN)).toBeUndefined();
  });
  it("shows transparent component sums, selects many metrics, and flags long efforts and sustained shifts",()=>{
    const records=exampleRecords(new Date("2026-11-11T12:00:00Z"));
    expect(analyticsSeries(records)).toHaveLength(18);
    for(const fitness of [false,true]) for(const point of contributionHistory(records,fitness)) {
      expect(Math.abs(point.parts.reduce((s,p)=>s+p.value,0)-point.score)).toBeLessThanOrEqual(.5);
      expect(point.parts.reduce((s,p)=>s+p.weight,0)).toBeCloseTo(1);
    }
    const flags=interestingPeriods(records);
    expect(flags.some(h=>h.kind==="effort"&&h.title==="Marathon-distance example")).toBe(true);
    expect(flags.some(h=>h.kind==="signals"&&h.end>h.start)).toBe(true);
    expect(interestingPeriods([record("daily",0,{sleepMinutes:200})])).toEqual([]);
  });
  it("uses completion dates for Apple effort load, rejects missing ratings, and exports safe CSV",()=>{
    const workouts=[record("workout",0,{endDate:date(1),minutes:120,appleEffort:8}),record("workout",1,{minutes:40}),record("workout",2,{minutes:45,appleEffort:11})];
    expect(workoutLoad(workouts).map(p=>[p.date,p.value])).toEqual([[date(1),960]]);
    expect(day(record("daily",0,{date:"2026-02-30"}))).toBe(date(0));
    expect(downloadableRows([{...record("workout",0,{title:'A "quote"'}),id:"=1+2"}])).toContain('"\'=1+2"');
    expect(downloadableRows(workouts)).toContain("endDate");
  });
});
