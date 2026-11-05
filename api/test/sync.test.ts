import { beforeEach, describe, expect, it } from "vitest";
import { createApp } from "../src/app";
import { MemoryEmailSender, memoryDeps } from "../src/adapters/memory";
import type { Deps } from "../src/ports";

const SECRET = "test-secret-test-secret-test-secret";
const id = (n: number) => `00000000-0000-4000-8000-${String(n).padStart(12, "0")}`;
type Json = Record<string, any>; // eslint-disable-line @typescript-eslint/no-explicit-any

let deps: Deps;
let app: ReturnType<typeof createApp>;
let email: MemoryEmailSender;

beforeEach(() => {
  email = new MemoryEmailSender();
  // Each reading is a second later, so no two writes share a timestamp (the pull orders by update time).
  let ms = Date.parse("2026-11-04T09:00:00Z");
  deps = memoryDeps({ email, authConfig: { jwtSecret: SECRET }, clock: { now: () => new Date((ms += 1000)) } });
  app = createApp(deps);
});

async function signIn(address = "runner@example.com"): Promise<string> {
  const headers = { "content-type": "application/json" };
  await app.request("/v1/auth/email/start", { method: "POST", body: JSON.stringify({ email: address }), headers });
  const res = await app.request("/v1/auth/email/verify", { method: "POST", body: JSON.stringify({ email: address, code: email.sent.at(-1)!.code, clientType: "ios" }), headers });
  return ((await res.json()) as { accessToken: string }).accessToken;
}

const send = (token: string | undefined, body: unknown) =>
  app.request("/v1/sync", { method: "POST", headers: { "content-type": "application/json", ...(token ? { authorization: `Bearer ${token}` } : {}) }, body: JSON.stringify(body) });
async function sync(token: string, request: unknown): Promise<Json> {
  const res = await send(token, request);
  const body = (await res.json()) as Json;
  expect(res.status, JSON.stringify(body)).toBe(200);
  return body;
}

const easy = (n: number, date: string, over: Json = {}) => ({
  id: id(200 + n),
  date,
  type: "easy",
  steps: [{ kind: "work", goal: { type: "distance", value: 5000 }, target: { type: "effort", effort: "easy" } }],
  ...over,
});
/** A session's content as session.create carries it: the operation holds the id. */
const content = (n: number, date: string) => {
  const { id: _id, ...rest } = easy(n, date);
  return rest;
};
const planData = (n = 1) => ({
  id: id(100 + n),
  goal: { type: "5k", date: "2027-01-10" },
  startDate: "2026-11-02",
  weekCount: 8,
  source: "rules",
  engine: { presetId: "5k", version: "1.0.0" },
  adaptive: true,
  weeks: [{ index: 0, phase: "base" }],
  sessions: [easy(n * 10 + 1, "2026-11-03"), easy(n * 10 + 2, "2026-11-05")],
});
let key = 1000;
const k = () => id(key++);
const planCreate = (n = 1) => ({ idempotencyKey: k(), kind: "plan.create", id: id(100 + n), data: planData(n) });
const sessionUpdate = (sessionId: string, baseRevision: number, data: Json, idempotencyKey = k()) => ({ idempotencyKey, kind: "session.update", id: sessionId, baseRevision, data });

describe("POST /v1/sync", () => {
  it("needs a token", async () => {
    expect((await send(undefined, { operations: [] })).status).toBe(401);
  });

  it("pulls everything on the first sync, then only what changed", async () => {
    const token = await signIn();
    const first = await sync(token, { operations: [planCreate()] });
    expect(first.results).toEqual([{ idempotencyKey: expect.any(String), status: "applied", revision: 1 }]);
    expect(first.changes.plans).toMatchObject([{ id: id(101), revision: 1, contentRevision: 1, weeks: [{ index: 0, phase: "base" }] }]);
    expect(first.changes.sessions.map((s: Json) => s.id)).toEqual([id(211), id(212)]);
    expect(first.changes.proposals).toEqual([]);
    expect(first.hasMore).toBe(false);
    const idle = await sync(token, { cursor: first.cursor, operations: [] });
    expect(idle.changes).toEqual({ plans: [], sessions: [], checkins: [], proposals: [] });
    const edit = await sync(token, { cursor: idle.cursor, operations: [sessionUpdate(id(211), 1, { status: "done" })] });
    expect(edit.results[0]).toMatchObject({ status: "applied", revision: 2 });
    expect(edit.changes.sessions).toMatchObject([{ id: id(211), status: "done", revision: 2 }]);
    // The plan comes back too, because its contentRevision moved.
    expect(edit.changes.plans).toMatchObject([{ id: id(101), contentRevision: 2 }]);
  });

  it("a retried batch applies once: the second answer is duplicate with the original revision", async () => {
    const token = await signIn();
    await sync(token, { operations: [planCreate()] });
    const op = sessionUpdate(id(211), 1, { notes: "felt good" }, id(777));
    const first = await sync(token, { operations: [op] });
    expect(first.results[0]).toEqual({ idempotencyKey: id(777), status: "applied", revision: 2 });
    const again = await sync(token, { operations: [op] });
    expect(again.results[0]).toEqual({ idempotencyKey: id(777), status: "duplicate", revision: 2 });
    const stored = await (await app.request(`/v1/plans/${id(101)}`, { headers: { authorization: `Bearer ${token}` } })).json() as Json;
    expect(stored.sessions.find((s: Json) => s.id === id(211))).toMatchObject({ revision: 2, notes: "felt good" });
  });

  it("the same key on a different edit is rejected, not treated as a retry", async () => {
    const token = await signIn();
    await sync(token, { operations: [planCreate()] });
    await sync(token, { operations: [sessionUpdate(id(211), 1, { notes: "a" }, id(777))] });
    const res = await sync(token, { operations: [sessionUpdate(id(211), 2, { notes: "b" }, id(777))] });
    expect(res.results[0]).toMatchObject({ status: "rejected", problem: { type: "idempotency_key_reused", status: 409 } });
  });

  it("a stale base revision is a conflict that carries the server version and changes nothing", async () => {
    const token = await signIn();
    await sync(token, { operations: [planCreate()] });
    await sync(token, { operations: [sessionUpdate(id(211), 1, { notes: "from the web" })] });
    const res = await sync(token, { operations: [sessionUpdate(id(211), 1, { notes: "from the phone" })] });
    expect(res.results[0]).toMatchObject({ status: "conflict", problem: { type: "revision_conflict", status: 409, currentRevision: 2 }, server: { id: id(211), revision: 2, notes: "from the web" } });
    // Keep mine: resend with the server's revision. The conflict was not remembered, so the key can be reused.
    const retry = res.results[0].idempotencyKey as string;
    const kept = await sync(token, { operations: [sessionUpdate(id(211), 2, { notes: "from the phone" }, retry)] });
    expect(kept.results[0]).toMatchObject({ status: "applied", revision: 3 });
  });

  it("a plan conflict returns the Plan", async () => {
    const token = await signIn();
    await sync(token, { operations: [planCreate()] });
    const op = (base: number) => ({ idempotencyKey: k(), kind: "plan.update", id: id(101), baseRevision: base, data: { adaptive: false } });
    expect((await sync(token, { operations: [op(1)] })).results[0]).toMatchObject({ status: "applied", revision: 2 });
    const res = await sync(token, { operations: [op(1)] });
    expect(res.results[0]).toMatchObject({ status: "conflict", server: { id: id(101), revision: 2, adaptive: false } });
    expect(res.results[0].server.sessions).toBeUndefined();
  });

  it("deletes are tombstones that come back in changes, and a later edit of one is rejected", async () => {
    const token = await signIn();
    const first = await sync(token, { operations: [planCreate()] });
    const del = await sync(token, { cursor: first.cursor, operations: [{ idempotencyKey: k(), kind: "session.delete", id: id(211), baseRevision: 1 }] });
    expect(del.results[0]).toMatchObject({ status: "applied", revision: 2 });
    expect(del.changes.sessions).toMatchObject([{ id: id(211), revision: 2, deletedAt: expect.any(String) }]);
    const edit = await sync(token, { operations: [sessionUpdate(id(211), 2, { notes: "x" })] });
    expect(edit.results[0]).toMatchObject({ status: "rejected", problem: { status: 404 } });
    const gone = await sync(token, { cursor: del.cursor, operations: [{ idempotencyKey: k(), kind: "plan.delete", id: id(101), baseRevision: 1 }] });
    expect(gone.changes.plans).toMatchObject([{ id: id(101), deletedAt: expect.any(String) }]);
  });

  it("applies in order: a session and a check-in can ride behind the plan they need", async () => {
    const token = await signIn();
    const res = await sync(token, {
      operations: [
        planCreate(),
        { idempotencyKey: k(), kind: "session.create", id: id(250), planId: id(101), data: content(50, "2026-11-10") },
        { idempotencyKey: k(), kind: "checkin.create", id: id(300), sessionId: id(250), data: { when: "after", feel: 4, effortFelt: 5 } },
      ],
    });
    expect(res.results.map((r: Json) => r.status)).toEqual(["applied", "applied", "applied"]);
    expect(res.changes.checkins).toMatchObject([{ id: id(300), sessionId: id(250), revision: 1, deletedAt: null }]);
    expect(res.changes.sessions.find((s: Json) => s.id === id(250))).toMatchObject({ owner: "user" });
  });

  it("rejects, per operation, what only the stored data can judge", async () => {
    const token = await signIn();
    await sync(token, { operations: [planCreate()] });
    const res = await sync(token, {
      operations: [
        { idempotencyKey: k(), kind: "session.create", id: id(251), planId: id(101), data: content(51, "2030-01-01") }, // outside the plan
        { idempotencyKey: k(), kind: "session.create", id: id(252), planId: id(199), data: content(52, "2026-11-10") }, // no such plan
        { idempotencyKey: k(), kind: "plan.create", id: id(101), data: planData(1) }, // same body again: idempotent, not an error
        { idempotencyKey: k(), kind: "plan.create", id: id(101), data: { ...planData(1), adaptive: false } }, // same id, other body
        { idempotencyKey: k(), kind: "checkin.create", id: id(301), sessionId: id(299), data: { when: "after", feel: 3 } },
      ],
    });
    expect(res.results.map((r: Json) => [r.status, r.problem?.status ?? r.revision])).toEqual([["rejected", 400], ["rejected", 404], ["applied", 1], ["rejected", 409], ["rejected", 404]]);
    expect(res.results[0].problem.errors[0].path).toBe("/date");
  });

  it("never touches another user's data", async () => {
    const mine = await signIn("a@example.com");
    const theirs = await signIn("b@example.com");
    await sync(mine, { operations: [planCreate()] });
    const res = await sync(theirs, { operations: [sessionUpdate(id(211), 1, { notes: "mine now" }), { idempotencyKey: k(), kind: "plan.delete", id: id(101), baseRevision: 1 }] });
    expect(res.results.map((r: Json) => r.problem.status)).toEqual([404, 404]);
    expect(res.changes.plans).toEqual([]);
    // Nor can they read my idempotency keys.
    const op = planCreate(2);
    await sync(mine, { operations: [op] });
    expect((await sync(theirs, { operations: [op] })).results[0].status).toBe("rejected"); // an id in use, not a duplicate
  });

  it("stops at the query budget and answers only what it reached; the client resends the rest", async () => {
    const token = await signIn();
    await sync(token, { operations: [planCreate()] });
    const ops = Array.from({ length: 60 }, (_, i) => ({ idempotencyKey: id(5000 + i), kind: "checkin.create", id: id(6000 + i), sessionId: id(211), data: { when: "before", feel: 3 } }));
    const first = await sync(token, { operations: ops });
    expect(first.results.length).toBeGreaterThan(0);
    expect(first.results.length).toBeLessThan(60);
    expect(first.results.map((r: Json) => r.idempotencyKey)).toEqual(ops.slice(0, first.results.length).map((o) => o.idempotencyKey));
    let rest = ops.slice(first.results.length);
    let calls = 1;
    while (rest.length > 0) {
      const next = await sync(token, { operations: rest });
      expect(next.results.length).toBeGreaterThan(0);
      rest = rest.slice(next.results.length);
      calls += 1;
    }
    expect(calls).toBeGreaterThan(1);
    // A full resend of the whole queue is all duplicates and costs no writes.
    const all = await sync(token, { operations: ops });
    expect(all.results.every((r: Json) => r.status === "duplicate")).toBe(true);
    expect(all.results).toHaveLength(60);
  });

  it("pages a large pull with the cursor, once, in order", async () => {
    const token = await signIn();
    const sessions = Array.from({ length: 150 }, (_, i) => easy(i + 1, "2026-11-03", { id: id(10_000 + i) }));
    await sync(token, { operations: [{ idempotencyKey: k(), kind: "plan.create", id: id(101), data: { ...planData(1), sessions } }] });
    const seen: string[] = [];
    let cursor: string | undefined;
    for (let calls = 0; calls < 10; calls++) {
      const res = await sync(token, { ...(cursor ? { cursor } : {}), operations: [] });
      seen.push(...res.changes.sessions.map((s: Json) => s.id));
      cursor = res.cursor;
      if (!res.hasMore) break;
    }
    expect(seen).toHaveLength(150);
    expect(new Set(seen).size).toBe(150);
  });

  describe("requests the spec forbids", () => {
    const bad = (name: string, body: unknown) =>
      it(`${name} is a 400`, async () => {
        const token = await signIn();
        const res = await send(token, body);
        expect(res.status).toBe(400);
        expect(res.headers.get("content-type")).toContain("application/problem+json");
      });
    bad("an unknown top-level field", { operations: [], extra: 1 });
    bad("no operations list", {});
    bad("more than 200 operations", { operations: Array.from({ length: 201 }, (_, i) => ({ idempotencyKey: id(i + 1), kind: "plan.delete", id: id(1), baseRevision: 1 })) });
    bad("an unknown kind", { operations: [{ idempotencyKey: id(1), kind: "plan.rename", id: id(1) }] });
    bad("an unknown field in an operation", { operations: [{ idempotencyKey: id(1), kind: "plan.delete", id: id(1), baseRevision: 1, extra: 1 }] });
    bad("a bad key", { operations: [{ idempotencyKey: "nope", kind: "plan.delete", id: id(1), baseRevision: 1 }] });
    bad("a missing base revision", { operations: [{ idempotencyKey: id(1), kind: "session.delete", id: id(1) }] });
    bad("an unknown field in plan data", { operations: [{ idempotencyKey: id(1), kind: "plan.create", id: id(101), data: { ...planData(1), extra: 1 } }] });
    bad("plan data whose id is not the operation's", { operations: [{ idempotencyKey: id(1), kind: "plan.create", id: id(102), data: planData(1) }] });
    bad("an id inside session data", { operations: [{ idempotencyKey: id(1), kind: "session.create", id: id(250), planId: id(101), data: easy(50, "2026-11-10") }] });
    bad("a bad check-in", { operations: [{ idempotencyKey: id(1), kind: "checkin.create", id: id(300), sessionId: id(211), data: { when: "after", feel: 9 } }] });
    bad("an unknown field in a session update", { operations: [{ idempotencyKey: id(1), kind: "session.update", id: id(211), baseRevision: 1, data: { extra: 1 } }] });
    bad("a cursor this server did not make", { cursor: "garbage!", operations: [] });
    bad("the same key twice", { operations: [1, 2].map((n) => ({ idempotencyKey: id(1), kind: "session.delete", id: id(n), baseRevision: 1 })) });
    it("a body over 1 MB is a 413", async () => {
      const token = await signIn();
      const res = await send(token, { operations: [], pad: "x".repeat(1_000_001) });
      expect(res.status).toBe(413);
    });
    it("a body that is not JSON is a 400", async () => {
      const token = await signIn();
      const res = await app.request("/v1/sync", { method: "POST", headers: { authorization: `Bearer ${token}` }, body: "{" });
      expect(res.status).toBe(400);
    });
  });
});
