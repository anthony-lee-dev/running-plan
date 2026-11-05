// Workers Free allows 50 D1 queries per request (a batch counts as one). The sync route spends a budget it counts
// from `OP_COST`; this test counts the real queries the Workers entry makes and checks the costs are not too low.
import { env } from "cloudflare:workers";
import { applyD1Migrations } from "cloudflare:test";
import { beforeAll, beforeEach, describe, expect, it } from "vitest";
import worker from "../../../src/index";
import { FIXED_QUERIES, OP_COST, QUERY_LIMIT, type SyncKind } from "../../../src/domain/sync";

const ctx = { waitUntil() {}, passThroughOnException() {} } as unknown as ExecutionContext;
const SECRET = "budget-test-secret-budget-test-secret";
const id = (n: number) => `00000000-0000-4000-8000-${String(n).padStart(12, "0")}`;
type Json = Record<string, any>; // eslint-disable-line @typescript-eslint/no-explicit-any

/** A D1 binding that counts queries the way Workers does: every statement run, and one per batch. */
function counting(db: D1Database) {
  const state = { queries: 0 };
  const targets = new WeakMap<object, D1PreparedStatement>();
  const wrap = (statement: D1PreparedStatement): D1PreparedStatement => {
    const proxy: D1PreparedStatement = new Proxy(statement, {
      get(target, prop) {
        if (prop === "bind") return (...args: unknown[]) => wrap(target.bind(...args));
        const value = Reflect.get(target, prop, target);
        if (typeof value !== "function") return value;
        if (prop === "first" || prop === "all" || prop === "run" || prop === "raw") {
          return (...args: unknown[]) => {
            state.queries += 1;
            return value.apply(target, args);
          };
        }
        return value.bind(target);
      },
    });
    targets.set(proxy, statement);
    return proxy;
  };
  const proxy = new Proxy(db, {
    get(target, prop) {
      if (prop === "prepare") return (sql: string) => wrap(target.prepare(sql));
      if (prop === "batch") {
        return (statements: D1PreparedStatement[]) => {
          state.queries += 1;
          return target.batch(statements.map((s) => targets.get(s) ?? s));
        };
      }
      const value = Reflect.get(target, prop, target);
      return typeof value === "function" ? value.bind(target) : value;
    },
  });
  return { db: proxy, state };
}

const sent: { to: string; subject: string }[] = [];
const EMAIL = { send: async (m: { to: string; subject: string }) => void sent.push(m) };
const bindings = (db: D1Database) => ({ DB: db, JWT_SECRET: SECRET, EMAIL, MAIL_FROM: "plans@example.com" });
let token: string;

async function signIn(): Promise<string> {
  const headers = { "content-type": "application/json", "cf-connecting-ip": "203.0.113.7" };
  await worker.fetch(new Request("http://x/v1/auth/email/start", { method: "POST", headers, body: JSON.stringify({ email: "r@example.com" }) }), bindings(env.DB), ctx);
  const code = /code is (\d{6})$/.exec(sent.at(-1)!.subject)![1];
  const res = await worker.fetch(new Request("http://x/v1/auth/email/verify", { method: "POST", headers, body: JSON.stringify({ email: "r@example.com", code, clientType: "ios" }) }), bindings(env.DB), ctx);
  return ((await res.json()) as Json).accessToken;
}

/** Sends one sync request and returns the response with the D1 queries the Worker made for it. */
async function counted(body: unknown) {
  const { db, state } = counting(env.DB);
  const res = await worker.fetch(
    new Request("http://x/v1/sync", { method: "POST", headers: { authorization: `Bearer ${token}`, "content-type": "application/json" }, body: JSON.stringify(body) }),
    bindings(db),
    ctx,
  );
  const json = (await res.json()) as Json;
  expect(res.status, JSON.stringify(json)).toBe(200);
  return { json, queries: state.queries };
}

const easy = (n: number, date = "2026-11-03", over: Json = {}) => ({ id: id(n), date, type: "easy", steps: [{ kind: "work", goal: { type: "distance", value: 5000 }, target: { type: "effort", effort: "easy" } }], ...over });
/** A session's content as session.create carries it: the operation holds the id. */
const content = (n: number, date = "2026-11-03") => {
  const { id: _id, ...rest } = easy(n, date);
  return rest;
};
const planData = (n: number, sessions: Json[]) => ({ id: id(n), goal: { type: "5k", date: "2027-01-10" }, startDate: "2026-11-02", weekCount: 8, source: "rules", engine: { presetId: "5k", version: "1.0.0" }, adaptive: true, weeks: [{ index: 0, phase: "base" }], sessions });
let key = 9000;
const op = (kind: SyncKind, over: Json) => ({ idempotencyKey: id(key++), kind, ...over });

beforeAll(async () => {
  await applyD1Migrations(env.DB, env.TEST_MIGRATIONS);
});
beforeEach(async () => {
  await env.DB.batch([env.DB.prepare("DELETE FROM users"), env.DB.prepare("DELETE FROM rate_limits"), env.DB.prepare("DELETE FROM email_codes")]);
  token = await signIn();
  const made = await counted({ operations: [op("plan.create", { id: id(100), data: planData(100, [easy(200), easy(201, "2026-11-05")]) })] });
  expect(made.json.results[0].status).toBe("applied");
});

describe("sync query budget on the Workers entry", () => {
  const cases: [string, SyncKind, () => Json][] = [
    ["plan.create", "plan.create", () => ({ id: id(101), data: planData(101, [easy(210)]) })],
    ["plan.create replayed", "plan.create", () => ({ id: id(100), data: planData(100, [easy(200), easy(201, "2026-11-05")]) })],
    ["plan.create clashing with a session id in the last chunk of 400", "plan.create", () => ({ id: id(102), data: planData(102, [...Array.from({ length: 399 }, (_, i) => easy(1000 + i)), easy(200)]) })],
    ["plan.update", "plan.update", () => ({ id: id(100), baseRevision: 1, data: { adaptive: false, weeks: [{ index: 1, phase: "build" }] } })],
    ["plan.update stale", "plan.update", () => ({ id: id(100), baseRevision: 5, data: { adaptive: false } })],
    ["plan.delete", "plan.delete", () => ({ id: id(100), baseRevision: 1 })],
    ["plan.delete stale", "plan.delete", () => ({ id: id(100), baseRevision: 5 })],
    ["session.create", "session.create", () => ({ id: id(220), planId: id(100), data: content(220, "2026-11-08") })],
    ["session.create replayed", "session.create", () => ({ id: id(200), planId: id(100), data: content(200) })],
    ["session.update", "session.update", () => ({ id: id(200), baseRevision: 1, data: { status: "done", notes: "n" } })],
    ["session.update stale", "session.update", () => ({ id: id(200), baseRevision: 4, data: { status: "done" } })],
    ["session.delete", "session.delete", () => ({ id: id(200), baseRevision: 1 })],
    ["session.delete stale", "session.delete", () => ({ id: id(200), baseRevision: 4 })],
    ["checkin.create", "checkin.create", () => ({ id: id(300), sessionId: id(200), data: { when: "after", feel: 4 } })],
    ["checkin.create replayed", "checkin.create", () => ({ id: id(301), sessionId: id(200), data: { when: "after", feel: 4 } })],
  ];

  it.each(cases)("%s stays within its cost", async (_name, kind, build) => {
    // The replayed cases first apply the operation, then send it again under a new key.
    if (_name.endsWith("replayed")) await counted({ operations: [op(kind, build())] });
    const { json, queries } = await counted({ operations: [op(kind, build())] });
    expect(json.results).toHaveLength(1);
    expect(queries).toBeGreaterThan(5); // the counter works: the token check, key lookup, the operation and the pull
    // The key lookup (1) and the operation's cost, on top of what every call spends.
    // (The spare in FIXED_QUERIES is left out, so a cost one too low fails here.)
    expect(queries).toBeLessThanOrEqual(1 + OP_COST[kind] + FIXED_QUERIES - 1);
    expect(queries).toBeLessThanOrEqual(QUERY_LIMIT);
  });

  it("a full queue stays inside 50 queries and always makes progress", async () => {
    // Worst-priced kinds first, 200 of them: the server must stop early rather than pass 50.
    const ops = Array.from({ length: 200 }, (_, i) => op("session.create", { id: id(5000 + i), planId: id(100), data: content(5000 + i, "2026-11-08") }));
    const { json, queries } = await counted({ operations: ops });
    expect(queries).toBeLessThanOrEqual(QUERY_LIMIT);
    expect(json.results.length).toBeGreaterThan(0);
    expect(json.results.length).toBeLessThan(200);
    // A queue of 200 retries of what was applied costs only the key lookups and the pull.
    const retry = await counted({ operations: ops.slice(0, json.results.length) });
    expect(retry.json.results.every((r: Json) => r.status === "duplicate")).toBe(true);
    expect(retry.queries).toBeLessThanOrEqual(1 + FIXED_QUERIES);
  });
});
