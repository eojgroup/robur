import { useMemo, useState } from "react";
import type { HealthRecord } from "@robur/core";
import { analyticsSeries, comparePoints, contributionHistory, correlation, downloadableRows, interestingPeriods, scoreVersions, type Highlight } from "./analytics";
import { groupPoints, type Point } from "./data";

const colors=["#e28c50","#65aaba","#bca16c","#ad92d1","#8cbe9d","#dc90a0"];
type Mode="overlay"|"components"|"relationship";
const dateTime=(date:string)=>Date.parse(`${date}T12:00:00Z`);
const format=(n:number|undefined,digits=1)=>n===undefined?"—":n.toLocaleString(undefined,{maximumFractionDigits:digits});

export function AnalyticsWorkspace({records,selectedDate,onSelect,grain="day"}: {records:HealthRecord[];selectedDate?:string;onSelect(date:string):void;grain?:"day"|"week"|"month"}) {
  const versions=useMemo(()=>scoreVersions(records),[records]);
  const [version,setVersion]=useState("");
  const activeVersion=versions.includes(version)?version:versions[0];
  const filtered=useMemo(()=>records.filter(r=>r.kind!=="score"||r.data.methodologyVersion===activeVersion),[records,activeVersion]);
  const metrics=useMemo(()=>analyticsSeries(filtered),[filtered]);
  const [keys,setKeys]=useState(["recovery","acuteLoad","hrv","sleepMinutes"]);
  const [mode,setMode]=useState<Mode>("overlay");
  const [normalization,setNormalization]=useState<"percent"|"zscore"|"raw">("percent");
  const [fitness,setFitness]=useState(false);
  const [mark,setMark]=useState(true);
  const [xKey,setXKey]=useState("acuteLoad"),[yKey,setYKey]=useState("recovery"),[lag,setLag]=useState(1);
  const chosen=useMemo(()=>keys.flatMap(key=>{const metric=metrics.find(s=>s.key===key);return metric?[metric]:[];}).map((s,i)=>({...s,color:colors[i%colors.length]})),[keys,metrics]);
  const rawAllowed=new Set(chosen.map(s=>s.unit)).size<=1;
  const sharedScale=normalization==="raw"&&!rawAllowed?"percent":normalization;
  const longest=Math.max(0,...chosen.map(s=>s.points.length));
  const period=grain==="day"&&longest>900?(longest>3000?"month":"week"):grain;
  const overlays=useMemo(()=>chosen.map(series=>({...series,points:groupPoints(sharedScale==="raw"?series.points:comparePoints(series.points,sharedScale),period)})),[chosen,sharedScale,period]);
  const highlights=useMemo(()=>interestingPeriods(filtered),[filtered]);
  const contributions=useMemo(()=>contributionHistory(filtered,fitness),[filtered,fitness]);
  const plotDates=[...new Set([...chosen.flatMap(s=>s.points.map(p=>p.date)),...contributions.map(p=>p.date)])].sort();
  const selected=selectedDate??plotDates.at(-1);
  const xMetric=metrics.find(s=>s.key===xKey),yMetric=metrics.find(s=>s.key===yKey);
  const relationship=useMemo(()=>correlation(xMetric?.points??[],yMetric?.points??[],lag),[xMetric,yMetric,lag]);
  const activeHighlights=highlights.filter(h=>selected!==undefined&&h.start<=selected&&h.end>=selected);
  function toggle(key:string){setKeys(current=>current.includes(key)?current.filter(k=>k!==key):current.length<6?[...current,key]:current);}
  function download(){const url=URL.createObjectURL(new Blob([downloadableRows(filtered)],{type:"text/csv;charset=utf-8"}));const a=document.createElement("a");a.href=url;a.download="robur-health-history.csv";a.click();URL.revokeObjectURL(url);}

  return <section className="analyticsWorkspace" aria-label="Metric analytics">
    <div className="analyticsToolbar"><div className="segmented" aria-label="Analysis mode">
      {([["overlay","Metric overlays"],["components","Score components"],["relationship","Relationships"]] as const).map(([value,label])=><button key={value} aria-pressed={mode===value} onClick={()=>setMode(value)}>{label}</button>)}
    </div><button onClick={download} disabled={!filtered.length}>Export recorded data · CSV</button></div>
    {versions.length>0&&<label className="versionPicker">Scoring version<select value={activeVersion} onChange={e=>setVersion(e.target.value)}>{versions.map(v=><option key={v}>{v}</option>)}</select><span>Versions are viewed separately.</span></label>}
    {mode==="overlay"&&<>
      <div className="metricChips" aria-label="Choose up to six metrics">{metrics.map(metric=><button key={metric.key} aria-pressed={keys.includes(metric.key)} disabled={!keys.includes(metric.key)&&keys.length>=6} onClick={()=>toggle(metric.key)}>{keys.includes(metric.key)?"✓ ":""}{metric.title}</button>)}</div>
      <div className="analyticsToolbar"><label>Shared scale<select value={sharedScale} onChange={e=>setNormalization(e.target.value as typeof normalization)}><option value="percent">% change from personal baseline</option><option value="zscore">Standard deviations from baseline</option>{rawAllowed&&<option value="raw">Raw units</option>}</select></label><label className="checkRow"><input type="checkbox" checked={mark} onChange={e=>setMark(e.target.checked)}/>Highlight notable periods</label></div>
      <p className="chartFootnote">{sharedScale==="raw"?"Raw readings share the same unit. Missing observations stay empty.":"Every metric uses its own preceding 30-day baseline, with at least 7 observed dates. Today is excluded from its baseline. Raw values and units appear below; missing dates stay empty."} {period!==grain?`Long history uses ${period}ly means for performance. `:""}No units are mixed on the shared axis.</p>
      <div className="analyticsChart"><OverlayPlot series={overlays} highlights={mark?highlights:[]} dates={plotDates} selected={selected} onSelect={onSelect} unit={sharedScale==="raw"?chosen[0]?.unit??"":sharedScale==="percent"?"% from baseline":"standard deviations"} period={period}/></div>
      <div className="metricReadings">{chosen.map(series=>{const raw=series.points.find(p=>p.date===selected);const normalized=sharedScale==="raw"?undefined:comparePoints(series.points,sharedScale).find(p=>p.date===selected);return <div key={series.key}><span><i style={{background:series.color}}/>{series.title}</span><strong>{format(raw?.value)} <small>{series.unit}</small></strong><small>{normalized?`${format(normalized.value)} ${sharedScale==="percent"?"%":"SD"} · baseline ${format(normalized.baseline)} ${series.unit} · n=${normalized.observations}`:sharedScale==="raw"?"Recorded daily reading":"More baseline data needed / no reading"}</small></div>;})}</div>
    </>}
    {mode==="components"&&<>
      <div className="analyticsToolbar"><label>Score<select value={fitness?"fitness":"recovery"} onChange={e=>setFitness(e.target.value==="fitness")}><option value="recovery">Recovery & readiness</option><option value="fitness">Fitness progress</option></select></label><label className="checkRow"><input type="checkbox" checked={mark} onChange={e=>setMark(e.target.checked)}/>Highlight notable periods</label></div>
      <ContributionPlot points={contributions} highlights={mark?highlights:[]} selected={selected} onSelect={onSelect}/>
      <div className="metricReadings">{contributions.find(p=>p.date===selected)?.parts.map(part=><div key={part.key}><span>{part.title}</span><strong>{format(part.value)} <small>points</small></strong><small>{format(part.weight*100,0)}% effective weight</small></div>)}</div>
      <p className="chartFootnote">Stacked point contributions add up to the overall score, allowing rounding of ±0.5. Effective weights can change when inputs are missing. Only dates with an eligible overall score are drawn; this view uses daily records.</p>
    </>}
    {mode==="relationship"&&<>
      <div className="relationshipControls"><label>Metric A<select value={xKey} onChange={e=>setXKey(e.target.value)}>{metrics.map(s=><option key={s.key} value={s.key}>{s.title}</option>)}</select></label><label>Metric B<select value={yKey} onChange={e=>setYKey(e.target.value)}>{metrics.map(s=><option key={s.key} value={s.key}>{s.title}</option>)}</select></label><label>Compare B<select value={lag} onChange={e=>setLag(Number(e.target.value))}>{[0,1,2,3,7].map(d=><option key={d} value={d}>{d===0?"Same day":`${d} day${d>1?"s":""} later`}</option>)}</select></label></div>
      <div className="relationshipSummary"><strong>{relationship?`r = ${relationship.r.toFixed(2)}`:"Not enough paired data"}</strong><span>{relationship?`${relationship.n} paired dates · Pearson correlation`:"At least 14 paired observed dates with variation in both metrics are needed."}</span></div>
      <ScatterPlot a={xMetric?.points??[]} b={yMetric?.points??[]} lag={lag} onSelect={onSelect} aTitle={`${xMetric?.title} (${xMetric?.unit})`} bTitle={`${yMetric?.title} (${yMetric?.unit})`}/>
      <p className="chartFootnote">A on the selected date is paired with B {lag?`${lag} days later`:"on the same date"}. Only observed pairs are used. Correlation does not establish cause; timing, training mix, illness, missing readings and measurement conditions can affect it.</p>
    </>}
    <div className="analyticsInspection"><label>Inspect date<input type="date" value={selected??""} onChange={e=>onSelect(e.target.value)}/></label><span>{selected??"Select a recorded date"} · raw daily readings</span></div>
    {activeHighlights.map(item=><p className="activeHighlight" key={item.id}><strong>{item.title}</strong> — {item.detail}</p>)}
    <details className="highlightList" open={highlights.length>0&&highlights.length<4}><summary>{highlights.length} notable periods · descriptive flags, not diagnoses</summary>
      {highlights.slice(0,100).map(item=><button key={item.id} onClick={()=>onSelect(item.start)}><span className={`highlightDot ${item.kind}`}/><span><strong>{item.title}</strong><small>{item.start}{item.end!==item.start?` – ${item.end}`:""} · {item.detail}</small></span></button>)}
      {!highlights.length&&<p className="muted">Large efforts, shifts from personal baselines and coverage changes appear when enough observations are available.</p>}
    </details>
  </section>;
}

const bandColors={effort:"#df9355",recovery:"#c77883",signals:"#71aaba",coverage:"#939ba5"};
function Bands({items,x,height,left,right}:{items:Highlight[];x(date:string):number;height:number;left:number;right:number}) {
  return <>{items.map(h=>{const a=Math.max(left,x(h.start)),b=Math.min(right,x(new Date(dateTime(h.end)+86400000).toISOString().slice(0,10)));return b<=a?null:<rect key={h.id} x={a} y={16} width={Math.max(2,b-a)} height={height-56} fill={bandColors[h.kind]} opacity={.12}><title>{h.title}: {h.start} – {h.end}</title></rect>;})}</>;
}
function OverlayPlot({series,highlights,dates,selected,onSelect,unit,period}:{series:{key:string;title:string;color:string;points:Point[]}[];highlights:Highlight[];dates:string[];selected?:string;onSelect(date:string):void;unit:string;period:string}) {
  const width=1000,height=370,left=65,right=970,top=20,bottom=325;
  const from=dateTime(dates[0]??"2000-01-01"),to=Math.max(from+86400000,dateTime(dates.at(-1)??"2000-01-02"));
  const values=series.flatMap(s=>s.points.map(p=>p.value)),low=Math.min(0,...values),high=Math.max(1,...values),padding=(high-low)*.1;
  const x=(date:string)=>left+(dateTime(date)-from)/(to-from)*(right-left),y=(value:number)=>top+(high+padding-value)/(high-low+2*padding)*(bottom-top);
  const selectAt=(event:React.PointerEvent<SVGSVGElement>)=>{const box=event.currentTarget.getBoundingClientRect(),pos=(event.clientX-box.left)/box.width*width;const target=from+(pos-left)/(right-left)*(to-from);const nearest=dates.reduce((prior,date)=>Math.abs(dateTime(date)-target)<Math.abs(dateTime(prior)-target)?date:prior,dates[0]);if(nearest)onSelect(nearest);};
  if(!values.length)return <div className="chartEmpty">Choose metrics and upload enough observed history to establish their baselines.</div>;
  return <svg viewBox={`0 0 ${width} ${height}`} className="overlayPlot" role="img" aria-label={`Metric overlays, ${unit}. Inspect a date below for raw readings.`} onPointerMove={selectAt} onClick={selectAt}>
    <Bands items={highlights} x={x} height={height} left={left} right={right}/>
    {[low,0,high].filter((value,i,array)=>array.indexOf(value)===i).map(value=><g key={value}><line x1={left} x2={right} y1={y(value)} y2={y(value)} className="gridLine"/><text x={left-8} y={y(value)+4} textAnchor="end" className="axisLabel">{format(value)}</text></g>)}
    {series.map((item,index)=>{let previous:Point|undefined;const limit=period==="month"?40:period==="week"?9:2;const path=item.points.map(p=>{const command=previous&&(dateTime(p.date)-dateTime(previous.date))/86400000<=limit?"L":"M";previous=p;return `${command}${x(p.date)},${y(p.value)}`;}).join(" ");return <path key={item.key} d={path} fill="none" stroke={item.color} strokeWidth={2.5} strokeDasharray={index>3?"6 3":undefined}><title>{item.title}</title></path>;})}
    {series.flatMap(item=>item.points.length<500?item.points.map(point=><circle key={`${item.key}-${point.date}`} cx={x(point.date)} cy={y(point.value)} r={2.2} fill={item.color}><title>{item.title}: {format(point.value)} {unit} · {point.date}</title></circle>):[])}
    {selected&&<line x1={x(selected)} x2={x(selected)} y1={top} y2={bottom} className="inspectionLine"/>}
    <text x={left} y={height-9} className="axisLabel">{dates[0]}</text><text x={right} y={height-9} className="axisLabel" textAnchor="end">{dates.at(-1)}</text><text x={left} y={13} className="axisLabel">{unit}</text>
  </svg>;
}

function ContributionPlot({points,highlights,selected,onSelect}:{points:ReturnType<typeof contributionHistory>;highlights:Highlight[];selected?:string;onSelect(date:string):void}) {
  const width=1000,height=360,left=55,right=975,top=20,bottom=315;
  const from=dateTime(points[0]?.date??"2000-01-01"),to=Math.max(from+86400000,dateTime(points.at(-1)?.date??"2000-01-02"));
  const x=(date:string)=>left+(dateTime(date)-from)/(to-from)*(right-left),y=(value:number)=>bottom-value/100*(bottom-top);
  const keys=[...new Set(points.flatMap(p=>p.parts.map(part=>part.key)))],barWidth=Math.max(.7,Math.min(18,(right-left)/Math.max(1,points.length)*.8));
  if(!points.length)return <div className="chartEmpty">No eligible score components uploaded for this range.</div>;
  return <><svg viewBox={`0 0 ${width} ${height}`} className="overlayPlot" role="img" aria-label="Daily score component contributions, 0 to 100 points">
    <Bands items={highlights} x={x} height={height} left={left} right={right}/>
    {[0,25,50,75,100].map(value=><g key={value}><line x1={left} x2={right} y1={y(value)} y2={y(value)} className="gridLine"/><text x={left-8} y={y(value)+4} textAnchor="end" className="axisLabel">{value}</text></g>)}
    {points.map(point=>{let sum=0;return <g key={point.date} onClick={()=>onSelect(point.date)}>{point.parts.map(part=>{const before=sum;sum+=part.value;return <rect key={part.key} x={x(point.date)-barWidth/2} y={y(sum)} width={barWidth} height={Math.max(0,y(before)-y(sum))} fill={colors[keys.indexOf(part.key)%colors.length]} opacity={selected===point.date?1:.8}><title>{point.date} · {part.title}: {format(part.value)} points · {format(part.weight*100,0)}% effective weight</title></rect>;})}</g>;})}
    <path d={points.map((p,i)=>`${i&&dateTime(p.date)-dateTime(points[i-1].date)<=2*86400000?"L":"M"}${x(p.date)},${y(p.score)}`).join(" ")} fill="none" className="scoreOutline"/>
    <text x={left} y={height-8} className="axisLabel">{points[0]?.date}</text><text x={right} y={height-8} textAnchor="end" className="axisLabel">{points.at(-1)?.date}</text>
  </svg><div className="componentLegend">{keys.map((key,index)=><span key={key}><i style={{background:colors[index%colors.length]}}/>{points.flatMap(p=>p.parts).find(p=>p.key===key)?.title}</span>)}</div></>;
}

function ScatterPlot({a,b,lag,onSelect,aTitle,bTitle}:{a:Point[];b:Point[];lag:number;onSelect(date:string):void;aTitle:string;bTitle:string}) {
  const map=new Map(b.map(p=>[p.date,p.value]));const pairs=a.flatMap(p=>{const value=map.get(new Date(dateTime(p.date)+lag*86400000).toISOString().slice(0,10));return value===undefined?[]:[{...p,other:value}];});
  if(!pairs.length)return <div className="chartEmpty">No overlapping observations for this metric pair and lag.</div>;
  const minA=Math.min(...pairs.map(p=>p.value)),maxA=Math.max(minA+1,...pairs.map(p=>p.value));
  const minB=Math.min(...pairs.map(p=>p.other)),maxB=Math.max(minB+1,...pairs.map(p=>p.other));
  return <svg viewBox="0 0 1000 370" className="overlayPlot" role="img" aria-label={`${aTitle} versus ${bTitle}, ${pairs.length} observed pairs`}>
    {pairs.map(p=><circle key={p.date} cx={80+(p.value-minA)/(maxA-minA)*850} cy={310-(p.other-minB)/(maxB-minB)*270} r={4} fill={colors[0]} opacity={.7} onClick={()=>onSelect(p.date)}><title>{p.date}: {format(p.value)}, {format(p.other)}</title></circle>)}
    <text x={500} y={355} textAnchor="middle" className="axisLabel">{aTitle}</text><text x={18} y={185} transform="rotate(-90 18 185)" textAnchor="middle" className="axisLabel">{bTitle}</text>
    <text x={80} y={330} className="axisLabel">{format(minA)}</text><text x={930} y={330} textAnchor="end" className="axisLabel">{format(maxA)}</text><text x={70} y={310} textAnchor="end" className="axisLabel">{format(minB)}</text><text x={70} y={40} textAnchor="end" className="axisLabel">{format(maxB)}</text>
  </svg>;
}
