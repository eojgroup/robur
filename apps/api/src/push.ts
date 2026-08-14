import { type PushDeviceRegistration, normalizePushDeviceRegistration } from "@robur/core";

export function parsePushDeviceRegistration(input: unknown): PushDeviceRegistration {
  if (!isRecord(input)) {
    throw new Error("Payload must be a JSON object.");
  }

  if (typeof input.installationId !== "string" || input.installationId.trim() === "") {
    throw new Error("installationId is required.");
  }

  if (input.platform !== "ios" && input.platform !== "watchos") {
    throw new Error("platform must be ios or watchos.");
  }

  if (typeof input.deviceToken !== "string" || input.deviceToken.trim() === "") {
    throw new Error("deviceToken is required.");
  }

  if (typeof input.bundleId !== "string" || input.bundleId.trim() === "") {
    throw new Error("bundleId is required.");
  }

  if (input.environment !== "development" && input.environment !== "production") {
    throw new Error("environment must be development or production.");
  }

  if (typeof input.registeredAt !== "string" || Number.isNaN(Date.parse(input.registeredAt))) {
    throw new Error("registeredAt must be an ISO timestamp.");
  }

  return normalizePushDeviceRegistration({
    installationId: input.installationId,
    platform: input.platform,
    deviceToken: input.deviceToken,
    bundleId: input.bundleId,
    environment: input.environment,
    registeredAt: input.registeredAt
  });
}

function isRecord(value: unknown): value is Record<string, unknown> {
  return typeof value === "object" && value !== null && !Array.isArray(value);
}
