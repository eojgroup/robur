import { describe, expect, it } from "vitest";
import {
  calculateReadinessScore,
  formatDuration,
  formatSleep,
  normalizeHealthKitSync,
  normalizePushDeviceRegistration,
  starterPlan,
  summarizeWeek,
  todaySnapshot
} from "../src";

describe("Robur core fitness calculations", () => {
  it("summarizes the starter plan", () => {
    const summary = summarizeWeek(starterPlan);

    expect(summary.plannedSessions).toBe(5);
    expect(summary.totalMinutes).toBe(225);
    expect(summary.averageIntensity).toBe(2.6);
    expect(summary.focusMix.strength).toBe(1);
    expect(summary.focusMix.running).toBe(1);
    expect(summary.readinessScore).toBeGreaterThan(35);
  });

  it("keeps readiness bounded", () => {
    expect(calculateReadinessScore([])).toBe(100);
  });

  it("formats durations for compact UI", () => {
    expect(formatDuration(46)).toBe("46m");
    expect(formatDuration(120)).toBe("2h");
    expect(formatDuration(135)).toBe("2h 15m");
    expect(formatSleep(468)).toBe("7h 48m");
  });

  it("normalizes HealthKit sync payloads", () => {
    const payload = normalizeHealthKitSync({
      sourceDeviceId: " phone-1 ",
      capturedAt: "2026-08-14T07:00:00.000Z",
      snapshot: {
        ...todaySnapshot,
        recovery: { label: "Recovery", value: 110 },
        trainingLoad: { label: "Training load", value: -4 }
      }
    });

    expect(payload.sourceDeviceId).toBe("phone-1");
    expect(payload.snapshot.recovery.value).toBe(100);
    expect(payload.snapshot.trainingLoad.value).toBe(0);
  });

  it("normalizes APNs device registrations", () => {
    const registration = normalizePushDeviceRegistration({
      installationId: " install-1 ",
      platform: "ios",
      deviceToken: "ABCD1234 ",
      bundleId: " com.eojgroup.robur ",
      environment: "development",
      registeredAt: "2026-08-14T08:10:00.000Z"
    });

    expect(registration.installationId).toBe("install-1");
    expect(registration.deviceToken).toBe("abcd1234");
    expect(registration.bundleId).toBe("com.eojgroup.robur");
  });
});
