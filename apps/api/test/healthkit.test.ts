import { describe, expect, it } from "vitest";
import { todaySnapshot } from "@robur/core";
import { buildTodayResponse, parseHealthKitPayload } from "../src/healthkit";
import { parsePushDeviceRegistration } from "../src/push";

describe("HealthKit API shell", () => {
  it("returns the mock Today snapshot until HealthKit sync data arrives", () => {
    const response = buildTodayResponse(null);

    expect(response.source).toBe("mock");
    expect(response.snapshot.recovery.value).toBe(82);
    expect(response.recommendationLabel).toBe("40-55 min / Zone 2");
  });

  it("accepts a HealthKit sync payload", () => {
    const payload = parseHealthKitPayload({
      sourceDeviceId: "iphone-15-pro",
      capturedAt: "2026-08-14T07:20:00.000Z",
      snapshot: todaySnapshot
    });

    expect(payload.sourceDeviceId).toBe("iphone-15-pro");
    expect(payload.snapshot.sleepMinutes).toBe(468);
  });

  it("accepts an APNs device registration", () => {
    const registration = parsePushDeviceRegistration({
      installationId: "iphone-1",
      platform: "ios",
      deviceToken: "ABCDEF",
      bundleId: "com.eojgroup.robur",
      environment: "development",
      registeredAt: "2026-08-14T08:12:00.000Z"
    });

    expect(registration.deviceToken).toBe("abcdef");
  });
});
