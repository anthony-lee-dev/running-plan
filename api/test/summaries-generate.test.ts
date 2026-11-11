import { beforeEach, describe, expect, it } from "vitest";
import { createApp } from "../src/app";
import { FakeNarrator, MemoryEmailSender, memoryDeps } from "../src/adapters/memory";
import { PAIN_GUIDANCE } from "../src/domain/run-summary-text";
import { NarratorError, type Deps } from "../src/ports";

const SECRET = "test-secret-test-secret-test-secret";
type Json = Record<string, any>; // eslint-disable-line @typescript-eslint/no-explicit-any
const id = (n: number) => `00000000-0000-4000-8000-${String(n).padStart(12, "0")}`;
const P = id(101);
const S1 = id(201);
const TODAY = "2026-11-02";
const GOOD = "A steady 10.0 km in 58 min at 5:50/km, with an average heart rate of 155 bpm. There are not yet enough runs of about this length in the last 4 weeks to compare it with.";
const answer = (paragraph: string) => JSON.stringify({ paragraph });

let app: ReturnType<typeof createApp>;
let email: MemoryEmailSender;
let token: string;
let narrator: FakeNarrator;
let overrides: Partial<Deps>;
let deps: Deps;

async function signIn(address = "runner@example.com"): Promise<string> {
  const headers = { "content-type": "application/json" };
  await app.request("/v1/auth/email/start", { method: "POST", body: JSON.stringify({ email: address }), headers });
  const res = await app.request("/v1/auth/email/verify", { method: "POST", body: JSON.stringify({ email: address, code: email.sent.at(-1)!.code, clientType: "ios" }), headers });
  return ((await res.json()) as { accessToken: string }).accessToken;
}
const call = (method: string, path: string, body?: unknown, as = token) =>
  app.request(path, { method, headers: { authorization: `Bearer ${as}`, ...(body !== undefined ? { "content-type": "application/json" } : {}) }, ...(body !== undefined ? { body: JSON.stringify(body) } : {}) });
const generate = (activityId: string, as = token, today: string | null = TODAY) => call("POST", `/v1/activities/${activityId}/summary:generate${today ? `?today=${today}` : ""}`, undefined, as);
const read = (activityId: string) => call("GET", `/v1/activities/${activityId}/summary?today=${TODAY}`);
const run = (n: number, localDate: string, over: Json = {}) => ({ source: "apple_health", externalId: `HK-${n}`, workoutType: "running", startedAt: `${localDate}T07:00:00-05:00`, localDate, durationSec: 3500, distanceM: 10000, avgHeartRate: 155, ...over });
const upload = async (items: Json[]) => ((await (await call("POST", "/v1/activities:batch", { activities: items })).json()) as Json).results.map((r: Json) => r.activityId) as string[];

async function start(script: (unknown | Error)[], extra: Partial<Deps> = {}) {
  narrator = new FakeNarrator(script);
  email = new MemoryEmailSender();
  overrides = { email, authConfig: { jwtSecret: SECRET }, narrator, ...extra };
  deps = memoryDeps(overrides);
  app = createApp(deps);
  token = await signIn();
  await call("POST", "/v1/plans", { id: P, goal: { type: "5k" }, startDate: "2026-10-26", weekCount: 8, source: "blank", adaptive: false, weeks: [], sessions: [{ id: S1, date: "2026-11-04", type: "easy", title: "My secret title", steps: [{ kind: "work", goal: { type: "distance", value: 6000 } }] }] });
}
beforeEach(() => start([answer(GOOD)]));

describe("POST /v1/activities/{id}/summary:generate", () => {
  it("needs a token, a valid today and one of the user's runs", async () => {
    const [a] = await upload([run(1, "2026-10-30")]);
    expect((await app.request(`/v1/activities/${a}/summary:generate?today=${TODAY}`, { method: "POST" })).status).toBe(401);
    expect((await generate(a!, token, null)).status).toBe(400);
    expect((await generate(id(999))).status).toBe(404);
    expect((await generate(a!, await signIn("other@example.com"))).status).toBe(404);
    expect(narrator.prompts).toHaveLength(0);
  });

  it("writes the AI paragraph, stores it, and serves it again without another model call", async () => {
    const [a] = await upload([run(1, "2026-10-30")]);
    const first = (await (await generate(a!)).json()) as Json;
    expect(first).toMatchObject({ text: GOOD, source: "ai", canGenerate: false, pain: false, nextStep: "Next planned session: Easy run, 6.0 km, on Wednesday." });
    expect(first.reason).toBeUndefined();
    expect(typeof first.generatedAt).toBe("string");
    expect(await (await generate(a!)).json()).toEqual(first);
    expect(narrator.prompts).toHaveLength(1);
    expect(await (await read(a!)).json()).toEqual(first);
  });

  it("sends the model the facts only: no note, title, id or date", async () => {
    const [a] = await upload([run(1, "2026-10-30")]);
    await call("PUT", `/v1/sessions/${S1}/match`, { activityId: a, status: "confirmed" });
    await call("POST", `/v1/sessions/${S1}/checkins`, { id: id(301), when: "after", feel: 4, effortFelt: 6, note: "my knee hurts, call 555-1234" });
    await generate(a!);
    const sent = JSON.stringify(narrator.prompts);
    for (const leak of ["knee", "555", "secret", a!, S1, P, "2026-1", "runner@example.com", "apple_health", "HK-1"]) expect(sent).not.toContain(leak);
    expect(narrator.prompts[0]!.user).toContain("4 out of 5");
  });

  it("writes the answer again once when it fails the checks, and counts both calls", async () => {
    await start([answer("A steady 10.0 km in 59 min at 5:50/km, with an average heart rate of 155 bpm and more."), answer(GOOD)]);
    const [a] = await upload([run(1, "2026-10-30")]);
    expect(await (await generate(a!)).json()).toMatchObject({ source: "ai", text: GOOD });
    expect(narrator.prompts).toHaveLength(2);
  });

  it.each([
    ["an invented number", answer(GOOD.replace("155 bpm", "158 bpm"))],
    ["an injury word", answer(`${GOOD} It may be an injury.`)],
    ["advice", answer(`${GOOD} You should rest.`)],
    ["not JSON", "Here is your summary: a nice run."],
    ["JSON of another shape", JSON.stringify({ text: GOOD })],
    ["an extra key", JSON.stringify({ paragraph: GOOD, note: "x" })],
    ["nothing", undefined],
    ["an empty paragraph", answer("")],
    ["a long paragraph", answer(`${GOOD} ${"Another sentence. ".repeat(80)}`)],
  ])("shows the template and remembers it when the model gives %s twice", async (_name, bad) => {
    await start([bad]);
    const [a] = await upload([run(1, "2026-10-30")]);
    const res = (await (await generate(a!)).json()) as Json;
    expect(res).toMatchObject({ source: "template", reason: "check_failed", canGenerate: false });
    expect(res.text).toContain("10.0 km in 58 min at 5:50/km");
    expect(narrator.prompts).toHaveLength(2);
    // Reopening the run, or asking again, spends nothing more.
    expect(await (await read(a!)).json()).toMatchObject({ source: "template", reason: "check_failed", canGenerate: false });
    await generate(a!);
    expect(narrator.prompts).toHaveLength(2);
  });

  it.each([
    ["times out", new NarratorError("timeout"), "ai_unavailable"],
    ["fails", new NarratorError("unavailable"), "ai_unavailable"],
    ["throws something else", new Error("boom: secret text"), "ai_unavailable"],
    ["has used up its allowance", new NarratorError("quota"), "over_limit"],
  ])("answers the template without storing it when the model %s", async (_name, error, reason) => {
    await start([error]);
    const [a] = await upload([run(1, "2026-10-30")]);
    expect(await (await generate(a!)).json()).toMatchObject({ source: "template", reason, canGenerate: false });
    expect(narrator.prompts).toHaveLength(1);
    expect(await (await read(a!)).json()).toMatchObject({ source: "template", reason: "not_generated", canGenerate: true });
  });

  it("is the template when no model is wired", async () => {
    await start([answer(GOOD)], { narrator: undefined });
    const [a] = await upload([run(1, "2026-10-30")]);
    expect(await (await generate(a!)).json()).toMatchObject({ source: "template", reason: "ai_unavailable" });
  });

  it("never calls the model with the kill switch off or the account's switch off", async () => {
    await start([answer(GOOD)], { summaryConfig: { aiEnabled: false, dailyCallCap: 600 } });
    let [a] = await upload([run(1, "2026-10-30")]);
    expect(await (await generate(a!)).json()).toMatchObject({ source: "template", reason: "disabled" });
    expect(await (await read(a!)).json()).toMatchObject({ reason: "disabled", canGenerate: false });
    await start([answer(GOOD)]);
    [a] = await upload([run(1, "2026-10-30")]);
    await app.request("/v1/profile", { method: "PATCH", body: JSON.stringify({ aiSummaries: false }), headers: { authorization: `Bearer ${token}`, "content-type": "application/json", "if-match": '"1"' } });
    expect(await (await generate(a!)).json()).toMatchObject({ source: "template", reason: "disabled" });
    expect(narrator.prompts).toHaveLength(0);
  });

  it("hides a stored paragraph while the kill switch is off", async () => {
    const [a] = await upload([run(1, "2026-10-30")]);
    await generate(a!);
    app = createApp({ ...deps, summaryConfig: { aiEnabled: false, dailyCallCap: 600 } });
    expect(await (await read(a!)).json()).toMatchObject({ source: "template", reason: "disabled", canGenerate: false });
  });

  it("writes it again when the run's data changes, and not when only the other runs do", async () => {
    const [a] = await upload([run(1, "2026-10-30")]);
    await generate(a!);
    await upload([run(2, "2026-10-29")]); // another similar run, still under three: nothing changes
    expect((await (await read(a!)).json() as Json).source).toBe("ai");
    await call("PUT", `/v1/sessions/${S1}/match`, { activityId: a, status: "confirmed" });
    expect(await (await read(a!)).json()).toMatchObject({ source: "template", canGenerate: true });
    await generate(a!);
    expect(narrator.prompts).toHaveLength(2);
  });

  it("holds the global daily cap: each model call counts, and over it the template is shown and nothing is stored", async () => {
    const bad = answer(GOOD.replace("155", "158"));
    await start([bad, answer(GOOD), bad, answer(GOOD)], { summaryConfig: { aiEnabled: true, dailyCallCap: 3 } });
    const ids = await upload([run(1, "2026-10-30"), run(2, "2026-10-29", { distanceM: 20000 })]);
    // Call 1 fails the checks, call 2 is good: the first run is written with two calls.
    expect(await (await generate(ids[0]!)).json()).toMatchObject({ source: "ai" });
    expect(narrator.prompts).toHaveLength(2);
    // Call 3 fails the checks; the retry would be call 4, over the cap of 3: template, over_limit, nothing remembered.
    expect(await (await generate(ids[1]!)).json()).toMatchObject({ source: "template", reason: "over_limit" });
    expect(narrator.prompts).toHaveLength(3);
    expect(await (await read(ids[1]!)).json()).toMatchObject({ reason: "not_generated", canGenerate: true });
    // Further requests do not reach the model at all.
    await generate(ids[1]!);
    expect(narrator.prompts).toHaveLength(3);
  });

  it("after the model's allowance is used up, later requests do not call it", async () => {
    await start([new NarratorError("quota"), answer(GOOD)]);
    const [a, b] = await upload([run(1, "2026-10-30"), run(2, "2026-10-29", { distanceM: 20000 })]);
    expect(await (await generate(a!)).json()).toMatchObject({ source: "template", reason: "over_limit" });
    expect(await (await generate(b!)).json()).toMatchObject({ source: "template", reason: "over_limit" });
    expect(narrator.prompts).toHaveLength(1);
  });

  it("a request over the account's limit does not touch the global cap", async () => {
    await start([answer(GOOD)], { summaryConfig: { aiEnabled: true, dailyCallCap: 600 } });
    const batch = Array.from({ length: 31 }, (_v, i) => run(i + 1, "2026-10-30", { startedAt: `2026-10-30T${String(i % 24).padStart(2, "0")}:${i < 24 ? "00" : "30"}:00-05:00` }));
    for (const x of await upload(batch)) await generate(x);
    expect(await deps.rateLimiter.peek("summary:global:day", 86_400, new Date())).toBe(30);
  });

  it("limits an account to 30 generations an hour with a 429", async () => {
    const batch = Array.from({ length: 32 }, (_v, i) => run(i + 1, "2026-10-30", { startedAt: `2026-10-30T${String(i % 24).padStart(2, "0")}:${i < 24 ? "00" : "30"}:00-05:00` }));
    const ids = await upload(batch);
    expect(new Set(ids).size).toBe(32);
    let limited: Response | undefined;
    for (const x of ids) {
      const res = await generate(x);
      if (res.status === 429) {
        limited = res;
        break;
      }
    }
    expect(limited?.status).toBe(429);
    expect(Number(limited!.headers.get("retry-after"))).toBeGreaterThan(0);
    expect(narrator.prompts).toHaveLength(30);
  });

  it("with pain flagged: the model is told to state numbers only, the guidance is the next step, and wording is stricter", async () => {
    const neutral = GOOD.replace("A steady", "A");
    await start([answer(`${neutral} A good, solid effort.`), answer(neutral)]);
    const [a] = await upload([run(1, "2026-10-30")]);
    await call("PUT", `/v1/sessions/${S1}/match`, { activityId: a, status: "confirmed" });
    await call("POST", `/v1/sessions/${S1}/checkins`, { id: id(301), when: "after", feel: 2, effortFelt: 9, pain: true });
    const res = (await (await generate(a!)).json()) as Json;
    expect(res).toMatchObject({ source: "ai", pain: true, nextStep: PAIN_GUIDANCE });
    expect(narrator.prompts).toHaveLength(2); // the praise failed the strict check
    expect(narrator.prompts[0]!.system).toContain("neutral statement of the numbers");
    expect(narrator.prompts[0]!.user).not.toMatch(/pain|felt|effort|rating/i);
  });
});
