import { createHash, createPublicKey, verify, type JsonWebKey } from "node:crypto";
import { HttpError } from "./health-cloud.js";

export interface Principal { ownerId: string; kind: "google" | "device"; sourceDeviceId?: string }
export interface DeviceLookup { authenticateDevice(tokenHash: string): Promise<Principal | null> }
export type Authenticator = (token: string) => Promise<Principal>;
export const tokenHash = (value: string) => createHash("sha256").update(value).digest("hex");
interface GoogleKey extends JsonWebKey { kid: string; kty: string; n: string; e: string; alg?: string; use?: string }
export class GoogleIdentityVerifier {
  private keys: GoogleKey[] = [];
  private expires = 0;
  constructor(private readonly audience: string, private readonly request: typeof fetch = fetch) {}
  async verify(token: string): Promise<Principal> {
    if (!this.audience) throw new HttpError(503, "Google sign-in is not configured for this deployment.");
    try {
      const segments = token.split(".");
      if (segments.length !== 3 || token.length > 16000) throw new Error("JWT format");
      const header = JSON.parse(Buffer.from(segments[0], "base64url").toString("utf8")) as { alg?: string; kid?: string };
      const claims = JSON.parse(Buffer.from(segments[1], "base64url").toString("utf8")) as Record<string, unknown>;
      if (header.alg !== "RS256" || typeof header.kid !== "string") throw new Error("JWT algorithm");
      if (Date.now() >= this.expires || !this.keys.some(key => key.kid === header.kid)) {
        const response = await this.request("https://www.googleapis.com/oauth2/v3/certs", { signal: AbortSignal.timeout(10000) });
        if (!response.ok) throw new HttpError(503, "Sign-in verification is temporarily unavailable.");
        const payload = await response.json() as { keys?: GoogleKey[] };
        this.keys = payload.keys ?? [];
        this.expires = Date.now() + 60 * 60 * 1000;
      }
      const key = this.keys.find(key => key.kid === header.kid && key.kty === "RSA" && (!key.alg || key.alg === "RS256"));
      if (!key || !verify("RSA-SHA256", Buffer.from(`${segments[0]}.${segments[1]}`), createPublicKey({ key, format: "jwk" }), Buffer.from(segments[2], "base64url"))) throw new Error("JWT signature");
      const now = Date.now() / 1000;
      if (!["https://accounts.google.com", "accounts.google.com"].includes(claims.iss as string) || claims.aud !== this.audience ||
        typeof claims.exp !== "number" || claims.exp <= now || typeof claims.iat !== "number" || claims.iat > now + 60 ||
        typeof claims.sub !== "string" || !claims.sub || claims.sub.length > 255 || claims.email_verified !== true) throw new Error("JWT claims");
      return { ownerId: `google:${claims.sub}`, kind: "google" };
    } catch (error) {
      if (error instanceof HttpError) throw error;
      throw new HttpError(401, "Sign-in expired or invalid. Sign in again.");
    }
  }
}
export function createAuthenticator(clientId: string | undefined, store: DeviceLookup): Authenticator {
  const google = new GoogleIdentityVerifier(clientId ?? "");
  return async token => {
    if (token.startsWith("rbr_")) {
      const principal = await store.authenticateDevice(tokenHash(token));
      if (!principal) throw new HttpError(401, "Device connection expired or revoked. Pair again.");
      return principal;
    }
    return google.verify(token);
  };
}
