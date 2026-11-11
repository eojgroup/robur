import { useEffect, useMemo, useRef, useState } from "react";
import { Activity, ArrowLeft, CalendarDays, ChevronRight, CloudUpload, HeartPulse, Link2, LockKeyhole, LogOut, RefreshCw, ShieldCheck, Trash2 } from "lucide-react";
import { metricColor, healthConsentVersion, type HealthDashboard, type HealthRecord } from "@robur/core";
import { AnalyticsWorkspace } from "./AnalyticsWorkspace";
import { exampleRecords } from "./example";
import { components, day, groupPoints, number, points, workoutLoad, type Point, type Series } from "./data";

interface GoogleAPI { accounts: { id: { initialize(config: { client_id: string; callback(response: { credential: string }): void }): void; renderButton(element: HTMLElement, config: Record<string, unknown>): void; disableAutoSelect(): void } } }
declare global { interface Window { google?: GoogleAPI } }
const apiBase = (import.meta.env.VITE_API_BASE_URL as string | undefined) ?? "";
const colors = ["#e47935", "#6d9eab", "#c4ab79", "#9a85b6"];

async function request<T>(path: string, token?: string, options: RequestInit = {}): Promise<T> {
  const response = await fetch(`${apiBase}${path}`, { ...options, credentials: "omit", referrerPolicy: "no-referrer", headers: {
    ...(options.body ? { "Content-Type": "application/json" } : {}), ...(token ? { Authorization: `Bearer ${token}` } : {}), ...options.headers
  } });
  if (!response.ok) {
    const payload = await response.json().catch(() => ({})) as { error?: string };
    throw new Error(payload.error ?? "Could not connect to Robur. Please retry.");
  }
  return response.status === 204 ? undefined as T : await response.json() as T;
}

function Brand() { return <a className="brand" href="/"><span className="brandMark"><Activity size={27} strokeWidth={2.1} /></span><span>Robur<span className="brandSub">Health & training</span></span></a>; }
function GoogleSignIn({ clientId, onToken }: { clientId: string; onToken(token: string): void }) {
  const element = useRef<HTMLDivElement>(null);
  const [error, setError] = useState<string>();
  useEffect(() => {
    let active = true;
    function initialize() {
      if (!active || !window.google || !element.current) return;
      window.google.accounts.id.initialize({ client_id: clientId, callback: result => onToken(result.credential) });
      window.google.accounts.id.renderButton(element.current, { theme: "outline", size: "large", text: "signin_with", shape: "pill", width: 260 });
    }
    if (window.google) initialize();
    else {
      let script = document.querySelector<HTMLScriptElement>("script[data-google-identity]");
      if (!script) {
        script = document.createElement("script"); script.src = "https://accounts.google.com/gsi/client"; script.async = true; script.dataset.googleIdentity = "true"; document.head.append(script);
      }
      script.addEventListener("load", initialize);
      script.addEventListener("error", () => setError("Google sign-in could not load. Check your connection and try again."));
    }
    return () => { active = false; };
  }, [clientId, onToken]);
  return <><div ref={element} className="googleSignIn" />{error && <p role="alert">{error}</p>}</>;
}

function App() {
  const [token, setToken] = useState<string>();
  const [example, setExample] = useState(false);
  const demonstration=useMemo(()=>exampleRecords(),[]);
  const [config, setConfig] = useState<{ googleWebClientId: string | null }>();
  const [dashboard, setDashboard] = useState<HealthDashboard>();
  const [days, setDays] = useState("90");
  const [view, setView] = useState("recovery");
  const [grain, setGrain] = useState<"day" | "week" | "month">("day");
  const [chartStyle, setChartStyle] = useState<"line" | "bar">("line");
  const [selectedDate, setSelectedDate] = useState<string>();
  const [error, setError] = useState<string>();
  const [loading, setLoading] = useState(false);
  const [busy, setBusy] = useState(false);
  const [refresh, setRefresh] = useState(0);
  const [pairing, setPairing] = useState<{ code: string; expiresAt: string }>();
  const [showSettings, setShowSettings] = useState(false);
  const [deleteText, setDeleteText] = useState("");
  const [deleting, setDeleting] = useState(false);
  const [detailed, setDetailed] = useState(false);
  const [reviews, setReviews] = useState(false);
  const isPrivacy = window.location.pathname === "/privacy";
  useEffect(() => { if (!isPrivacy) void request<{ googleWebClientId: string | null }>("/api/config").then(setConfig).catch(e => setError((e as Error).message)); }, [isPrivacy]);
  useEffect(() => {
    if (!token) return;
    const controller = new AbortController();
    setLoading(true); setError(undefined);
    void request<HealthDashboard>(`/api/health/dashboard?days=${days}`, token, { signal: controller.signal }).then(result => {
      setDashboard(result); setDetailed(result.consent?.detailedSamples ?? false); setReviews(result.consent?.workoutReviews ?? false);
    }).catch(e => { if (!controller.signal.aborted) setError((e as Error).message); }).finally(() => { if (!controller.signal.aborted) setLoading(false); });
    return () => controller.abort();
  }, [token, days, refresh]);
  const records = dashboard?.records ?? [];
  const scores = records.filter(record => record.kind === "score");
  const latest = scores[scores.length-1];
  const selectedScore = scores.filter(record => !selectedDate || day(record) <= selectedDate).at(-1);
  const selectedDaily = records.filter(record => record.kind === "daily" && day(record) === (selectedDate ?? day(latest ?? records.at(-1) ?? { observedAt: new Date().toISOString(), data: {} } as HealthRecord))).at(-1);
  const series = useMemo((): Series[] => {
    const daily = (key: string, title: string, unit: string, color = colors[0]) => ({ key, title, unit, color, points: points(records, "daily", key) });
    const score = (key: string, title: string, color = colors[0]) => ({ key, title, unit: "/100", color, points: points(records, "score", key) });
    let selected: Series[];
    switch (view) {
      case "fitness": selected = [score("fitness", "Fitness progress", colors[1]), daily("vo2Max", "Cardio fitness · VO₂ max", "mL/kg/min", colors[2])]; break;
      case "load": selected = [
        { key: "appleLoad", title: "Daily Apple effort load", unit: "AU", color: colors[0], points: workoutLoad(records) },
        { key: "acuteLoad", title: "Acute load · 7-day EWMA", unit: "AU/day", color: colors[1], points: points(records, "score", "acuteLoad") },
        { key: "chronicLoad", title: "Chronic load · 42-day EWMA", unit: "AU/day", color: colors[2], points: points(records, "score", "chronicLoad") }]; break;
      case "activity": selected = [daily("steps", "Steps", "steps"), daily("exerciseMinutes", "Exercise", "min", colors[1]), daily("standMinutes", "Stand time", "min", colors[2]), daily("activeEnergyKcal", "Active energy", "kcal", colors[3])]; break;
      case "body": selected = [daily("weightKg", "Weight", "kg"), daily("bodyFatPercent", "Body fat", "%", colors[1]), daily("bmi", "BMI", "kg/m²", colors[2])]; break;
      default: selected = [score("recovery", "Recovery & readiness"), daily("sleepMinutes", "Sleep", "min", colors[1]), daily("hrv", "Heart-rate variability · SDNN", "ms", colors[2]), daily("restingHR", "Resting heart rate", "bpm", colors[3])];
    }
    return selected.map(item => ({ ...item, color:metricColor(item.key), points: groupPoints(item.points, grain, ["steps", "exerciseMinutes", "standMinutes", "activeEnergyKcal", "appleLoad"].includes(item.key)) }));
  }, [records, view, grain]);
  async function act(action: () => Promise<unknown>) {
    setBusy(true); setError(undefined);
    try { await action(); setRefresh(value => value + 1); } catch (e) { setError((e as Error).message); } finally { setBusy(false); }
  }
  function signOut() { setToken(undefined); setDashboard(undefined); setPairing(undefined); setSelectedDate(undefined); window.google?.accounts.id.disableAutoSelect(); }
  if (isPrivacy) return <PrivacyPage />;
  return <div className="appShell">
    <header className="topbar"><Brand /><div className="topbarActions"><a href="/privacy" className="quietLink"><ShieldCheck size={16} />Privacy</a>{token && <button className="iconButton" onClick={signOut} aria-label="Sign out"><LogOut size={18} /></button>}</div></header>
    <main>
      {!token ? <><section className="welcome panel"><div className="eyebrow"><LockKeyhole size={16} />Private by choice</div><h1>Your health.<br /><span>The bigger picture.</span></h1><p>Recovery, fitness and training in one place. Connect the Apple Health data you choose from Robur, then explore the same scores and their contributing signals here.</p>
        {config?.googleWebClientId ? <GoogleSignIn clientId={config.googleWebClientId} onToken={setToken} /> : <div className="setupNotice"><strong>{config ? "Sign-in setup is pending" : "Connecting…"}</strong><p>{config ? "The deployment needs a Google web OAuth client before accounts can connect. Health uploads remain locked." : "Checking the secure connection."}</p></div>}
        <button onClick={()=>setExample(value=>!value)}>{example ? "Close analytics example" : "Explore analytics with example data"}</button><div className="welcomeFacts"><span><ShieldCheck size={17} />No public health profiles</span><span><HeartPulse size={17} />Apple Health stays in your control</span><span><CloudUpload size={17} />Upload only when you choose</span></div>
      </section>{example && <section className="panel"><p className="exampleNotice"><strong>Synthetic example — not your Health data.</strong> These generated records stay in this browser and are never uploaded.</p><AnalyticsWorkspace records={demonstration} selectedDate={selectedDate} onSelect={setSelectedDate}/></section>}</> : <>
        <section className="dashboardIntro"><div><p className="eyebrow">Your private dashboard</p><h1>See how it connects.</h1><p>{dashboard?.lastSyncedAt ? `Last upload ${new Date(dashboard.lastSyncedAt).toLocaleString()}` : "Connect Robur to bring your approved Health history here."}</p></div><div className="actions"><button onClick={() => void act(async () => setPairing(await request("/api/pairings", token, { method: "POST" })))} disabled={busy}><Link2 size={17} />Connect device</button><button className="iconButton" onClick={() => setRefresh(value => value+1)} aria-label="Refresh dashboard" disabled={loading}><RefreshCw size={17} className={loading ? "spinning" : ""} /></button><button onClick={() => setShowSettings(true)}>Data controls</button></div></section>
        <section className="scoreSummary" aria-label="Current scores">
          <Score label="Recovery & readiness" value={number(latest?.data.recovery)} detail="One combined daily recovery score" />
          <Score label="Fitness progress" value={number(latest?.data.fitness)} detail="Longer-term personal fitness trend" />
          <div className="metricSummary"><span>Dataset</span><strong>{Object.values(dashboard?.counts ?? {}).reduce((sum,count)=>sum+(count??0),0).toLocaleString()}</strong><small>records you chose to upload</small></div>
          <div className="metricSummary"><span>Coverage</span><strong>{dashboard?.counts.daily ?? 0}<small> days</small></strong><small>{dashboard?.counts.workout ?? 0} workouts · {dashboard?.counts.fitness ?? 0} fitness readings</small></div>
        </section>
        <section className="panel chartPanel">
          <div className="panelHeading"><div><p className="eyebrow">Your analytics workspace</p><h2>Explore the numbers together.</h2></div>
            <div className="controls"><label>Range<select value={days} onChange={e=>{setDays(e.target.value);setSelectedDate(undefined);}}><option value="30">30 days</option><option value="90">90 days</option><option value="365">1 year</option><option value="all">All uploaded</option></select></label><label>Period<select value={grain} onChange={e=>setGrain(e.target.value as typeof grain)}><option value="day">Daily</option><option value="week">Weekly</option><option value="month">Monthly</option></select></label></div>
          </div>
          {loading?<div className="loadingState">Reading your private dataset…</div>:<AnalyticsWorkspace records={records} selectedDate={selectedDate} onSelect={setSelectedDate} grain={grain}/>}
          {dashboard?.truncated && <p className="notice">Showing the latest 10,000 summaries. Choose a shorter range to inspect every record in that range.</p>}
        </section>
        <details className="focusedCharts"><summary>Individual metric charts</summary>
        <section className="panel chartPanel"><div className="panelHeading"><div><p className="eyebrow">Explore your history</p><h2>{view === "recovery" ? "Recovery is more than sleep." : view === "fitness" ? "Fitness, over time." : view === "load" ? "Training and recovery demand." : view === "activity" ? "Your everyday movement." : "Body measurements."}</h2></div><div className="controls"><label>Range<select value={days} onChange={e=>{setDays(e.target.value);setSelectedDate(undefined);}}><option value="30">30 days</option><option value="90">90 days</option><option value="365">1 year</option><option value="all">All uploaded</option></select></label><label>Period<select value={grain} onChange={e=>setGrain(e.target.value as typeof grain)}><option value="day">Daily</option><option value="week">Weekly</option><option value="month">Monthly</option></select></label><label>Chart<select value={chartStyle} onChange={e=>setChartStyle(e.target.value as typeof chartStyle)}><option value="line">Lines</option><option value="bar">Bars</option></select></label></div></div>
          <div className="segmented" role="group" aria-label="Health graph"><button aria-pressed={view==="recovery"} onClick={()=>setView("recovery")}>Recovery</button><button aria-pressed={view==="fitness"} onClick={()=>setView("fitness")}>Fitness</button><button aria-pressed={view==="load"} onClick={()=>setView("load")}>Load</button><button aria-pressed={view==="activity"} onClick={()=>setView("activity")}>Activity</button><button aria-pressed={view==="body"} onClick={()=>setView("body")}>Body</button></div>
          {!records.length ? <div className="emptyState"><CloudUpload size={32} /><h3>Your data starts here.</h3><p>Connect a device, review the data categories, then upload from Robur. No example scores are substituted for missing Health readings.</p></div> : <div className="graphGrid">{series.map(item=><DataChart key={item.key} series={item} style={chartStyle} selected={selectedDate} onSelect={setSelectedDate} grain={grain} score={item.unit==="/100"} />)}</div>}
          <p className="chartFootnote">{grain === "day" ? "Recorded dates only." : "Score and vital signs use recorded-date means; movement and session load use totals."} Separate scales preserve units. Select a point for its date; gaps and absent readings remain visible. Scores use their uploaded methodology version.</p>
          {dashboard?.truncated && <p className="notice">This view contains the latest 10,000 summaries. Select a shorter range for a complete chart. Your other uploaded records remain stored.</p>}
        </section>
        </details>
        <div className="detailGrid"><section className="panel"><div className="panelHeading"><div><p className="eyebrow">What builds the score</p><h2>{selectedScore ? new Date(`${day(selectedScore)}T12:00:00`).toLocaleDateString(undefined,{dateStyle:"medium"}) : "Waiting for a recovery score"}</h2></div><HeartPulse size={23} /></div><ComponentBreakdown record={selectedScore} />
          <p className="chartFootnote">Methodology: {typeof selectedScore?.data.methodologyVersion === "string" ? selectedScore.data.methodologyVersion : "Not uploaded"}. This is a transparent Robur estimate, not a diagnostic or an injury prediction.</p></section>
          <section className="panel"><div className="panelHeading"><div><p className="eyebrow">Selected period</p><h2>{selectedDate ? new Date(`${selectedDate}T12:00:00`).toLocaleDateString(undefined,{dateStyle:"medium"}) : "Latest readings"}</h2></div><CalendarDays size={22} /></div><dl className="readingList">{[["Sleep", "sleepMinutes", "min"],["HRV · SDNN","hrv","ms"],["Resting HR","restingHR","bpm"],["Steps","steps","steps"],["Exercise","exerciseMinutes","min"],["Weight","weightKg","kg"]].map(([label,key,unit])=><div key={key}><dt>{label}</dt><dd>{number(selectedDaily?.data[key])?.toLocaleString(undefined,{maximumFractionDigits:1}) ?? "—"}<small> {unit}</small></dd></div>)}</dl></section></div>
        <section className="panel"><div className="panelHeading"><div><p className="eyebrow">Recorded training</p><h2>Workouts in context</h2></div><Activity size={23} /></div><div className="workoutTable">{records.filter(record=>record.kind==="workout" && (!selectedDate || day(record)===selectedDate)).slice(-30).reverse().map(record=><div className="workoutRow" key={record.id}><span className="workoutIcon"><Activity size={19} /></span><div><strong>{String(record.data.title ?? record.data.activity ?? "Workout")}</strong><small>{new Date(record.observedAt).toLocaleString()}</small></div><span>{number(record.data.minutes)?.toFixed(0) ?? "—"} min</span><span>{number(record.data.appleEffort)?.toFixed(1) ?? "—"}<small> /10 Apple effort</small></span></div>)}{!records.some(record=>record.kind==="workout" && (!selectedDate || day(record)===selectedDate)) && <p className="muted">No workouts uploaded for this selection.</p>}</div>{selectedDate && <button className="textButton" onClick={()=>setSelectedDate(undefined)}>Clear date selection</button>}</section>
      </>}
      {error && <div className="errorBanner" role="alert">{error}<button onClick={()=>setError(undefined)} aria-label="Dismiss error">×</button></div>}
      {pairing && <div className="modalBackdrop"><section className="modal panel" role="dialog" aria-modal="true" aria-labelledby="pair-title"><p className="eyebrow">Connect Robur</p><h2 id="pair-title">Your one-use pairing code</h2><p>In Robur, open Settings → Cloud sync. Enter this website address and the code below. Then choose what to share and upload.</p><code className="pairCode">{pairing.code.slice(0,5)} {pairing.code.slice(5)}</code><p className="muted">Expires {new Date(pairing.expiresAt).toLocaleTimeString()} · This code grants a device access to your account. Keep it private.</p><button onClick={()=>setPairing(undefined)}>Done</button></section></div>}
      {showSettings && <div className="modalBackdrop"><section className="modal panel" role="dialog" aria-modal="true" aria-labelledby="controls-title"><div className="panelHeading"><h2 id="controls-title">Your data controls</h2><button className="iconButton" onClick={()=>setShowSettings(false)} aria-label="Close data controls">×</button></div><p>Sync is optional. Pausing stops new uploads; previously uploaded data remains until you delete it.</p><label className="checkRow"><input type="checkbox" checked={detailed} onChange={e=>setDetailed(e.target.checked)} />Allow detailed Health samples, including workout heart-rate observations</label><label className="checkRow"><input type="checkbox" checked={reviews} onChange={e=>setReviews(e.target.checked)} />Allow workout reviews, muscle tags and notes</label><div className="actions"><button disabled={busy} onClick={()=>void act(()=>request("/api/health/consent",token,{method:"POST",body:JSON.stringify({version:healthConsentVersion,detailedSamples:detailed,workoutReviews:reviews})}))}>Enable / update sync consent</button><button disabled={busy} onClick={()=>void act(()=>request("/api/health/consent",token,{method:"DELETE"}))}>Pause uploads</button></div><p className="muted">Current permission: {dashboard?.consent ? "enabled" : "paused"}. Changing categories does not erase data already uploaded. <a href="/privacy">Read the privacy details.</a></p><hr/><button className="danger textButton" onClick={()=>setDeleting(value=>!value)}><Trash2 size={16}/>Delete all cloud health data</button>{deleting && <div className="deleteConfirm"><p>This deletes your cloud Health records and disconnects all paired devices. Apple Health and on-device records are unchanged. Database backups expire according to the published retention period.</p><label>Type DELETE<input value={deleteText} onChange={e=>setDeleteText(e.target.value)} autoComplete="off" /></label><button className="danger" disabled={deleteText!=="DELETE" || busy} onClick={()=>void act(async()=>{await request("/api/health/data",token,{method:"DELETE"});setDeleteText("");setDeleting(false);setPairing(undefined);})}>Permanently delete cloud data</button></div>}</section></div>}
    </main><footer><span>Robur · Health and training, connected.</span><a href="/privacy">Privacy & data controls<ChevronRight size={14}/></a></footer>
  </div>;
}

function Score({ label, value, detail }: { label: string; value?: number; detail: string }) { return <div className="metricSummary"><span>{label}</span><strong>{value===undefined ? "—" : Math.round(value)}<small>{value===undefined ? "" : " /100"}</small></strong><small>{detail}</small></div>; }
function DataChart({ series, style, selected, onSelect, grain, score }: { series: Series; style: "line"|"bar"; selected?: string; onSelect(date:string):void; grain:string; score:boolean }) {
  const values = series.points, [hover, setHover] = useState<Point>();
  const width=650,height=210,left=48,right=18,top=18,bottom=32;
  const minDate = Date.parse(`${values[0]?.date ?? "2000-01-01"}T12:00:00Z`), maxDate=Date.parse(`${values.at(-1)?.date ?? "2000-01-02"}T12:00:00Z`);
  const min=score ? 0 : Math.min(0,...values.map(p=>p.value)),max=score?100:Math.max(1,...values.map(p=>p.value))*1.12;
  const x=(p:Point)=>left+(Date.parse(`${p.date}T12:00:00Z`)-minDate)/Math.max(86400000,maxDate-minDate)*(width-left-right),y=(v:number)=>top+(max-v)/(max-min)*(height-top-bottom);
  const latest=values.at(-1),display=hover ?? values.find(p=>p.date===selected) ?? latest;
  const maxGap=grain==="month"?40:grain==="week"?9:2;
  let prior:Point|undefined;
  const path=values.map(p=>{const gap=prior?(Date.parse(p.date)-Date.parse(prior.date))/86400000:Infinity;const command=gap>maxGap?"M":"L";prior=p;return `${command}${x(p).toFixed(1)},${y(p.value).toFixed(1)}`;}).join(" ");
  return <div className="dataChart"><div className="chartTitle"><h3><i style={{background:series.color}}/>{series.title}</h3><strong>{display?.value.toLocaleString(undefined,{maximumFractionDigits:1})??"—"}<small> {series.unit}</small></strong></div>{!values.length?<div className="chartEmpty">No approved readings uploaded for this measure.</div>:<><svg viewBox={`0 0 ${width} ${height}`} role="img" aria-label={`${series.title}, ${values.length} recorded periods. ${latest?.date}: ${latest?.value.toFixed(1)} ${series.unit}`}>
    {[0,.5,1].map(ratio=>{const value=min+(max-min)*ratio;return <g key={ratio}><line x1={left} x2={width-right} y1={y(value)} y2={y(value)} className="gridLine"/><text x={left-8} y={y(value)+4} textAnchor="end" className="axisLabel">{Math.round(value).toLocaleString()}</text></g>;})}
    {style==="line"?<path d={path} fill="none" stroke={series.color} strokeWidth="2.5" strokeLinecap="round" strokeLinejoin="round"/>:values.map(p=><rect key={p.date} x={x(p)-Math.max(2,Math.min(12,(width-left-right)/values.length*.32))} y={y(p.value)} width={Math.max(4,Math.min(24,(width-left-right)/values.length*.64))} height={Math.max(1,y(min)-y(p.value))} fill={series.color} opacity={selected===p.date?1:.72} rx="2"/>)}
    {values.map(p=><circle key={p.date} cx={x(p)} cy={y(p.value)} r={display?.date===p.date?5:3} fill={series.color} opacity={display?.date===p.date?1:.4} tabIndex={0} role="button" aria-label={`${p.date}: ${p.value.toFixed(1)} ${series.unit}`} onMouseEnter={()=>setHover(p)} onMouseLeave={()=>setHover(undefined)} onClick={()=>onSelect(p.date)} onFocus={()=>setHover(p)} onKeyDown={e=>{if(e.key==="Enter"||e.key===" "){e.preventDefault();onSelect(p.date);}}}><title>{p.date}: {p.value.toFixed(1)} {series.unit}</title></circle>)}
    <text x={left} y={height-7} className="axisLabel">{values[0]?.date}</text><text x={width-right} y={height-7} textAnchor="end" className="axisLabel">{latest?.date}</text>
  </svg><p className="chartCaption">{display?.date} · {values.length} recorded {grain==="day"?"days":`${grain}s`}</p></>}</div>;
}
function ComponentBreakdown({ record }: { record?: HealthRecord }) {
  const values=components(record);
  if(!values.length)return <p className="muted">Upload a recovery analysis from Robur to see its actual contributing factors, weights and baseline coverage.</p>;
  return <div className="components">{values.map((part,index)=>{const value=number(part.value)??number(part.score),weight=number(part.effectiveWeight)??number(part.weight);return <div className="component" key={String(part.id??part.title??index)}><div><strong>{String(part.title??part.id??"Component")}</strong><span>{value===undefined?"Unavailable":`${Math.round(value)}/100`}{weight!==undefined?` · ${Math.round(weight*(weight<=1?100:1))}% weight`:""}</span></div><div className="componentTrack"><span style={{width:`${value??0}%`}}/></div>{(part.current!==undefined||part.baseline!==undefined)&&<p>Observed {String(part.current??"—")} {String(part.unit??"")} · baseline {String(part.baseline??"—")}</p>}{typeof part.explanation==="string"&&<p>{part.explanation}</p>}</div>;})}</div>;
}
function PrivacyPage() { return <div className="appShell"><header className="topbar"><Brand/><a className="quietLink" href="/"><ArrowLeft size={16}/>Dashboard</a></header><main className="privacyPage panel"><p className="eyebrow">Privacy & data controls</p><h1>Health data stays yours.</h1><p>Robur works on your Apple devices without cloud sync. Cloud storage is optional and starts only after you connect a device, review the data categories and give consent. This dashboard has no public health profiles.</p><h2>What you can choose to upload</h2><p>Daily Health summaries such as sleep, heart-rate variability (SDNN), resting heart rate, steps, movement, cardio fitness and body measurements; recorded workouts and Apple effort; and versioned Robur recovery/fitness analyses with their component breakdown. A separate choice controls detailed samples such as workout heart-rate observations. Another separate choice controls workout muscle tags and free-text reviews.</p><p>Medical ID, emergency contacts, blood type and clinical records are not included in the standard sync. Robur does not collect GPS routes or saved gym locations. Health access remains controlled in Apple Health.</p><h2>Storage and account access</h2><p>Selected data is sent over HTTPS to Robur’s Google Cloud service and PostgreSQL database in the configured European region. Your records are isolated by your signed-in account. Google sign-in identifies the account using its stable subject identifier; Robur does not store your Google profile email or name in the Health database. Paired devices use revocable device credentials stored as hashes on the server.</p><p>Health data is used to provide your private Robur health and training features. It is not sold, used for advertising or sent to third-party AI services. This website has no advertising or analytics trackers. Google provides sign-in and infrastructure processing.</p><h2>Pause, delete or disconnect</h2><p>Pause uploads in Data controls or turn off sync in Robur to stop new uploads. Pausing and removing a category do not erase records already uploaded. Delete cloud health data from Data controls to remove the active cloud dataset and revoke every paired device credential. Your original Apple Health and device-local records are unchanged.</p><p>Database backups may retain deleted data until the configured backup retention period expires. Restored backups must reapply deletion records before access is reopened. Do not treat active-database deletion as immediate erasure from all backups.</p><h2>Data quality and scores</h2><p>Cloud charts display the data and algorithm version uploaded from Robur. Missing Health readings remain missing. Recovery and fitness scores are transparent wellness estimates, not clinical measurements, diagnoses or predictions of injury. Changes in wearable coverage, permissions or measurement conditions affect comparability.</p><p>For account or data questions, contact <a href="mailto:support@robur.fit">support@robur.fit</a>.</p></main></div>; }
export default App;
