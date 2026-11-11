export type TrainingFocus = "running" | "cycling" | "strength" | "mobility" | "recovery";

export interface WorkoutSession {
  id: string;
  day: string;
  title: string;
  focus: TrainingFocus;
  durationMinutes: number;
  intensity: 1 | 2 | 3 | 4 | 5;
  targetHeartRateZone: 1 | 2 | 3 | 4 | 5;
  movements: string[];
}

export interface HealthMetric {
  label: string;
  value: string;
  unit?: string;
}

export interface ScoreMetric {
  label: string;
  value: number;
  baseline?: number;
}

export interface FitnessRecommendation {
  title: string;
  durationMinutesMin: number;
  durationMinutesMax: number;
  zone: number;
  rationale: string;
}

export interface WeekTotals {
  runningKm: number;
  cyclingKm: number;
  strengthSessions: number;
  trainingMinutes: number;
}

export interface TodaySnapshot {
  dateLabel: string;
  recovery: ScoreMetric;
  trainingLoad: ScoreMetric;
  sleepMinutes: number;
  restingHeartRateBpm: number;
  heartRateVariabilityMs: number;
  recommendation: FitnessRecommendation;
  week: WeekTotals;
}

export interface WeekSummary {
  plannedSessions: number;
  totalMinutes: number;
  averageIntensity: number;
  focusMix: Record<TrainingFocus, number>;
  readinessScore: number;
}

export interface HealthKitSyncPayload {
  sourceDeviceId: string;
  capturedAt: string;
  snapshot: TodaySnapshot;
}

export interface PushDeviceRegistration {
  installationId: string;
  platform: "ios" | "watchos";
  deviceToken: string;
  bundleId: string;
  environment: "development" | "production";
  registeredAt: string;
}

export const roburApp = {
  name: "Robur",
  slug: "robur",
  bundleIdentifier: "com.eojgroup.robur",
  watchBundleIdentifier: "com.eojgroup.robur.watchkitapp",
  supportEmail: "support@robur.fit"
} as const;

export const todaySnapshot: TodaySnapshot = {
  dateLabel: "Today",
  recovery: {
    label: "Recovery",
    value: 82
  },
  trainingLoad: {
    label: "Training load",
    value: 64
  },
  sleepMinutes: 468,
  restingHeartRateBpm: 48,
  heartRateVariabilityMs: 71,
  recommendation: {
    title: "Easy aerobic",
    durationMinutesMin: 40,
    durationMinutesMax: 55,
    zone: 2,
    rationale: "Your recovery is above baseline, but 7-day running load is +18%."
  },
  week: {
    runningKm: 38.4,
    cyclingKm: 112,
    strengthSessions: 2,
    trainingMinutes: 402
  }
};

export const starterPlan: WorkoutSession[] = [
  {
    id: "monday-easy-aerobic",
    day: "Mon",
    title: "Easy Aerobic",
    focus: "running",
    durationMinutes: 45,
    intensity: 2,
    targetHeartRateZone: 2,
    movements: ["Warmup walk", "Zone 2 run", "Cooldown walk", "Mobility reset"]
  },
  {
    id: "tuesday-strength",
    day: "Tue",
    title: "Lower Strength",
    focus: "strength",
    durationMinutes: 46,
    intensity: 4,
    targetHeartRateZone: 3,
    movements: ["Back squat", "Romanian deadlift", "Walking lunge", "Calf raise"]
  },
  {
    id: "thursday-cycling",
    day: "Thu",
    title: "Endurance Ride",
    focus: "cycling",
    durationMinutes: 72,
    intensity: 3,
    targetHeartRateZone: 2,
    movements: ["Progressive warmup", "Steady ride", "Cadence drills", "Cooldown spin"]
  },
  {
    id: "friday-mobility",
    day: "Fri",
    title: "Mobility Reset",
    focus: "mobility",
    durationMinutes: 24,
    intensity: 2,
    targetHeartRateZone: 1,
    movements: ["Hip flow", "Thoracic rotation", "Hamstring floss", "Box breathing"]
  },
  {
    id: "sunday-recovery",
    day: "Sun",
    title: "Recovery Walk",
    focus: "recovery",
    durationMinutes: 38,
    intensity: 2,
    targetHeartRateZone: 1,
    movements: ["Easy walk", "Nasal breathing", "Stretch cooldown"]
  }
];

export function summarizeWeek(sessions: WorkoutSession[]): WeekSummary {
  const focusMix: Record<TrainingFocus, number> = {
    running: 0,
    cycling: 0,
    strength: 0,
    mobility: 0,
    recovery: 0
  };

  const totalMinutes = sessions.reduce((total, session) => {
    focusMix[session.focus] += 1;
    return total + session.durationMinutes;
  }, 0);

  const intensityTotal = sessions.reduce((total, session) => total + session.intensity, 0);
  const averageIntensity = sessions.length === 0 ? 0 : round(intensityTotal / sessions.length, 1);

  return {
    plannedSessions: sessions.length,
    totalMinutes,
    averageIntensity,
    focusMix,
    readinessScore: calculateReadinessScore(sessions)
  };
}

export function calculateReadinessScore(sessions: WorkoutSession[]): number {
  if (sessions.length === 0) {
    return 100;
  }

  const hardMinutes = sessions
    .filter((session) => session.intensity >= 4)
    .reduce((total, session) => total + session.durationMinutes, 0);
  const recoveryMinutes = sessions
    .filter((session) => session.focus === "recovery" || session.focus === "mobility")
    .reduce((total, session) => total + session.durationMinutes, 0);

  const loadPenalty = Math.min(34, Math.round(hardMinutes / 5));
  const recoveryCredit = Math.min(18, Math.round(recoveryMinutes / 4));

  return clamp(72 - loadPenalty + recoveryCredit, 35, 96);
}

export function normalizeHealthKitSync(payload: HealthKitSyncPayload): HealthKitSyncPayload {
  return {
    sourceDeviceId: payload.sourceDeviceId.trim(),
    capturedAt: new Date(payload.capturedAt).toISOString(),
    snapshot: {
      ...payload.snapshot,
      recovery: {
        ...payload.snapshot.recovery,
        value: clampScore(payload.snapshot.recovery.value)
      },
      trainingLoad: {
        ...payload.snapshot.trainingLoad,
        value: clampScore(payload.snapshot.trainingLoad.value)
      },
      sleepMinutes: Math.max(0, Math.round(payload.snapshot.sleepMinutes)),
      restingHeartRateBpm: Math.max(0, Math.round(payload.snapshot.restingHeartRateBpm)),
      heartRateVariabilityMs: Math.max(0, Math.round(payload.snapshot.heartRateVariabilityMs))
    }
  };
}

export function normalizePushDeviceRegistration(payload: PushDeviceRegistration): PushDeviceRegistration {
  return {
    installationId: payload.installationId.trim(),
    platform: payload.platform,
    deviceToken: payload.deviceToken.trim().toLowerCase(),
    bundleId: payload.bundleId.trim(),
    environment: payload.environment,
    registeredAt: new Date(payload.registeredAt).toISOString()
  };
}

export function recommendationLabel(recommendation: FitnessRecommendation): string {
  return `${recommendation.durationMinutesMin}-${recommendation.durationMinutesMax} min / Zone ${recommendation.zone}`;
}

export function formatDuration(minutes: number): string {
  const hours = Math.floor(minutes / 60);
  const remainder = minutes % 60;

  if (hours === 0) {
    return `${remainder}m`;
  }

  return remainder === 0 ? `${hours}h` : `${hours}h ${remainder}m`;
}

export function formatSleep(minutes: number): string {
  return formatDuration(minutes);
}

export function focusLabel(focus: TrainingFocus): string {
  const labels: Record<TrainingFocus, string> = {
    running: "Running",
    cycling: "Cycling",
    strength: "Strength",
    mobility: "Mobility",
    recovery: "Recovery"
  };

  return labels[focus];
}

function clampScore(value: number): number {
  return clamp(Math.round(value), 0, 100);
}

function clamp(value: number, min: number, max: number): number {
  return Math.min(max, Math.max(min, value));
}

function round(value: number, precision: number): number {
  const multiplier = 10 ** precision;
  return Math.round(value * multiplier) / multiplier;
}

export * from "./health-cloud.js";
export * from "./metric-style.js";
