import { beforeEach, describe, expect, it } from "vitest";
import { createApp } from "../src/app";
import { MemoryEmailSender, memoryDeps } from "../src/adapters/memory";

const SECRET = "test-secret-test-secret-test-secret";
type Json = Record<string, any>; // eslint-disable-line @typescript-eslint/no-explicit-any
const id = (n: number) => `00000000-0000-4000-8000-${String(n).padStart(12, "0")}`;
const P = id(101);
const S1 = id(201);
const S2 = id(202);

let app: ReturnType<typeof createApp>;
let email: MemoryEmailSender;
let token: string;

async function signIn(address = "runner@example.com", clientType = "ios"): Promise<string> {
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

const easy = (sid: string, date: string) => ({ id: sid, date, type: "easy", steps: [{ kind: "work", goal: { type: "distance", value: 5000 }, target: { type: "effort", effort: "easy" } }] });
const run = (n: number, localDate: string) => ({ source: "apple_health", externalId: `HK-${n}`, workoutType: "running", startedAt: `${localDate}T07:00:00-04:00`, localDate, durationSec: 1800, distanceM: 5000 });

let A1: string;
let A2: string;
beforeEach(async () => {
  email = new MemoryEmailSender();
  app = createApp(memoryDeps({ email, authConfig: { jwtSecret: SECRET } }));
  token = await signIn();
  await call("POST", "/v1/plans", { id: P, goal: { type: "5k" }, startDate: "2026-10-26", weekCount: 8, source: "blank", adaptive: false, weeks: [], sessions: [easy(S1, "2026-10-28"), easy(S2, "2026-10-29")] });
  const up = (await (await call("POST", "/v1/activities:batch", { activities: [run(1, "2026-10-28"), run(2, "2026-10-29")] })).json()) as Json;
  [A1, A2] = up.results.map((r: Json) => r.activityId);
});

const confirm = (sessionId: string, activityId: string) => call("PUT", `/v1/sessions/${sessionId}/match`, { activityId, status: "confirmed" });
const listed = async () => ((await (await call("GET", "/v1/activities")).json()) as Json).activities as Json[];

describe("PUT /v1/sessions/{id}/match", () => {
  it("confirms a match: the session is done with a new revision, and the activity leaves the inbox", async () => {
    const res = await confirm(S1, A1);
    expect(res.status).toBe(200);
    const body = (await res.json()) as Json;
    expect(body.match).toMatchObject({ sessionId: S1, activityId: A1, status: "confirmed" });
    expect(body.session).toMatchObject({ id: S1, status: "done", revision: 2 });
    expect(body.planContentRevision).toBe(2);
    expect(Array.isArray(body.warnings)).toBe(true);
    const a1 = (await listed()).find((a) => a.id === A1)!;
    expect(a1.disposition).toBe("matched");
    expect(a1.match).toMatchObject({ sessionId: S1, status: "confirmed" });
    expect((await (await call("GET", "/v1/activities?inbox=true")).json() as Json).activities.map((a: Json) => a.id)).toEqual([A2]);
  });

  it("a suggestion keeps the session planned and the activity in the inbox", async () => {
    const body = (await (await call("PUT", `/v1/sessions/${S1}/match`, { activityId: A1, status: "suggested" })).json()) as Json;
    expect(body.session).toMatchObject({ status: "planned", revision: 1 });
    expect((await listed()).find((a) => a.id === A1)).toMatchObject({ disposition: "inbox", match: { status: "suggested" } });
  });

  it("moves an activity matched elsewhere and resets the session it left", async () => {
    await confirm(S1, A1);
    await confirm(S2, A1);
    const s1 = (await (await call("GET", `/v1/plans/${P}`)).json() as Json).sessions.find((s: Json) => s.id === S1);
    expect(s1.status).toBe("planned");
    expect((await listed()).find((a) => a.id === A1)!.match.sessionId).toBe(S2);
  });

  it.each([
    ["an unknown session", () => [id(299), A1]],
    ["an unknown activity", () => [S1, id(999)]],
  ])("answers 404 for %s", async (_name, ids) => {
    const [sid, aid] = ids() as [string, string];
    expect((await confirm(sid, aid)).status).toBe(404);
  });

  it("answers 404 for another user's session or activity", async () => {
    const other = await signIn("other@example.com");
    expect((await call("PUT", `/v1/sessions/${S1}/match`, { activityId: A1, status: "confirmed" }, other)).status).toBe(404);
  });

  it.each([{}, { activityId: "x", status: "confirmed" }, { activityId: id(901), status: "done" }, { activityId: id(901), status: "confirmed", extra: 1 }])(
    "answers 400 to %j",
    async (body) => {
      expect((await call("PUT", `/v1/sessions/${S1}/match`, body)).status).toBe(400);
    },
  );
});

describe("DELETE /v1/sessions/{id}/match", () => {
  it("unlinks: the activity goes back to the inbox and the session to planned", async () => {
    await confirm(S1, A1);
    const res = await call("DELETE", `/v1/sessions/${S1}/match`);
    expect(res.status).toBe(200);
    const body = (await res.json()) as Json;
    expect(body.session).toMatchObject({ status: "planned", revision: 3 });
    expect(body.planContentRevision).toBe(3);
    expect((await listed()).find((a) => a.id === A1)).toMatchObject({ disposition: "inbox" });
    expect((await listed()).find((a) => a.id === A1)!.match).toBeUndefined();
  });

  it("answers 404 when the session has no match", async () => {
    expect((await call("DELETE", `/v1/sessions/${S1}/match`)).status).toBe(404);
  });
});

describe("PATCH /v1/activities/{id}", () => {
  it("marks an activity extra, unlinking it from its session first", async () => {
    await confirm(S1, A1);
    const res = await call("PATCH", `/v1/activities/${A1}`, { disposition: "extra" });
    expect(res.status).toBe(200);
    const body = (await res.json()) as Json;
    expect(body).toMatchObject({ id: A1, disposition: "extra" });
    expect(body.match).toBeUndefined();
    expect(body.revision).toBeUndefined();
    const s1 = (await (await call("GET", `/v1/plans/${P}`)).json() as Json).sessions.find((s: Json) => s.id === S1);
    expect(s1.status).toBe("planned");
  });

  it("answers 404 for an unknown or another user's activity", async () => {
    expect((await call("PATCH", `/v1/activities/${id(999)}`, { disposition: "ignored" })).status).toBe(404);
    const other = await signIn("other@example.com");
    expect((await call("PATCH", `/v1/activities/${A1}`, { disposition: "ignored" }, other)).status).toBe(404);
  });

  it.each([{}, { disposition: "matched" }, { disposition: "extra", note: "x" }])("answers 400 to %j", async (body) => {
    expect((await call("PATCH", `/v1/activities/${A1}`, body)).status).toBe(400);
  });
});
