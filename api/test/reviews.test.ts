import { beforeEach, describe, expect, it } from "vitest";
import { createApp } from "../src/app";
import { FixedClock, MemoryEmailSender, memoryDeps } from "../src/adapters/memory";

const SECRET = "test-secret-test-secret-test-secret";
type Json = Record<string, any>; // eslint-disable-line @typescript-eslint/no-explicit-any
const id = (n: number) => `00000000-0000-4000-8000-${String(n).padStart(12, "0")}`;
const P = id(101);
const TODAY = "2026-11-09"; // a Monday, the day after week 1 (2026-11-02 to 2026-11-08) ends
const run = (sid: string, date: string, over: Json = {}) => ({ id: sid, date, type: "easy", key: false, steps: [{ kind: "work", goal: { type: "distance", value: 5000 }, target: { type: "effort", effort: "easy" } }], ...over });
const S_KEY = id(201);
const S_EASY = id(202);
const S_NEXT = id(203);
const S_NEXT2 = id(204);

let app: ReturnType<typeof createApp>;
let email: MemoryEmailSender;
let token: string;

async function signIn(address = "runner@example.com"): Promise<string> {
  const headers = { "content-type": "application/json" };
  await app.request("/v1/auth/email/start", { method: "POST", body: JSON.stringify({ email: address }), headers });
  const res = await app.request("/v1/auth/email/verify", { method: "POST", body: JSON.stringify({ email: address, code: email.sent.at(-1)!.code, clientType: "ios" }), headers });
  return ((await res.json()) as { accessToken: string }).accessToken;
}
const call = (method: string, path: string, body?: unknown, as: string | undefined = token, headers: Record<string, string> = {}) =>
  app.request(path, {
    method,
    headers: { ...(as ? { authorization: `Bearer ${as}` } : {}), ...(body !== undefined ? { "content-type": "application/json" } : {}), ...headers },
    ...(body !== undefined ? { body: JSON.stringify(body) } : {}),
  });
const json = async (res: Response) => (await res.json()) as Json;
const review = (week: string | number = 0, today: string | null = TODAY, planId = P, as: string | null = token) =>
  app.request(`/v1/plans/${planId}/reviews/${week}${today === null ? "" : `?today=${today}`}`, { headers: as === null ? {} : { authorization: `Bearer ${as}` } });
const setReview = async (frequency: string) => {
  const profile = await json(await call("GET", "/v1/profile"));
  await call("PATCH", "/v1/profile", { review: { frequency } }, token, { "if-match": `"${profile.revision}"` });
};
const createPlan = (over: Json = {}) =>
  call("POST", "/v1/plans", {
    id: P, goal: { type: "5k", date: "2027-01-10" }, startDate: "2026-11-02", weekCount: 8, source: "rules", engine: { presetId: "5k", version: "0.2.0" }, adaptive: true,
    weeks: [{ index: 0, phase: "base" }],
    sessions: [run(S_KEY, "2026-11-03", { key: true, title: "Tempo" }), run(S_EASY, "2026-11-05"), run(S_NEXT, "2026-11-10", { owner: "system" }), run(S_NEXT2, "2026-11-12", { owner: "system" })],
    ...over,
  });
const upload = async (n: number, localDate = "2026-11-03") => {
  const act = { source: "apple_health", externalId: `HK-${n}`, workoutType: "running", startedAt: `${localDate}T07:00:00-05:00`, localDate, durationSec: 1800, distanceM: 5200 };
  const up = await json(await call("POST", "/v1/activities:batch", { activities: [act] }));
  return up.results[0].activityId as string;
};

beforeEach(async () => {
  email = new MemoryEmailSender();
  app = createApp(memoryDeps({ email, authConfig: { jwtSecret: SECRET }, clock: new FixedClock(new Date(`${TODAY}T12:00:00Z`)) }));
  token = await signIn();
  await createPlan();
});

describe("GET /v1/plans/{id}/reviews/{weekIndex}", () => {
  it("summarises the week: sessions, distance, time, key sessions, check-ins and the inbox", async () => {
    const hit = await upload(1);
    await call("PUT", `/v1/sessions/${S_KEY}/match`, { activityId: hit, status: "confirmed" });
    await call("POST", `/v1/sessions/${S_KEY}/checkins`, { id: id(301), when: "after", feel: 4, effortFelt: 6 });
    await call("POST", `/v1/sessions/${S_EASY}/checkins`, { id: id(302), when: "after", feel: 2, effortFelt: 8, pain: true });
    await upload(2, "2026-11-04"); // stays in the inbox
    const res = await review();
    expect(res.status).toBe(200);
    const body = await json(res);
    expect(body).toMatchObject({
      planId: P,
      weekIndex: 0,
      startDate: "2026-11-02",
      endDate: "2026-11-08",
      due: true,
      summary: {
        sessions: { planned: 2, done: 1, skipped: 0, missed: 1 },
        distance: { plannedM: 10000, actualM: 5200 },
        time: { actualSec: 1800 },
        keySessions: [{ sessionId: S_KEY, title: "Tempo", outcome: "hit" }],
        checkIns: { count: 2, averageFeel: 3, averageEffortFelt: 7, painFlags: 1 },
      },
      looseEnds: { inboxActivities: 1 },
    });
    expect(Array.isArray(body.proposals)).toBe(true);
  });

  it("carries the pending proposals of the plan, without the engine's key", async () => {
    await call("POST", `/v1/sessions/${S_EASY}/checkins`, { id: id(302), when: "after", feel: 2, effortFelt: 8, pain: true });
    const body = await json(await review());
    // The pain flag's lighter next week, and the missed key session's drop (S_KEY has no done run by today).
    expect(body.proposals).toHaveLength(2);
    expect(body.proposals[0]).toMatchObject({ planId: P, kind: "adjustment", urgent: true, status: "pending" });
    expect(body.proposals[0]).not.toHaveProperty("key");
  });

  it("does not write: no proposals are made by reading the review", async () => {
    await review();
    const list = await json(await call("GET", `/v1/plans/${P}/proposals?status=pending`));
    expect(list.proposals).toEqual([]);
  });

  it("leaves the proposals out when reviews are Off, and for a blank plan that is not adaptive", async () => {
    await call("POST", `/v1/sessions/${S_EASY}/checkins`, { id: id(302), when: "after", feel: 2, effortFelt: 8, pain: true });
    expect((await json(await review())).proposals).toHaveLength(2);
    await setReview("off");
    const off = await json(await review());
    expect(off.proposals).toEqual([]);
    expect(off.due).toBe(false);
    expect(off.summary.sessions.planned).toBe(2);
  });

  it("gives a blank non-adaptive plan the summary with no proposals", async () => {
    await call("DELETE", `/v1/plans/${P}`, undefined, token, { "if-match": '"1"' });
    const blank = id(102);
    await call("POST", "/v1/plans", {
      id: blank, goal: { type: "5k", date: "2027-01-10" }, startDate: "2026-11-02", weekCount: 4, source: "blank", adaptive: false, weeks: [],
      sessions: [run(id(211), "2026-11-03")],
    });
    await call("POST", `/v1/sessions/${id(211)}/checkins`, { id: id(311), when: "after", feel: 2, effortFelt: 8, pain: true });
    const body = await json(await review(0, TODAY, blank));
    expect(body.summary.sessions.planned).toBe(1);
    expect(body.proposals).toEqual([]);
  });

  it("is 404 for another user's plan, an unknown plan, a week outside the plan and a week that is not a number", async () => {
    const other = await signIn("other@example.com");
    expect((await review(0, TODAY, P, other)).status).toBe(404);
    expect((await review(0, TODAY, id(999))).status).toBe(404);
    expect((await review(0, TODAY, "not-a-uuid")).status).toBe(404);
    expect((await review(8)).status).toBe(404);
    expect((await review(52)).status).toBe(404);
    expect((await review("x")).status).toBe(404);
    expect((await review("-1")).status).toBe(404);
    expect((await review("1.5")).status).toBe(404);
    expect((await review(7)).status).toBe(200);
  });

  it("is 401 without a token, before today is looked at, and 400 for a missing or bad today", async () => {
    expect((await review(0, null, P, null)).status).toBe(401);
    expect((await review(0, TODAY, P, null)).status).toBe(401);
    expect((await review(0, null)).status).toBe(400);
    expect((await review(0, "2026-13-40")).status).toBe(400);
  });
});
