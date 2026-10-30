import { beforeEach, describe, expect, it } from "vitest";
import { createApp } from "../src/app";
import { MemoryEmailSender, memoryDeps } from "../src/adapters/memory";

const SECRET = "test-secret-test-secret-test-secret";
const id = (n: number) => `00000000-0000-4000-8000-${String(n).padStart(12, "0")}`;

let app: ReturnType<typeof createApp>;
let email: MemoryEmailSender;

beforeEach(() => {
  email = new MemoryEmailSender();
  app = createApp(memoryDeps({ email, authConfig: { jwtSecret: SECRET } }));
});

async function signIn(address = "runner@example.com", clientType = "ios"): Promise<string> {
  const json = { "content-type": "application/json" };
  await app.request("/v1/auth/email/start", { method: "POST", body: JSON.stringify({ email: address }), headers: json });
  const res = await app.request("/v1/auth/email/verify", { method: "POST", body: JSON.stringify({ email: address, code: email.sent.at(-1)!.code, clientType }), headers: json });
  return ((await res.json()) as { accessToken: string }).accessToken;
}

const call = (token: string | undefined, method: string, path: string, body?: unknown, ifMatch?: string) =>
  app.request(path, {
    method,
    headers: { ...(token ? { authorization: `Bearer ${token}` } : {}), ...(body !== undefined ? { "content-type": "application/json" } : {}), ...(ifMatch ? { "if-match": ifMatch } : {}) },
    ...(body !== undefined ? { body: JSON.stringify(body) } : {}),
  });

const easy = (n: number, date: string, over: Record<string, unknown> = {}) => ({
  id: id(200 + n),
  date,
  type: "easy",
  steps: [{ kind: "work", goal: { type: "distance", value: 5000 }, target: { type: "effort", effort: "easy" } }],
  ...over,
});
const planBody = (n = 1, over: Record<string, unknown> = {}) => ({
  id: id(100 + n),
  goal: { type: "5k", date: "2027-01-10" },
  startDate: "2026-11-02",
  weekCount: 8,
  source: "rules",
  engine: { presetId: "5k", version: "1.0.0" },
  adaptive: true,
  weeks: [{ index: 0, phase: "base" }],
  sessions: [easy(1, "2026-11-03"), easy(2, "2026-11-05"), easy(3, "2026-11-08", { type: "long" })],
  ...over,
});

type Json = Record<string, any>; // eslint-disable-line @typescript-eslint/no-explicit-any
const json = async (res: Response) => (await res.json()) as Json;

describe("auth on plan routes", () => {
  it.each([
    ["GET", "/v1/plans"],
    ["POST", "/v1/plans"],
    ["GET", `/v1/plans/${id(101)}`],
    ["PATCH", `/v1/plans/${id(101)}`],
    ["DELETE", `/v1/plans/${id(101)}`],
    ["POST", `/v1/plans/${id(101)}/sessions`],
    ["PATCH", `/v1/sessions/${id(201)}`],
    ["DELETE", `/v1/sessions/${id(201)}`],
  ])("%s %s needs a token", async (method, path) => {
    expect((await call(undefined, method, path, method === "GET" || method === "DELETE" ? undefined : {})).status).toBe(401);
  });
});

describe("POST /v1/plans", () => {
  it("creates a plan with weeks and sessions, and returns the detail with an ETag", async () => {
    const token = await signIn();
    const res = await call(token, "POST", "/v1/plans", planBody());
    expect(res.status).toBe(201);
    expect(res.headers.get("etag")).toBe('"1"');
    const body = await json(res);
    expect(body).toMatchObject({ id: id(101), revision: 1, contentRevision: 1, deletedAt: null, goal: { type: "5k" }, weekCount: 8, source: "rules", adaptive: true, weeks: [{ index: 0, phase: "base" }] });
    expect(body.sessions).toHaveLength(3);
    expect(body.sessions[0]).toMatchObject({ planId: id(101), revision: 1, status: "planned", owner: "system", deletedAt: null });
    expect(Array.isArray(body.warnings)).toBe(true);
  });

  it("creates a blank plan", async () => {
    const token = await signIn();
    const res = await call(token, "POST", "/v1/plans", planBody(2, { source: "blank", engine: undefined, adaptive: false, weeks: [], sessions: [] }));
    expect(res.status).toBe(201);
    expect(await json(res)).toMatchObject({ source: "blank", adaptive: false, sessions: [] });
  });

  it("returns 200 with the stored plan when the same create is repeated", async () => {
    const token = await signIn();
    await call(token, "POST", "/v1/plans", planBody());
    const again = await call(token, "POST", "/v1/plans", { ...planBody(), sessions: planBody().sessions.map((s) => ({ ...s, status: "planned", owner: "system" })) });
    expect(again.status).toBe(200);
    expect((await json(again)).sessions).toHaveLength(3);
  });

  it("still returns 200 for a repeated create after the plan was edited", async () => {
    const token = await signIn();
    await call(token, "POST", "/v1/plans", planBody());
    await call(token, "PATCH", `/v1/plans/${id(101)}`, { adaptive: false }, '"1"');
    const again = await call(token, "POST", "/v1/plans", planBody());
    expect(again.status).toBe(200);
    expect((await json(again)).adaptive).toBe(false);
  });

  it("answers 409 for the same id with a different body, and for another user's id", async () => {
    const a = await signIn("a@example.com");
    const b = await signIn("b@example.com");
    await call(a, "POST", "/v1/plans", planBody());
    expect((await call(a, "POST", "/v1/plans", planBody(1, { weekCount: 9 }))).status).toBe(409);
    const theirs = await call(b, "POST", "/v1/plans", planBody());
    expect(theirs.status).toBe(409);
    expect(theirs.headers.get("content-type")).toContain("application/problem+json");
    expect((await call(b, "GET", `/v1/plans/${id(101)}`)).status).toBe(404);
  });

  it("answers 400 with field errors for invalid data and stores nothing", async () => {
    const token = await signIn();
    const res = await call(token, "POST", "/v1/plans", planBody(1, { weekCount: 99, sessions: [easy(1, "2026-11-03", { type: "sprint" })] }));
    expect(res.status).toBe(400);
    const body = await json(res);
    expect(body.type).toBe("validation_failed");
    expect(body.errors.map((e: { path: string }) => e.path).sort()).toEqual(["/sessions/0/type", "/weekCount"]);
    expect((await call(token, "GET", "/v1/plans")).status).toBe(200);
    expect((await json(await call(token, "GET", "/v1/plans"))).plans).toEqual([]);
  });

  it("answers 409, not 500, when a session id in the plan is already in use", async () => {
    const a = await signIn("a@example.com");
    const b = await signIn("b@example.com");
    await call(a, "POST", "/v1/plans", planBody(1));
    const res = await call(b, "POST", "/v1/plans", planBody(2));
    expect(res.status).toBe(409);
    expect((await call(b, "GET", `/v1/plans/${id(102)}`)).status).toBe(404);
  });

  it("measures the body in bytes, and refuses by Content-Length before reading", async () => {
    const token = await signIn();
    const multibyte = planBody(1, { weeks: [], sessions: [], goal: { type: "custom", label: "é".repeat(600_000) } });
    expect((await call(token, "POST", "/v1/plans", multibyte)).status).toBe(413);
    const lying = await app.request("/v1/plans", { method: "POST", body: "{}", headers: { authorization: `Bearer ${token}`, "content-length": "5000000" } });
    expect(lying.status).toBe(413);
  });

  it("answers 400 for a body that is not JSON and 413 for one that is too large", async () => {
    const token = await signIn();
    expect((await app.request("/v1/plans", { method: "POST", body: "nope", headers: { authorization: `Bearer ${token}` } })).status).toBe(400);
    const big = planBody(1, { weeks: [], sessions: [], goal: { type: "custom", label: "x".repeat(2_000_000) } });
    expect((await call(token, "POST", "/v1/plans", big)).status).toBe(413);
  });

  it("returns validator warnings with the plan and never blocks", async () => {
    const token = await signIn();
    const hard = (n: number, date: string, type: string) => easy(n, date, { type });
    const res = await call(token, "POST", "/v1/plans", planBody(3, { sessions: [hard(1, "2026-11-03", "intervals"), hard(2, "2026-11-04", "tempo")] }));
    expect(res.status).toBe(201);
    const body = await json(res);
    expect(body.warnings).toEqual([expect.objectContaining({ code: "hard_days_back_to_back", severity: "caution", weekIndex: 0, sessionIds: [id(201), id(202)] })]);
  });
});

describe("GET /v1/plans and GET /v1/plans/{id}", () => {
  it("lists summaries newest first and pages with a cursor", async () => {
    const token = await signIn();
    for (const [n, start] of [[1, "2026-03-02"], [2, "2026-05-04"], [3, "2026-07-06"]] as const) {
      await call(token, "POST", "/v1/plans", planBody(n, { startDate: start, sessions: [] }));
    }
    const first = await json(await call(token, "GET", "/v1/plans?limit=2"));
    expect(first.plans.map((p: Json) => p.id)).toEqual([id(103), id(102)]);
    expect(first.plans[0]).toMatchObject({ revision: 1, goal: { type: "5k" }, startDate: "2026-07-06", weekCount: 8, source: "rules", adaptive: true, deletedAt: null });
    expect(first.plans[0].sessions).toBeUndefined();
    expect(typeof first.nextCursor).toBe("string");
    const second = await json(await call(token, "GET", `/v1/plans?limit=2&cursor=${encodeURIComponent(first.nextCursor)}`));
    expect(second.plans.map((p: Json) => p.id)).toEqual([id(101)]);
    expect(second.nextCursor).toBeUndefined();
  });

  it.each(["limit=0", "limit=201", "limit=abc", "cursor=not-a-cursor"])("rejects %s with 400", async (query) => {
    expect((await call(await signIn(), "GET", `/v1/plans?${query}`)).status).toBe(400);
  });

  it("gets a plan with ETag, sessions and warnings, and 404s for unknown or other users' plans", async () => {
    const a = await signIn("a@example.com");
    const b = await signIn("b@example.com");
    await call(a, "POST", "/v1/plans", planBody());
    const res = await call(a, "GET", `/v1/plans/${id(101)}`);
    expect(res.status).toBe(200);
    expect(res.headers.get("etag")).toBe('"1"');
    expect((await json(res)).sessions).toHaveLength(3);
    expect((await call(b, "GET", `/v1/plans/${id(101)}`)).status).toBe(404);
    expect((await call(a, "GET", `/v1/plans/${id(999)}`)).status).toBe(404);
    expect((await call(a, "GET", "/v1/plans/not-a-uuid")).status).toBe(404);
    expect((await call(a, "GET", `/v1/plans/${id(101)}`)).headers.get("content-type")).toContain("application/json");
  });
});

describe("PATCH /v1/plans/{id}", () => {
  const patch = (token: string, body: unknown, ifMatch?: string, planId = id(101)) => call(token, "PATCH", `/v1/plans/${planId}`, body, ifMatch);

  it("updates goal, adaptive and week notes, and moves both revisions", async () => {
    const token = await signIn();
    await call(token, "POST", "/v1/plans", planBody());
    const res = await patch(token, { goal: { type: "10k", label: "Fall" }, adaptive: false, weeks: [{ index: 1, notes: "down week" }] }, '"1"');
    expect(res.status).toBe(200);
    expect(res.headers.get("etag")).toBe('"2"');
    const body = await json(res);
    expect(body).toMatchObject({ revision: 2, contentRevision: 2, adaptive: false, goal: { type: "10k", label: "Fall" } });
    expect(body.weeks).toEqual([{ index: 0, phase: "base" }, { index: 1, notes: "down week" }]);
    expect(body.sessions).toHaveLength(3);
  });

  it("needs If-Match, rejects a stale one with 409 and the current revision, and a bad body with 400", async () => {
    const token = await signIn();
    await call(token, "POST", "/v1/plans", planBody());
    expect((await patch(token, { adaptive: false })).status).toBe(400);
    await patch(token, { adaptive: false }, '"1"');
    const stale = await patch(token, { adaptive: true }, '"1"');
    expect(stale.status).toBe(409);
    expect(await json(stale)).toMatchObject({ type: "revision_conflict", currentRevision: 2 });
    const bad = await patch(token, { startDate: "2026-12-01" }, '"2"');
    expect(bad.status).toBe(400);
    expect((await json(bad)).errors[0].path).toBe("/startDate");
    expect((await patch(token, { weeks: [{ index: 8 }] }, '"2"')).status).toBe(400);
  });

  it("answers 404 for a missing or another user's plan", async () => {
    const a = await signIn("a@example.com");
    const b = await signIn("b@example.com");
    await call(a, "POST", "/v1/plans", planBody());
    expect((await patch(b, { adaptive: false }, '"1"')).status).toBe(404);
    expect((await patch(a, { adaptive: false }, '"1"', id(999))).status).toBe(404);
  });
});

describe("DELETE /v1/plans/{id}", () => {
  it("tombstones the plan: 204, then 404 everywhere", async () => {
    const token = await signIn();
    await call(token, "POST", "/v1/plans", planBody());
    expect((await call(token, "DELETE", `/v1/plans/${id(101)}`, undefined, '"1"')).status).toBe(204);
    expect((await call(token, "GET", `/v1/plans/${id(101)}`)).status).toBe(404);
    expect((await json(await call(token, "GET", "/v1/plans"))).plans).toEqual([]);
    expect((await call(token, "PATCH", `/v1/sessions/${id(201)}`, { status: "done" }, '"1"')).status).toBe(404);
    expect((await call(token, "DELETE", `/v1/plans/${id(101)}`, undefined, '"2"')).status).toBe(404);
  });

  it("needs If-Match and the current revision", async () => {
    const token = await signIn();
    await call(token, "POST", "/v1/plans", planBody());
    expect((await call(token, "DELETE", `/v1/plans/${id(101)}`)).status).toBe(400);
    const stale = await call(token, "DELETE", `/v1/plans/${id(101)}`, undefined, '"5"');
    expect(stale.status).toBe(409);
    expect((await json(stale)).currentRevision).toBe(1);
  });
});

describe("POST /v1/plans/{planId}/sessions", () => {
  const add = (token: string, body: unknown, planId = id(101)) => call(token, "POST", `/v1/plans/${planId}/sessions`, body);

  it("adds a user-owned session and returns it with the plan's new contentRevision and warnings", async () => {
    const token = await signIn();
    await call(token, "POST", "/v1/plans", planBody());
    const res = await add(token, easy(9, "2026-11-10", { type: "custom", steps: [], custom: { activityLabel: "cycling", goal: { type: "time", value: 3600 }, effort: "moderate" }, title: "Ride", owner: "system" }));
    expect(res.status).toBe(201);
    const body = await json(res);
    expect(body.session).toMatchObject({ id: id(209), planId: id(101), owner: "user", revision: 1, type: "custom", title: "Ride", status: "planned" });
    expect(body.planContentRevision).toBe(2);
    expect(Array.isArray(body.warnings)).toBe(true);
    expect((await json(await call(token, "GET", `/v1/plans/${id(101)}`))).sessions).toHaveLength(4);
  });

  it("returns 200 for a repeat with the same body, 409 for the same id and another body", async () => {
    const token = await signIn();
    await call(token, "POST", "/v1/plans", planBody());
    const body = easy(9, "2026-11-10");
    expect((await add(token, body)).status).toBe(201);
    const again = await add(token, body);
    expect(again.status).toBe(200);
    expect((await json(again)).planContentRevision).toBe(2);
    expect((await add(token, { ...body, date: "2026-11-11" })).status).toBe(409);
  });

  it("answers 409 when a deleted session's create is replayed: a tombstone does not come back", async () => {
    const token = await signIn();
    await call(token, "POST", "/v1/plans", planBody());
    const body = easy(9, "2026-11-10");
    await add(token, body);
    await call(token, "DELETE", `/v1/sessions/${id(209)}`, undefined, '"1"');
    expect((await add(token, body)).status).toBe(409);
  });

  it("answers 404 for a missing, other user's or deleted plan and 400 for invalid data", async () => {
    const a = await signIn("a@example.com");
    const b = await signIn("b@example.com");
    await call(a, "POST", "/v1/plans", planBody());
    expect((await add(b, easy(9, "2026-11-10"))).status).toBe(404);
    expect((await add(a, easy(9, "2026-11-10"), id(999))).status).toBe(404);
    const bad = await add(a, easy(9, "2027-06-01"));
    expect(bad.status).toBe(400);
    expect((await json(bad)).errors[0].path).toBe("/date");
    expect((await add(a, { ...easy(9, "2026-11-10"), id: "nope" })).status).toBe(400);
  });
});

describe("PATCH /v1/sessions/{id}", () => {
  const patch = (token: string, sessionId: string, body: unknown, ifMatch?: string) => call(token, "PATCH", `/v1/sessions/${sessionId}`, body, ifMatch);
  let token: string;
  beforeEach(async () => {
    token = await signIn();
    await call(token, "POST", "/v1/plans", planBody());
  });

  it("edits a session, takes ownership, moves its revision and the plan's contentRevision", async () => {
    const res = await patch(token, id(201), { date: "2026-11-04", title: "Moved", notes: "felt good" }, '"1"');
    expect(res.status).toBe(200);
    const body = await json(res);
    expect(body.session).toMatchObject({ id: id(201), revision: 2, date: "2026-11-04", title: "Moved", notes: "felt good", owner: "user" });
    expect(body.planContentRevision).toBe(2);
  });

  it("keeps ownership when only the status changes", async () => {
    const body = await json(await patch(token, id(201), { status: "done" }, '"1"'));
    expect(body.session).toMatchObject({ status: "done", owner: "system", revision: 2 });
  });

  it("clears optional fields and drops custom details when the type changes away from custom", async () => {
    await call(token, "POST", `/v1/plans/${id(101)}/sessions`, easy(9, "2026-11-10", { type: "custom", steps: [], custom: { effort: "hard" }, title: "Ride", notes: "n" }));
    const cleared = await json(await patch(token, id(209), { clear: ["title", "notes"] }, '"1"'));
    expect(cleared.session.title).toBeUndefined();
    expect(cleared.session.notes).toBeUndefined();
    expect(cleared.session.custom).toEqual({ effort: "hard" });
    const changed = await json(await patch(token, id(209), { type: "easy" }, '"2"'));
    expect(changed.session).toMatchObject({ type: "easy", steps: [] });
    expect(changed.session.custom).toBeUndefined();
  });

  it("drops steps that no longer fit when the session class changes without new steps", async () => {
    const res = await json(await patch(token, id(201), { type: "strength" }, '"1"'));
    expect(res.session).toMatchObject({ type: "strength", steps: [] });
  });

  it("needs If-Match, answers 409 with the current revision, 404 and 400", async () => {
    expect((await patch(token, id(201), { status: "done" })).status).toBe(400);
    await patch(token, id(201), { status: "done" }, '"1"');
    const stale = await patch(token, id(201), { status: "skipped" }, '"1"');
    expect(stale.status).toBe(409);
    expect(await json(stale)).toMatchObject({ type: "revision_conflict", currentRevision: 2 });
    expect((await patch(token, id(999), { status: "done" }, '"1"')).status).toBe(404);
    expect((await patch(token, "not-a-uuid", { status: "done" }, '"1"')).status).toBe(404);
    const bad = await patch(token, id(201), { date: "2027-06-01" }, '"2"');
    expect(bad.status).toBe(400);
    expect((await patch(token, id(201), {}, '"2"')).status).toBe(400);
  });

  it("does not touch another user's session", async () => {
    const other = await signIn("other@example.com");
    expect((await patch(other, id(201), { status: "done" }, '"1"')).status).toBe(404);
    expect((await json(await call(token, "GET", `/v1/plans/${id(101)}`))).sessions.find((s: Json) => s.id === id(201)).status).toBe("planned");
  });

  it("recomputes the plan's warnings after the edit", async () => {
    await patch(token, id(202), { type: "intervals", date: "2026-11-04" }, '"1"');
    const res = await json(await patch(token, id(201), { type: "tempo", date: "2026-11-03" }, '"1"'));
    expect(res.warnings.map((w: Json) => w.code)).toContain("hard_days_back_to_back");
  });
});

describe("DELETE /v1/sessions/{id}", () => {
  it("tombstones the session and returns it with the new contentRevision", async () => {
    const token = await signIn();
    await call(token, "POST", "/v1/plans", planBody());
    const res = await call(token, "DELETE", `/v1/sessions/${id(201)}`, undefined, '"1"');
    expect(res.status).toBe(200);
    const body = await json(res);
    expect(body.session).toMatchObject({ id: id(201), revision: 2 });
    expect(typeof body.session.deletedAt).toBe("string");
    expect(body.planContentRevision).toBe(2);
    expect((await json(await call(token, "GET", `/v1/plans/${id(101)}`))).sessions).toHaveLength(2);
    expect((await call(token, "DELETE", `/v1/sessions/${id(201)}`, undefined, '"2"')).status).toBe(404);
  });

  it("needs If-Match and the current revision", async () => {
    const token = await signIn();
    await call(token, "POST", "/v1/plans", planBody());
    expect((await call(token, "DELETE", `/v1/sessions/${id(201)}`)).status).toBe(400);
    const stale = await call(token, "DELETE", `/v1/sessions/${id(201)}`, undefined, '"4"');
    expect(stale.status).toBe(409);
    expect((await json(stale)).currentRevision).toBe(1);
  });
});

describe("account delete", () => {
  it("removes the account's plans", async () => {
    const token = await signIn();
    await call(token, "POST", "/v1/plans", planBody());
    await call(token, "DELETE", "/v1/account");
    const again = await signIn();
    expect((await json(await call(again, "GET", "/v1/plans"))).plans).toEqual([]);
    expect((await call(again, "GET", `/v1/plans/${id(101)}`)).status).toBe(404);
  });
});
