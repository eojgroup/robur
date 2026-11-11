import type { HealthRecord } from "@robur/core";

/** Explicit public playground data. Never sent to the API or shown as a user's data. */
export function exampleRecords(now=new Date()):HealthRecord[] {
  const result:HealthRecord[]=[];
  for(let i=0;i<120;i++) {
    const date=new Date(Date.UTC(now.getFullYear(),now.getMonth(),now.getDate()-119+i)).toISOString().slice(0,10);
    const stress=i>=86&&i<=89?1:0,wave=Math.sin(i/7),observedAt=`${date}T12:00:00Z`;
    const recoveryParts=[
      {key:"hrv",title:"HRV",score:72+wave*8-stress*25,weight:.25},
      {key:"restingHR",title:"Resting HR",score:74-wave*4-stress*20,weight:.20},
      {key:"sleep",title:"Sleep",score:73+Math.sin(i/3)*10-stress*30,weight:.25},
      {key:"sleepDebt",title:"Recent sleep shortfall",score:82-stress*30,weight:.10},
      {key:"respiratoryRate",title:"Respiratory rate",score:72-stress*12,weight:.10},
      {key:"load",title:"Training demand",score:75-stress*35,weight:.10}
    ].map(p=>({...p,effectiveWeight:p.weight,contribution:p.score*p.weight}));
    const fitnessParts=[{key:"cardio",title:"Cardio",score:62+i*.12,weight:.35},{key:"activity",title:"Activity",score:78+wave*5,weight:.25},
      {key:"consistency",title:"Consistency",score:72+i*.1,weight:.25},{key:"strength",title:"Strength",score:70,weight:.15}].map(p=>({...p,effectiveWeight:p.weight,contribution:p.score*p.weight}));
    result.push({kind:"daily",id:`example-daily-${i}`,observedAt,data:{date,sleepMinutes:460+Math.sin(i/3)*35-stress*140,hrv:62+wave*6-stress*22,
      restingHR:54-wave*2+stress*8,respiratoryRate:14+wave*.3+stress,oxygenSaturation:98,steps:8500+Math.sin(i/5)*2000,
      exerciseMinutes:35+i%25,standMinutes:95+i%30,activeEnergyKcal:430+Math.sin(i/6)*90,vo2Max:43+i*.025,weightKg:78-i*.01}});
    result.push({kind:"score",id:`example-score-${i}`,observedAt,data:{date,methodologyVersion:"example-only",recovery:Math.round(recoveryParts.reduce((s,p)=>s+p.contribution,0)),
      fitness:Math.round(fitnessParts.reduce((s,p)=>s+p.contribution,0)),coverage:1,acuteLoad:180+Math.sin(i/9)*45+stress*160,
      chronicLoad:170+Math.sin(i/25)*20,components:recoveryParts,fitnessComponents:fitnessParts}});
    if(i%3===0||i===86)result.push({kind:"workout",id:`example-workout-${i}`,observedAt,data:{date,title:i===86?"Marathon-distance example":"Running example",activityType:"running",minutes:i===86?230:45,appleEffort:i===86?9:5,distanceKm:i===86?42.2:7.5}});
  }
  return result;
}
