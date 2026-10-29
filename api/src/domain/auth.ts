// Rules for sign-in: scopes by client type, lifetimes, and keyed hashes so codes and tokens are never stored in clear.
import type { ClientType, Scope } from "../ports";

export const ACCESS_TOKEN_SECONDS = 15 * 60;
export const REFRESH_TOKEN_SECONDS = 60 * 24 * 3600;
export const CODE_SECONDS = 10 * 60;
export const MAX_CODE_ATTEMPTS = 5;

/** Every client gets `app`; native clients also upload activities, the web client never does. */
export function scopesFor(clientType: ClientType): Scope[] {
  return clientType === "web" ? ["app"] : ["app", "activities:write"];
}

export function normaliseEmail(email: string): string {
  return email.trim().toLowerCase();
}

/** HMAC-SHA256 as hex. `purpose` keeps a code hash from ever equalling a token hash. */
export async function keyedHash(secret: string, purpose: "code" | "refresh", value: string): Promise<string> {
  const key = await crypto.subtle.importKey("raw", new TextEncoder().encode(secret), { name: "HMAC", hash: "SHA-256" }, false, ["sign"]);
  const mac = await crypto.subtle.sign("HMAC", key, new TextEncoder().encode(`${purpose}:${value}`));
  return [...new Uint8Array(mac)].map((b) => b.toString(16).padStart(2, "0")).join("");
}

/** Compares equal-length hex strings without stopping at the first difference. */
export function equalHashes(a: string, b: string): boolean {
  if (a.length !== b.length) return false;
  let diff = 0;
  for (let i = 0; i < a.length; i++) diff |= a.charCodeAt(i) ^ b.charCodeAt(i);
  return diff === 0;
}
