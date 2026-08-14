import type { CSSProperties, ReactNode } from "react";
import {
  Activity,
  ArrowUpRight,
  Bike,
  CalendarDays,
  ChevronRight,
  Dumbbell,
  HeartPulse,
  House,
  Moon,
  Route,
  ShieldCheck,
  Sparkles,
  Watch
} from "lucide-react";
import {
  focusLabel,
  formatDuration,
  formatSleep,
  recommendationLabel,
  roburApp,
  starterPlan,
  summarizeWeek,
  todaySnapshot
} from "@robur/core";

const planSummary = summarizeWeek(starterPlan);

function App() {
  return (
    <div className="appShell">
      <aside className="sidebar" aria-label="Primary navigation">
        <a className="brand" href="#today" aria-label={`${roburApp.name} home`}>
          <span className="brandMark" aria-hidden="true">
            R
          </span>
          <span>{roburApp.name}</span>
        </a>

        <nav className="primaryNav">
          <NavLink icon={<House size={18} />} label="Today" href="#today" active />
          <NavLink icon={<CalendarDays size={18} />} label="Plan" href="#plan" />
          <NavLink icon={<Route size={18} />} label="Progress" href="#progress" />
        </nav>

        <div className="sidebarFooter">
          <span className="sidebarEyebrow">Your system</span>
          <p>Built around the signals you choose to share.</p>
          <a href="#health" className="healthLink">
            <ShieldCheck size={16} /> Health privacy
          </a>
        </div>
      </aside>

      <div className="workspace">
        <header className="topbar">
          <div>
            <p className="eyebrow">{todaySnapshot.dateLabel}</p>
            <h1>Train with intent.</h1>
          </div>
          <div className="topbarActions">
            <StatusPill icon={<Sparkles size={15} />} tone="info">
              Demo data
            </StatusPill>
            <StatusPill icon={<Watch size={15} />} tone="neutral">
              Apple Health ready
            </StatusPill>
          </div>
        </header>

        <main id="today" className="dashboard" tabIndex={-1}>
          <section className="dashboardIntro" aria-labelledby="dashboard-heading">
            <div>
              <p className="sectionKicker">Daily readiness</p>
              <h2 id="dashboard-heading">A steady day, with room to move.</h2>
            </div>
            <p>
              Your current snapshot is a mock-up of the Apple Health signals the iPhone app can
              read with your permission.
            </p>
          </section>

          <div className="dashboardGrid">
            <ReadinessCard />
            <RecommendationCard />
            <VitalsCard />
            <WeeklyTrainingCard />
            <PlanCard />
            <ProgressCard />
          </div>
        </main>
      </div>
    </div>
  );
}

function NavLink({ icon, label, href, active = false }: { icon: ReactNode; label: string; href: string; active?: boolean }) {
  return (
    <a className={`navLink${active ? " isActive" : ""}`} href={href} aria-current={active ? "page" : undefined}>
      {icon}
      <span>{label}</span>
    </a>
  );
}

function ReadinessCard() {
  return (
    <section className="panel readinessPanel" aria-labelledby="readiness-heading">
      <PanelHeading eyebrow="Readiness" title="Your capacity today" action="How it works" />
      <div className="readinessBody">
        <ScoreDial value={todaySnapshot.recovery.value} />
        <div className="readinessSummary">
          <p className="readinessLead">
            Recovery is <strong>good</strong> and trending up from your recent baseline.
          </p>
          <p className="mutedCopy">
            Sleep and autonomic signals support a purposeful aerobic session today.
          </p>
          <div className="scoreComparison" aria-label="Recovery score breakdown">
            <ScoreLine label="Recovery" value={todaySnapshot.recovery.value} tone="positive" />
            <ScoreLine label="Training load" value={todaySnapshot.trainingLoad.value} tone="information" />
          </div>
        </div>
      </div>
      <p id="readiness-heading" className="srOnly">
        Your capacity today
      </p>
    </section>
  );
}

function ScoreDial({ value }: { value: number }) {
  return (
    <div className="scoreDial" style={{ "--score": value } as CSSProperties} aria-label={`Readiness ${value} out of 100`}>
      <div className="scoreDialInner">
        <strong>{value}</strong>
        <span>out of 100</span>
      </div>
    </div>
  );
}

function RecommendationCard() {
  return (
    <section className="panel recommendationPanel" aria-labelledby="recommendation-heading">
      <PanelHeading eyebrow="Recommended session" title={todaySnapshot.recommendation.title} />
      <div className="recommendationMeta">
        <span>
          <Activity size={17} /> {recommendationLabel(todaySnapshot.recommendation)}
        </span>
        <span>
          <HeartPulse size={17} /> Controlled effort
        </span>
      </div>
      <p className="recommendationRationale">{todaySnapshot.recommendation.rationale}</p>
      <a href="#plan" className="primaryAction">
        View session <ArrowUpRight size={17} />
      </a>
      <p id="recommendation-heading" className="srOnly">
        Recommended session
      </p>
    </section>
  );
}

function VitalsCard() {
  return (
    <section className="panel vitalsPanel" id="health" aria-labelledby="vitals-heading">
      <PanelHeading eyebrow="Apple Health snapshot" title="Signals" action="Updated 08:42" />
      <dl className="vitalsList">
        <Vital icon={<Moon size={19} />} label="Sleep" value={formatSleep(todaySnapshot.sleepMinutes)} detail="Last night" tone="positive" />
        <Vital icon={<HeartPulse size={19} />} label="Resting HR" value={`${todaySnapshot.restingHeartRateBpm} bpm`} detail="Within baseline" tone="information" />
        <Vital icon={<Activity size={19} />} label="HRV" value={`${todaySnapshot.heartRateVariabilityMs} ms`} detail="Above baseline" tone="positive" />
      </dl>
      <p id="vitals-heading" className="srOnly">
        Apple Health signals
      </p>
    </section>
  );
}

function Vital({ icon, label, value, detail, tone }: { icon: ReactNode; label: string; value: string; detail: string; tone: "positive" | "information" }) {
  return (
    <div className="vitalRow">
      <dt>
        <span className={`metricIcon ${tone}`}>{icon}</span>
        <span>{label}</span>
      </dt>
      <dd>
        <strong>{value}</strong>
        <span>{detail}</span>
      </dd>
    </div>
  );
}

function WeeklyTrainingCard() {
  const totals = todaySnapshot.week;
  return (
    <section className="panel weeklyPanel" aria-labelledby="weekly-heading">
      <PanelHeading eyebrow="This week" title="Training load" action="Aug 10–16" />
      <div className="weeklyTotals">
        <div>
          <strong>{formatDuration(totals.trainingMinutes)}</strong>
          <span>training time</span>
        </div>
        <div>
          <strong>{totals.runningKm.toFixed(1)} km</strong>
          <span>running</span>
        </div>
        <div>
          <strong>{totals.cyclingKm} km</strong>
          <span>cycling</span>
        </div>
      </div>
      <div className="loadScale" aria-label="Current training load is 64, within target range">
        <div className="loadScaleLabels">
          <span>Under</span>
          <span>Target</span>
          <span>High</span>
        </div>
        <div className="loadTrack">
          <span className="targetBand" />
          <span className="loadMarker" style={{ left: `${todaySnapshot.trainingLoad.value}%` }}>
            <i />
          </span>
        </div>
      </div>
      <div className="trainingFooter">
        <Dumbbell size={17} />
        <span>{totals.strengthSessions} strength sessions completed</span>
      </div>
      <p id="weekly-heading" className="srOnly">
        Training load this week
      </p>
    </section>
  );
}

function PlanCard() {
  const sessions = starterPlan.slice(0, 4);
  return (
    <section className="panel planPanel" id="plan" aria-labelledby="plan-heading">
      <PanelHeading eyebrow="Week ahead" title="A balanced plan" action={`${planSummary.plannedSessions} sessions`} />
      <ol className="sessionList">
        {sessions.map((session) => (
          <li key={session.id}>
            <span className={`sessionIcon ${session.focus}`}>{focusIcon(session.focus)}</span>
            <span className="sessionDay">{session.day}</span>
            <span className="sessionTitle">
              <strong>{session.title}</strong>
              <small>{focusLabel(session.focus)}</small>
            </span>
            <span className="sessionDuration">{formatDuration(session.durationMinutes)}</span>
            <ChevronRight className="sessionArrow" size={17} aria-hidden="true" />
          </li>
        ))}
      </ol>
      <a className="subtleAction" href="#progress">
        See full plan <ArrowUpRight size={16} />
      </a>
      <p id="plan-heading" className="srOnly">
        Your balanced week ahead
      </p>
    </section>
  );
}

function ProgressCard() {
  const values = [42, 57, 48, 68, 61, 76, todaySnapshot.recovery.value];
  return (
    <section className="panel progressPanel" id="progress" aria-labelledby="progress-heading">
      <PanelHeading eyebrow="Recovery trend" title="Your last 7 days" action="Stable" />
      <div className="trend" aria-label="Recovery rose from 42 to 82 over seven days">
        {values.map((value, index) => (
          <div className="trendColumn" key={`${value}-${index}`}>
            <span style={{ height: `${value}%` }} />
            <small>{["M", "T", "W", "T", "F", "S", "S"][index]}</small>
          </div>
        ))}
      </div>
      <div className="progressFooter">
        <span>7-day average</span>
        <strong>64</strong>
        <span className="trendUp">+6 from prior week</span>
      </div>
      <p id="progress-heading" className="srOnly">
        Recovery trend over the last seven days
      </p>
    </section>
  );
}

function PanelHeading({ eyebrow, title, action }: { eyebrow: string; title: string; action?: string }) {
  return (
    <header className="panelHeading">
      <div>
        <p className="sectionKicker">{eyebrow}</p>
        <h3>{title}</h3>
      </div>
      {action ? <span className="panelAction">{action}</span> : null}
    </header>
  );
}

function ScoreLine({ label, value, tone }: { label: string; value: number; tone: "positive" | "information" }) {
  return (
    <div className="scoreLine">
      <div>
        <span>{label}</span>
        <strong>{value}</strong>
      </div>
      <div className={`scoreTrack ${tone}`} aria-hidden="true">
        <span style={{ width: `${value}%` }} />
      </div>
    </div>
  );
}

function StatusPill({ icon, tone, children }: { icon: ReactNode; tone: "info" | "neutral"; children: ReactNode }) {
  return (
    <span className={`statusPill ${tone}`}>
      {icon}
      {children}
    </span>
  );
}

function focusIcon(focus: string) {
  if (focus === "cycling") return <Bike size={17} />;
  if (focus === "strength") return <Dumbbell size={17} />;
  if (focus === "mobility" || focus === "recovery") return <Sparkles size={17} />;
  return <Activity size={17} />;
}

export default App;
