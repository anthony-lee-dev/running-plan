import { beforeEach, describe, expect, it } from "vitest";
import { createApp } from "../src/app";
import { FixedClock, MemoryEmailSender, memoryDeps } from "../src/adapters/memory";

const SECRET = "test-secret-test-secret-test-secret";
type Json = Record<string, any>; // eslint-disable-line @typescript-eslint/no-explicit-any
const id = (n: number) => `00000000-0000-4000-8000-${String(n).padStart(12, "0")}`;
const P = id(101);
const P2 = id(102);
const S1 = id(201);
const S2 = id(202);
const S3 = id(203);

let app: ReturnType<typeof createApp>;
let email: MemoryEmailSender;
let clock: FixedClock;
let token: string;

async function signIn(address: string, clientType = "ios"): Promise<string> {
  const headers = { "content-type": "application/json" };
  await app.request("/v1/auth/email/start", { method: "POST", body: JSON.stringify({ email: address }), headers });
  const res = await app.request("/v1/auth/email/verify", { method: "POST", body: JSON.stringify({ email: address, code: email.sent.at(-1)!.code, clientType }), headers });
  return ((await res.json()) as { accessToken: string }).accessToken;
}
const call = (method: string, path: string, body?: unknown, as = token) =>
  app.request(path, {
    method,
    headers: { authorization: `Bearer ${as}`, ...(body !== undefined ? { "content-type": "application/json" } : {}) },
    ...(body !== undefined ? { body: JSON.stringify(body) } : {}),
  });
const exportAccount = (as = token) => call("POST", "/v1/account/export", undefined, as);

const easy = (sid: string, date: string) => ({ id: sid, date, type: "easy", steps: [{ kind: "work", goal: { type: "distance", value: 5000 }, target: { type: "effort", effort: "easy" } }] });
const plan = (pid: string, sessions: unknown[]) => ({ id: pid, goal: { type: "5k" }, startDate: "2026-10-26", weekCount: 8, source: "blank", adaptive: false, weeks: [], sessions });
const run = (n: number, localDate: string) => ({ source: "apple_health", externalId: `HK-${n}`, workoutType: "running", startedAt: `${localDate}T07:00:00-04:00`, localDate, durationSec: 1800, distanceM: 5000 });

beforeEach(async () => {
  email = new MemoryEmailSender();
  clock = new FixedClock(new Date("2026-11-07T12:00:00.000Z"));
  app = createApp(memoryDeps({ email, clock, authConfig: { jwtSecret: SECRET } }));
  token = await signIn("runner@example.com");
});

describe("POST /v1/account/export", () => {
  it("needs a token", async () => {
    expect((await app.request("/v1/account/export", { method: "POST" })).status).toBe(401);
    expect((await exportAccount("not-a-token")).status).toBe(401);
  });

  it("is a 404, not a 401, for a GET: only the POST exists", async () => {
    expect((await call("GET", "/v1/account/export")).status).toBe(404);
  });

  it("exports an empty account: the default profile and empty lists", async () => {
    const res = await exportAccount();
    expect(res.status).toBe(200);
    expect(res.headers.get("cache-control")).toBe("no-store");
    expect(await res.json()).toEqual({
      exportedAt: "2026-11-07T12:00:00.000Z",
      email: "runner@example.com",
      profile: ((await (await call("GET", "/v1/profile")).json()) as Json),
      plans: [],
      activities: [],
      checkins: [],
      proposals: [],
    });
  });

  it("exports proposals in the spec's shape, without the engine key or revision, and not those of a deleted plan", async () => {
    // Pain on a session this week, with a run next week to lighten: each plan gets an urgent proposal.
    const adaptive = (pid: string, a: string, b: string) => ({ ...plan(pid, [easy(a, "2026-11-05"), easy(b, "2026-11-10")]), adaptive: true, source: "rules", engine: { presetId: "5k", version: "0.2.0" } });
    await call("POST", "/v1/plans", adaptive(P, S1, S2));
    await call("POST", "/v1/plans", adaptive(P2, S3, id(204)));
    await call("POST", `/v1/sessions/${S1}/checkins`, { id: id(301), when: "after", feel: 2, effortFelt: 8, pain: true });
    await call("POST", `/v1/sessions/${S3}/checkins`, { id: id(302), when: "after", feel: 2, effortFelt: 8, pain: true });
    expect(((await (await exportAccount()).json()) as Json).proposals).toHaveLength(2);
    const deleted = await app.request(`/v1/plans/${P2}`, { method: "DELETE", headers: { authorization: `Bearer ${token}`, "if-match": '"1"' } });
    expect(deleted.status).toBe(204);
    const body = (await (await exportAccount()).json()) as Json;
    expect(body.proposals).toHaveLength(1);
    expect(body.proposals[0]).toMatchObject({ planId: P, kind: "adjustment", urgent: true, status: "pending", deletedAt: null, resolvedAt: null });
    expect(body.proposals[0]).not.toHaveProperty("key");
    expect(body.proposals[0]).not.toHaveProperty("revision");
  });

  it("exports the saved profile", async () => {
    const before = await call("GET", "/v1/profile");
    await app.request("/v1/profile", {
      method: "PATCH",
      headers: { authorization: `Bearer ${token}`, "content-type": "application/json", "if-match": before.headers.get("etag")! },
      body: JSON.stringify({ targetDisplay: "heart_rate" }),
    });
    const body = (await (await exportAccount()).json()) as Json;
    expect(body.profile).toMatchObject({ targetDisplay: "heart_rate", revision: 2 });
  });

  it("exports plans with their sessions and warnings, activities with their match, and check-ins", async () => {
    await call("POST", "/v1/plans", plan(P, [easy(S1, "2026-10-28"), easy(S2, "2026-10-29")]));
    const up = (await (await call("POST", "/v1/activities:batch", { activities: [run(1, "2026-10-28"), run(2, "2026-10-29")] })).json()) as Json;
    const [A1, A2] = up.results.map((r: Json) => r.activityId);
    await call("PUT", `/v1/sessions/${S1}/match`, { activityId: A1, status: "confirmed" });
    await call("POST", `/v1/sessions/${S1}/checkins`, { id: id(301), when: "after", feel: 4 });

    const body = (await (await exportAccount()).json()) as Json;
    expect(body.plans).toHaveLength(1);
    expect(body.plans[0]).toMatchObject({ id: P, contentRevision: 2 });
    expect(body.plans[0].sessions.map((s: Json) => [s.id, s.status])).toEqual([[S1, "done"], [S2, "planned"]]);
    expect(Array.isArray(body.plans[0].warnings)).toBe(true);
    expect(body.activities.map((a: Json) => a.id)).toEqual([A2, A1]);
    expect(body.activities.find((a: Json) => a.id === A1)).toMatchObject({ disposition: "matched", match: { sessionId: S1, status: "confirmed" } });
    expect(body.activities.find((a: Json) => a.id === A2).match).toBeUndefined();
    // The same activity view as the list: no internal revision.
    expect(body.activities[0]).not.toHaveProperty("revision");
    expect(body.checkins).toMatchObject([{ id: id(301), sessionId: S1, when: "after", feel: 4 }]);
  });

  it("leaves out deleted plans, deleted sessions, and what hangs off them", async () => {
    await call("POST", "/v1/plans", plan(P, [easy(S1, "2026-10-28"), easy(S2, "2026-10-29")]));
    await call("POST", "/v1/plans", plan(P2, [easy(S3, "2026-10-30")]));
    await call("POST", `/v1/sessions/${S2}/checkins`, { id: id(301), when: "after", feel: 4 });
    await call("POST", `/v1/sessions/${S3}/checkins`, { id: id(302), when: "after", feel: 4 });
    const remove = (path: string, revision: number) => app.request(path, { method: "DELETE", headers: { authorization: `Bearer ${token}`, "if-match": `"${revision}"` } });
    expect((await remove(`/v1/sessions/${S2}`, 1)).status).toBe(200);
    expect((await remove(`/v1/plans/${P2}`, 1)).status).toBe(204);

    const body = (await (await exportAccount()).json()) as Json;
    expect(body.plans.map((p: Json) => p.id)).toEqual([P]);
    expect(body.plans[0].sessions.map((s: Json) => s.id)).toEqual([S1]);
    expect(body.checkins).toEqual([]);
  });

  it("never includes another account's data", async () => {
    await call("POST", "/v1/plans", plan(P, [easy(S1, "2026-10-28")]));
    await call("POST", "/v1/activities:batch", { activities: [run(1, "2026-10-28")] });
    const other = await signIn("other@example.com");
    const body = (await (await exportAccount(other)).json()) as Json;
    expect(body).toMatchObject({ email: "other@example.com", plans: [], activities: [], checkins: [], proposals: [] });
  });

  it("is rate limited per account, with Retry-After", async () => {
    for (let i = 0; i < 5; i++) expect((await exportAccount()).status).toBe(200);
    const limited = await exportAccount();
    expect(limited.status).toBe(429);
    expect(Number(limited.headers.get("retry-after"))).toBeGreaterThan(0);
    // Another account is not held back by it.
    expect((await exportAccount(await signIn("other@example.com"))).status).toBe(200);
  });
});
