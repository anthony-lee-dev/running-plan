import { beforeEach, describe, expect, it } from "vitest";
import { createApp } from "../src/app";
import { MemoryEmailSender, memoryDeps } from "../src/adapters/memory";
import { PAIN_GUIDANCE, PROMPT_VERSION } from "../src/domain/run-summary-text";
import type { Deps } from "../src/ports";

const SECRET = "test-secret-test-secret-test-secret";
type Json = Record<string, any>; // eslint-disable-line @typescript-eslint/no-explicit-any
const id = (n: number) => `00000000-0000-4000-8000-${String(n).padStart(12, "0")}`;
const P = id(101);
const S1 = id(201);
const S2 = id(202);
const TODAY = "2026-11-02";

let app: ReturnType<typeof createApp>;
let deps: Deps;
let email: MemoryEmailSender;
let token: string;

async function signIn(address = "runner@example.com"): Promise<string> {
  const headers = { "content-type": "application/json" };
  await app.request("/v1/auth/email/start", { method: "POST", body: JSON.stringify({ email: address }), headers });
  const res = await app.request("/v1/auth/email/verify", { method: "POST", body: JSON.stringify({ email: address, code: email.sent.at(-1)!.code, clientType: "ios" }), headers });
  return ((await res.json()) as { accessToken: string }).accessToken;
}
const call = (method: string, path: string, body?: unknown, as = token) =>
  app.request(path, { method, headers: { authorization: `Bearer ${as}`, ...(body !== undefined ? { "content-type": "application/json" } : {}) }, ...(body !== undefined ? { body: JSON.stringify(body) } : {}) });
const summary = async (activityId: string, as = token, today: string | null = TODAY) => call("GET", `/v1/activities/${activityId}/summary${today ? `?today=${today}` : ""}`, undefined, as);

const session = (sid: string, date: string, type = "easy", km = 6) => ({ id: sid, date, type, steps: [{ kind: "work", goal: { type: "distance", value: km * 1000 } }] });
const upload = async (items: Json[]) => ((await (await call("POST", "/v1/activities:batch", { activities: items })).json()) as Json).results.map((r: Json) => r.activityId) as string[];
const run = (n: number, localDate: string, over: Json = {}) => ({ source: "apple_health", externalId: `HK-${n}`, workoutType: "running", startedAt: `${localDate}T07:00:00-05:00`, localDate, durationSec: 3500, distanceM: 10000, avgHeartRate: 155, ...over });

beforeEach(async () => {
  email = new MemoryEmailSender();
  deps = memoryDeps({ email, authConfig: { jwtSecret: SECRET } });
  app = createApp(deps);
  token = await signIn();
  await call("POST", "/v1/plans", { id: P, goal: { type: "5k" }, startDate: "2026-10-26", weekCount: 8, source: "blank", adaptive: false, weeks: [], sessions: [session(S1, "2026-10-30", "easy", 10), session(S2, "2026-11-04", "easy", 6)] });
});

describe("GET /v1/activities/{id}/summary", () => {
  it("needs a token and a valid today", async () => {
    const [a] = await upload([run(1, "2026-10-30")]);
    expect((await app.request(`/v1/activities/${a}/summary?today=${TODAY}`)).status).toBe(401);
    expect((await summary(a!, token, null)).status).toBe(400);
    expect((await summary(a!, token, "2026-13-40")).status).toBe(400);
  });

  it("gives the template for a first run, with nothing to compare", async () => {
    const [a] = await upload([run(1, "2026-10-30")]);
    const body = (await (await summary(a!)).json()) as Json;
    expect(body).toMatchObject({ source: "template", reason: "not_generated", canGenerate: true, pain: false });
    expect(body.text).toContain("10.0 km in 58 min at 5:50/km");
    expect(body.text).toContain("not yet enough runs");
    expect(body.generatedAt).toBeUndefined();
  });

  it("names the next planned session after today, from the plan", async () => {
    const [a] = await upload([run(1, "2026-10-30")]);
    expect(((await (await summary(a!)).json()) as Json).nextStep).toBe("Next planned session: Easy run, 6.0 km, on Wednesday.");
    expect(((await (await summary(a!, token, "2026-11-04")).json()) as Json).nextStep).toBeUndefined();
  });

  it("compares with at least three similar runs, and not with fewer", async () => {
    const ids = await upload([run(1, "2026-10-30", { durationSec: 3300 }), run(2, "2026-10-25"), run(3, "2026-10-20", { durationSec: 3600 }), run(4, "2026-10-15")]);
    expect(((await (await summary(ids[0]!)).json()) as Json).text).toContain("quicker than your 3 other runs");
    const few = await upload([run(5, "2026-10-12"), run(6, "2026-10-11")]);
    expect(((await (await summary(few[0]!)).json()) as Json).text).toContain("not yet enough runs");
  });

  it("uses the matched session and its after-run check-in", async () => {
    const [a] = await upload([run(1, "2026-10-30")]);
    await call("PUT", `/v1/sessions/${S1}/match`, { activityId: a, status: "confirmed" });
    await call("POST", `/v1/sessions/${S1}/checkins`, { id: id(301), when: "after", feel: 4, effortFelt: 6 });
    const body = (await (await summary(a!)).json()) as Json;
    expect(body.text).toContain("matched to an easy run that planned 10.0 km");
    expect(body.text).toContain("how it felt 4 out of 5 and the effort 6 out of 10");
    expect(body.pain).toBe(false);
  });

  it("does not compare an interval session with other runs", async () => {
    await call("POST", `/v1/plans/${P}/sessions`, session(id(203), "2026-10-29", "intervals", 8));
    const ids = await upload([run(1, "2026-10-29"), run(2, "2026-10-25"), run(3, "2026-10-20"), run(4, "2026-10-15")]);
    await call("PUT", `/v1/sessions/${id(203)}/match`, { activityId: ids[0], status: "confirmed" });
    expect(((await (await summary(ids[0]!)).json()) as Json).text).toContain("not yet enough runs");
  });

  it("with pain flagged: the fixed guidance replaces the next step, and the check-in numbers stay out", async () => {
    const [a] = await upload([run(1, "2026-10-30")]);
    await call("PUT", `/v1/sessions/${S1}/match`, { activityId: a, status: "confirmed" });
    await call("POST", `/v1/sessions/${S1}/checkins`, { id: id(301), when: "after", feel: 2, effortFelt: 9, pain: true });
    const body = (await (await summary(a!)).json()) as Json;
    expect(body).toMatchObject({ pain: true, nextStep: PAIN_GUIDANCE });
    expect(body.text).not.toMatch(/pain|hurt|felt|effort|Next planned/i);
  });

  it("is a 404 for another user's run, an unknown id, a non-run and an ignored run", async () => {
    const [a, b, c] = await upload([run(1, "2026-10-30"), run(2, "2026-10-29", { workoutType: "strength", distanceM: undefined }), run(3, "2026-10-28")]);
    await call("PATCH", `/v1/activities/${c}`, { disposition: "ignored" });
    const other = await signIn("other@example.com");
    expect((await summary(a!, other)).status).toBe(404);
    for (const x of [id(999), "nope", b!, c!]) expect((await summary(x)).status).toBe(404);
  });

  it("serves the stored AI paragraph while the facts are unchanged, and the template once they change", async () => {
    const [a] = await upload([run(1, "2026-10-30")]);
    const first = (await (await summary(a!)).json()) as Json;
    expect(first.canGenerate).toBe(true);
    // Another test writes through the generate route (slice 3); here the store is filled directly.
    const { loadSummaryContext } = await import("../src/http/summaries");
    const userId = (await deps.auth.findOrCreateUser("runner@example.com", id(1), "x")).user.id;
    const ctx = (await loadSummaryContext(deps, userId, a!, TODAY))!;
    await deps.summaries.put(userId, { activityId: a!, factsHash: ctx.factsHash, promptVersion: PROMPT_VERSION, model: "m", source: "ai", text: "Written by a model.", createdAt: "2026-11-02T10:00:00.000Z" });
    expect(await (await summary(a!)).json()).toMatchObject({ source: "ai", text: "Written by a model.", canGenerate: false, generatedAt: "2026-11-02T10:00:00.000Z" });
    // A check-in moves the facts: the stored text no longer matches them.
    await call("PUT", `/v1/sessions/${S1}/match`, { activityId: a, status: "confirmed" });
    await call("POST", `/v1/sessions/${S1}/checkins`, { id: id(301), when: "after", feel: 4 });
    expect(await (await summary(a!)).json()).toMatchObject({ source: "template", reason: "not_generated", canGenerate: true });
  });

  it("serves a remembered failure as the template without offering another try", async () => {
    const [a] = await upload([run(1, "2026-10-30")]);
    const { loadSummaryContext } = await import("../src/http/summaries");
    const user = (await deps.auth.findOrCreateUser("runner@example.com", id(1), "x")).user.id;
    const ctx = (await loadSummaryContext(deps, user, a!, TODAY))!;
    await deps.summaries.put(user, { activityId: a!, factsHash: ctx.factsHash, promptVersion: PROMPT_VERSION, model: "m", source: "template", reason: "check_failed", text: "x", createdAt: "2026-11-02T10:00:00.000Z" });
    expect(await (await summary(a!)).json()).toMatchObject({ source: "template", reason: "check_failed", canGenerate: false });
  });

  it("is the template with reason disabled when the account's switch is off", async () => {
    const [a] = await upload([run(1, "2026-10-30")]);
    await app.request("/v1/profile", { method: "PATCH", body: JSON.stringify({ aiSummaries: false }), headers: { authorization: `Bearer ${token}`, "content-type": "application/json", "if-match": '"1"' } });
    expect(await (await summary(a!)).json()).toMatchObject({ source: "template", reason: "disabled", canGenerate: false });
  });
});
