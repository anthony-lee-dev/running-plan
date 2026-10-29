// Small strict validators for request bodies: unknown fields are rejected, as the spec's
// `additionalProperties: false` requires.
import type { ClientType } from "../ports";

export type Body = Record<string, unknown>;

export async function readBody(request: Request): Promise<Body | undefined> {
  try {
    const value: unknown = await request.json();
    return value !== null && typeof value === "object" && !Array.isArray(value) ? (value as Body) : undefined;
  } catch {
    return undefined;
  }
}

/** True when the body has only these keys. */
export const onlyKeys = (body: Body, keys: string[]): boolean => Object.keys(body).every((k) => keys.includes(k));

const EMAIL = /^[^\s@]+@[^\s@]+\.[^\s@]+$/;
export const isEmail = (v: unknown): v is string => typeof v === "string" && v.length <= 254 && EMAIL.test(v);
export const isCode = (v: unknown): v is string => typeof v === "string" && /^[0-9]{6}$/.test(v);
export const isClientType = (v: unknown): v is ClientType => v === "ios" || v === "android" || v === "web";
