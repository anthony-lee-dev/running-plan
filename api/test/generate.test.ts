import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import { createApp } from "../src/app";
import { memoryDeps } from "../src/adapters/memory";
import { GENERATE_PER_DEVICE, GENERATE_PER_IP, MAX_GENERATE_BODY_BYTES, MAX_GENERATE_RESPONSE_BYTES } from "../src/http/generate";
import { generatePlan, type PlanDraft } from "../src/domain/engine";

type Json = Record<string, any>; // eslint-disable-line @typescript-eslint/no-explicit-any

const body = { answers: { goal: { distance: "5k", date: "2027-01-10" }, weeklyDistanceM: 15000, runsPerWeek: 3 }, today: "2026-11-02" };
const largest = {
  answers: {
    goal: { distance: "half_marathon", date: "2027-12-31", targetTimeSec: 6000 },
    recentResult: { distanceM: 10000, timeSec: 2700 },
    weeklyDistanceM: 80000,
    longestRunM: 25000,
    runningHistory: "over_3_years",
    runsPerWeek: 5,
    strength: { enabled: true, equipment: "dumbbells" },
    targetDisplay: "heart_rate",
    heartRate: { maxBpm: 195, zones: [{ minBpm: 100, maxBpm: 125 }, { minBpm: 125, maxBpm: 145 }, { minBpm: 145, maxBpm: 165 }, { minBpm: 165, maxBpm: 180 }, { minBpm: 180, maxBpm: 195 }] },
  },
  today: "2026-11-02",
};

let app: ReturnType<typeof createApp>;
beforeEach(() => {
  app = createApp(memoryDeps());
});
afterEach(() => vi.restoreAllMocks());

const post = (payload: unknown, headers: Record<string, string> = {}, target = app) =>
  target.request("/v1/plans/generate", {
    method: "POST",
    headers: { "content-type": "application/json", "cf-connecting-ip": "203.0.113.1", ...headers },
    body: typeof payload === "string" ? payload : JSON.stringify(payload),
  });

describe("POST /v1/plans/generate", () => {
  it("returns a plan draft without signing in", async () => {
    const res = await post(body);
    expect(res.status).toBe(200);
    const draft = (await res.json()) as Json;
    expect(draft).toMatchObject({ goal: { type: "5k", date: "2027-01-10" }, source: "rules", adaptive: true, engine: { presetId: "5k" } });
    expect(draft.weeks.length).toBe(draft.weekCount);
    expect(draft.sessions.length).toBeGreaterThan(0);
    expect(Array.isArray(draft.assumptions)).toBe(true);
    expect(Array.isArray(draft.warnings)).toBe(true);
  });

  it("gives the same draft for the same request", async () => {
    expect(await (await post(body)).text()).toBe(await (await post(body)).text());
  });

  it("echoes only the validated answers in the engine snapshot", async () => {
    const draft = (await (await post(body)).json()) as Json;
    expect(draft.engine.interview).toEqual(body.answers);
  });

  it("stores nothing: a following signed-out plans list still needs a token", async () => {
    await post(body);
    expect((await app.request("/v1/plans")).status).toBe(401);
  });

  it("answers 400 with every invalid field", async () => {
    const res = await post({ answers: { goal: { distance: "marathon" }, runsPerWeek: 9 }, today: "2026-11-02" });
    expect(res.status).toBe(400);
    expect(res.headers.get("content-type")).toContain("application/problem+json");
    const problem = (await res.json()) as Json;
    expect(problem.type).toBe("validation_failed");
    expect(problem.errors.map((e: Json) => e.path).sort()).toEqual(["/answers/goal/distance", "/answers/runsPerWeek"]);
  });

  it("answers 400 to an unknown preset", async () => {
    expect((await post({ ...body, presetId: "marathon" })).status).toBe(400);
  });

  it("answers 400 to a body that is not JSON", async () => {
    expect((await post("{not json")).status).toBe(400);
  });

  it("answers 400 to a device id that is not a UUID", async () => {
    expect((await post(body, { "x-device-id": "not-a-uuid" })).status).toBe(400);
  });

  it("answers 413 to a body over the limit, by header or by size", async () => {
    const padded = JSON.stringify(body).replace("}", `,"pad":"${"x".repeat(MAX_GENERATE_BODY_BYTES)}"}`);
    expect((await post(padded)).status).toBe(413);
    expect((await post(body, { "content-length": String(MAX_GENERATE_BODY_BYTES + 1) })).status).toBe(413);
  });

  it("rate limits by IP, with Retry-After", async () => {
    for (let i = 0; i < GENERATE_PER_IP; i++) expect((await post(body)).status).toBe(200);
    const limited = await post(body);
    expect(limited.status).toBe(429);
    expect(Number(limited.headers.get("retry-after"))).toBeGreaterThan(0);
    expect((await post(body, { "cf-connecting-ip": "203.0.113.2" })).status).toBe(200);
  });

  it("rate limits by device across IPs", async () => {
    const device = { "x-device-id": "6f1c3a4e-2b7d-4c1e-9f0a-1b2c3d4e5f60" };
    for (let i = 0; i < GENERATE_PER_DEVICE; i++) expect((await post(body, { ...device, "cf-connecting-ip": `198.51.100.${i % 200}` })).status).toBe(200);
    expect((await post(body, { ...device, "cf-connecting-ip": "198.51.100.250" })).status).toBe(429);
  });

  it("counts a rate-limit hit before reading the body", async () => {
    for (let i = 0; i < GENERATE_PER_IP; i++) await post("{bad");
    expect((await post(body)).status).toBe(429);
  });

  it("logs nothing about the answers, on success or failure", async () => {
    const spies = (["log", "info", "warn", "error", "debug"] as const).map((m) => vi.spyOn(console, m).mockImplementation(() => {}));
    await post(largest);
    await post({ ...body, answers: { ...body.answers, runsPerWeek: 9 } });
    const failing = createAppWith(() => {
      throw new Error(`boom with ${JSON.stringify(body.answers)}`);
    });
    expect((await post(body, {}, failing)).status).toBe(500);
    const logged = spies.flatMap((s) => s.mock.calls.flat()).map(String).join("\n");
    expect(logged).not.toContain("15000");
    expect(logged).not.toContain("2027-01-10");
  });

  it("answers 422 when no plan fits the answers", async () => {
    const res = await post(body, {}, createAppWith(() => {
      throw new RangeError("at least 3 days a week must be available to run");
    }));
    expect(res.status).toBe(422);
    expect(((await res.json()) as Json).type).toBe("no_plan_fits");
  });

  it("keeps the largest plan under the response cap", async () => {
    const res = await post(largest);
    expect(res.status).toBe(200);
    expect(new TextEncoder().encode(await res.text()).length).toBeLessThan(MAX_GENERATE_RESPONSE_BYTES);
  });

  it("refuses to send a draft over the response cap", async () => {
    const huge = (input: Parameters<typeof generatePlan>[0]): PlanDraft => {
      const draft = generatePlan(input);
      return { ...draft, assumptions: Array.from({ length: 2000 }, () => ({ code: "x", message: "y".repeat(400) })) };
    };
    expect((await post(body, {}, createAppWith(huge))).status).toBe(500);
  });
});

/** The app with a stand-in engine, to reach failures the real engine cannot produce from valid input. */
function createAppWith(generate: typeof generatePlan) {
  return createApp(memoryDeps(), { generate });
}
