// `POST /v1/plans/generate` (design §7): stateless and unauthenticated. Nothing is stored and the answers are never
// logged. Abuse controls: rate limits by IP and by `X-Device-Id`, counted before the body is read; a small body cap;
// strict validation; and a cap on the response size. The engine is bounded by the schema (at most 16 weeks).
import { Hono } from "hono";
import { generatePlan } from "../domain/engine";
import { parseGenerateRequest } from "../domain/generate-input";
import type { Deps } from "../ports";
import { problem } from "./problem";

export const GENERATE_PER_IP = 300; // an hour; generous because mobile carriers share addresses
export const GENERATE_PER_DEVICE = 120; // an hour; the preview regenerates on each changed answer
export const MAX_GENERATE_BODY_BYTES = 16_384;
export const MAX_GENERATE_RESPONSE_BYTES = 262_144;
const HOUR = 3600;
const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;

export function generateRoutes(deps: Deps, generate: typeof generatePlan = generatePlan) {
  const app = new Hono();

  app.post("/v1/plans/generate", async (c) => {
    const device = c.req.header("x-device-id");
    if (device !== undefined && !UUID.test(device)) return problem(c, 400, "bad_request", "X-Device-Id must be a UUID");

    const now = deps.clock.now();
    const keys = [`generate:ip:${c.req.header("cf-connecting-ip") ?? "unknown"}`, ...(device ? [`generate:device:${device.toLowerCase()}`] : [])];
    const limits = [GENERATE_PER_IP, GENERATE_PER_DEVICE];
    for (const [i, key] of keys.entries()) {
      const result = await deps.rateLimiter.hit(key, limits[i]!, HOUR, now);
      if (!result.allowed) return problem(c, 429, "rate_limited", "Too many requests", { "retry-after": String(result.retryAfterSec) });
    }

    const tooLarge = () => problem(c, 413, "payload_too_large", "That is too large");
    if (Number(c.req.header("content-length") ?? 0) > MAX_GENERATE_BODY_BYTES) return tooLarge();
    const text = await c.req.text();
    if (new TextEncoder().encode(text).length > MAX_GENERATE_BODY_BYTES) return tooLarge();
    let body: unknown;
    try {
      body = JSON.parse(text);
    } catch {
      return problem(c, 400, "bad_request", "Send JSON");
    }

    const parsed = parseGenerateRequest(body);
    if (!parsed.ok) return problem(c, 400, "validation_failed", "Some fields are invalid", {}, { errors: parsed.errors });

    let draft;
    try {
      draft = generate(parsed.value);
    } catch (error) {
      if (error instanceof RangeError) return problem(c, 422, "no_plan_fits", "No plan fits these answers", {}, { alternatives: [] });
      // A fresh error, so nothing from the answers reaches the error log.
      throw new Error("plan generation failed");
    }

    const out = JSON.stringify(draft);
    if (new TextEncoder().encode(out).length > MAX_GENERATE_RESPONSE_BYTES) throw new Error("plan draft over the response cap");
    return new Response(out, { status: 200, headers: { "content-type": "application/json" } });
  });

  return app;
}
