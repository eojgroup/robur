import { generateKeyPairSync, sign } from "node:crypto";
import { describe, expect, it } from "vitest";
import { GoogleIdentityVerifier } from "../src/auth";

const { publicKey, privateKey } = generateKeyPairSync("rsa", { modulusLength: 2048 });
function token(overrides: Record<string, unknown> = {}) {
  const header = Buffer.from(JSON.stringify({ alg: "RS256", kid: "test-key" })).toString("base64url");
  const body = Buffer.from(JSON.stringify({ iss: "https://accounts.google.com", aud: "robur-client",
    sub: "owner-a", iat: Date.now() / 1000 - 10, exp: Date.now() / 1000 + 300, email_verified: true, ...overrides })).toString("base64url");
  return `${header}.${body}.${sign("RSA-SHA256", Buffer.from(`${header}.${body}`), privateKey).toString("base64url")}`;
}
function verifier() {
  // Only the test public key is trusted; no Google request or account is used.
  const request = (async () => new Response(JSON.stringify({ keys: [{ ...publicKey.export({ format: "jwk" }), kid: "test-key", alg: "RS256" }] }), { status: 200 })) as typeof fetch;
  return new GoogleIdentityVerifier("robur-client", request);
}

describe("Google identity verification", () => {
  it("uses the verified stable subject, without retaining email or display name", async () => {
    expect(await verifier().verify(token())).toEqual({ ownerId: "google:owner-a", kind: "google" });
  });
  it("rejects a wrong audience, issuer, expiry, future issuance and unverified identity", async () => {
    for (const claims of [{ aud: "other-app" }, { iss: "https://attacker.invalid" }, { exp: 0 },
      { iat: Date.now() / 1000 + 3600 }, { email_verified: false }, { sub: "" }]) {
      await expect(verifier().verify(token(claims))).rejects.toMatchObject({ status: 401 });
    }
  });
  it("rejects tampered signatures and fails closed without production client configuration", async () => {
    const signed = token().split(".");
    signed[1] = Buffer.from(JSON.stringify({ sub: "owner-b" })).toString("base64url");
    await expect(verifier().verify(signed.join("."))).rejects.toMatchObject({ status: 401 });
    await expect(new GoogleIdentityVerifier("").verify(token())).rejects.toMatchObject({ status: 503 });
  });
});
