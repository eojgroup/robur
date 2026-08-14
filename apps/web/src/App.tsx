import type { ReactNode } from "react";
import { Activity, Bike, Dumbbell, HeartPulse, Moon, Watch } from "lucide-react";
import {
  formatDuration,
  formatSleep,
  recommendationLabel,
  roburApp,
  todaySnapshot
} from "@robur/core";

function App() {
  return (
    <main className="appShell">
      <section className="todayPanel" aria-label="Robur Today">
        <header className="appHeader">
          <div>
            <p className="appName">{roburApp.name}</p>
            <h1>Today</h1>
          </div>
          <button type="button" className="iconButton" title="Apple Health sync">
            <Watch size={20} />
          </button>
        </header>

        <div className="divider" />

        <section className="scoreStack" aria-label="Daily readiness scores">
          <ScoreRow label={todaySnapshot.recovery.label} value={todaySnapshot.recovery.value} />
          <ScoreRow label={todaySnapshot.trainingLoad.label} value={todaySnapshot.trainingLoad.value} />
        </section>

        <section className="vitalsGrid" aria-label="Apple Health vitals">
          <VitalRow icon={<Moon size={18} />} label="Sleep" value={formatSleep(todaySnapshot.sleepMinutes)} />
          <VitalRow icon={<HeartPulse size={18} />} label="Resting HR" value={`${todaySnapshot.restingHeartRateBpm} bpm`} />
          <VitalRow icon={<Activity size={18} />} label="HRV" value={`${todaySnapshot.heartRateVariabilityMs} ms`} />
        </section>

        <div className="divider" />

        <section className="recommendation" aria-label="Today's recommendation">
          <p className="sectionLabel">Today's recommendation</p>
          <h2>{todaySnapshot.recommendation.title}</h2>
          <p className="prescription">{recommendationLabel(todaySnapshot.recommendation)}</p>
          <p className="rationale">{todaySnapshot.recommendation.rationale}</p>
        </section>

        <div className="divider" />

        <section className="week" aria-label="This week">
          <p className="sectionLabel">This week</p>
          <WeekRow icon={<Activity size={18} />} label="Running" value={`${todaySnapshot.week.runningKm.toFixed(1)} km`} />
          <WeekRow icon={<Bike size={18} />} label="Cycling" value={`${todaySnapshot.week.cyclingKm} km`} />
          <WeekRow icon={<Dumbbell size={18} />} label="Strength" value={`${todaySnapshot.week.strengthSessions} sessions`} />
          <WeekRow icon={<Watch size={18} />} label="Training" value={formatDuration(todaySnapshot.week.trainingMinutes)} />
        </section>
      </section>
    </main>
  );
}

interface ScoreRowProps {
  label: string;
  value: number;
}

function ScoreRow({ label, value }: ScoreRowProps) {
  return (
    <div className="scoreRow">
      <div className="metricLine">
        <span>{label}</span>
        <strong>{value}</strong>
      </div>
      <div className="barTrack" aria-hidden="true">
        <span style={{ width: `${value}%` }} />
      </div>
    </div>
  );
}

interface RowProps {
  icon: ReactNode;
  label: string;
  value: string;
}

function VitalRow({ icon, label, value }: RowProps) {
  return (
    <div className="dataRow">
      <span className="rowIcon">{icon}</span>
      <span>{label}</span>
      <strong>{value}</strong>
    </div>
  );
}

function WeekRow({ icon, label, value }: RowProps) {
  return (
    <div className="dataRow weekRow">
      <span className="rowIcon">{icon}</span>
      <span>{label}</span>
      <strong>{value}</strong>
    </div>
  );
}

export default App;
