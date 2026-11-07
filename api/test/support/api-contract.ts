// Contract tests: each call goes through a real entry and its response must match `spec/openapi.yaml` (status,
// documented headers, content type, body schema). Run against the Node app and the Workers entry so both stay on the contract.
// A new endpoint gets a case here; until it is built it stays in `NOT_BUILT`, and the last test fails otherwise.
import { beforeEach, describe, expect, it } from "vitest";
import { placeholderPath, requestErrors, responseErrors, specOperations } from "./openapi";

export interface ContractTarget {
  fetch(request: Request): Response | Promise<Response>;
  /** The last sign-in code emailed to this address. */
  lastCode(email: string): string;
  reset(): Promise<void>;
}

/** Spec operations with no route yet. Remove one when its slice builds it, and add its cases. */
export const NOT_BUILT = new Set([
  "POST /v1/plans/{planId}/proposals:generate",
  "GET /v1/plans/{planId}/proposals",
  "POST /v1/proposals/{proposalId}:accept",
  "POST /v1/proposals/{proposalId}:dismiss",
  "GET /v1/plans/{planId}/reviews/{weekIndex}",
]);

type Json = Record<string, any>; // eslint-disable-line @typescript-eslint/no-explicit-any

export interface Call {
  token?: string;
  body?: unknown;
  headers?: Record<string, string>;
}

export const EMAIL = "runner@example.com";
const id = (n: number) => `00000000-0000-4000-8000-${String(n).padStart(12, "0")}`;
const easy = (n: number, date: string, over: Json = {}) => ({
  id: id(200 + n),
  date,
  type: "easy",
  steps: [{ kind: "work", goal: { type: "distance", value: 5000 }, target: { type: "effort", effort: "easy" } }],
  ...over,
});
const planBody = (n: number, over: Json = {}) => ({
  id: id(100 + n),
  goal: { type: "5k", date: "2027-01-10" },
  startDate: "2026-11-02",
  weekCount: 8,
  source: "rules",
  engine: { presetId: "5k", version: "1.0.0" },
  adaptive: true,
  weeks: [{ index: 0, phase: "base" }],
  sessions: [easy(10 * n + 1, "2026-11-03"), easy(10 * n + 2, "2026-11-05")],
  ...over,
});
const run = (n: number, localDate: string, over: Json = {}) => ({
  source: "apple_health",
  externalId: `HK-${n}`,
  workoutType: "running",
  startedAt: `${localDate}T07:00:00-04:00`,
  localDate,
  durationSec: 1800,
  distanceM: 5000,
  ...over,
});
const etag = (res: { headers: Headers }) => ({ "if-match": res.headers.get("etag")! });
/** `If-Match` for a session write result, which carries the revision in its body. */
const sessionTag = (res: { json: Json }) => ({ "if-match": `"${res.json.session.revision}"` });

export const GENERATE_BODY = {
  answers: { goal: { distance: "5k", date: "2027-01-10" }, weeklyDistanceM: 15000, runsPerWeek: 3 },
  today: "2026-11-02",
};

export function apiContract(name: string, setup: () => Promise<ContractTarget>) {
  describe(`API contract (${name})`, () => {
    let target: ContractTarget;
    const covered = new Set<string>();

    beforeEach(async () => {
      target = await setup();
      await target.reset();
    });

    /** Sends `op` (with `path` filled in) and checks the response against the spec. Returns status and body. */
    async function call(op: string, path: string, { token, body, headers = {} }: Call = {}) {
      const method = op.split(" ")[0]!;
      const res = await target.fetch(
        new Request(`http://localhost${path}`, {
          method,
          headers: {
            "cf-connecting-ip": "203.0.113.9",
            ...(token ? { authorization: `Bearer ${token}` } : {}),
            ...(body !== undefined ? { "content-type": "application/json" } : {}),
            ...headers,
          },
          ...(body !== undefined ? { body: JSON.stringify(body) } : {}),
        }),
      );
      const copy = res.clone();
      expect(await responseErrors(op, res)).toEqual([]);
      covered.add(op);
      const text = await copy.text();
      return { status: copy.status, headers: copy.headers, json: text ? JSON.parse(text) : undefined };
    }

    /** A valid body (checked against the spec first) gets `status`. */
    async function ok(op: string, path: string, status: number, c: Call = {}) {
      if (c.body !== undefined) expect(requestErrors(op, c.body)).toEqual([]);
      const res = await call(op, path, c);
      expect(res.status).toBe(status);
      return res;
    }

    /**
     * A body with a field the spec forbids (`field`, a JSON pointer such as `/answers/goal/extra`) gets a 400, and
     * for that field: the spec flags it there, and the same body without it is not a 400. Its problem names the
     * field when the route lists field errors.
     */
    async function rejected(op: string, path: string, c: Call & { body: Json }, field: string) {
      expect(requestErrors(op, c.body).some((e) => e.startsWith(`#${field} `))).toBe(true);
      const res = await call(op, path, c);
      expect(res.status).toBe(400);
      if (Array.isArray(res.json?.errors)) expect(res.json.errors.map((e: { path: string }) => e.path)).toContain(field);
      const without = structuredClone(c.body);
      const keys = field.split("/").slice(1);
      const parent = keys.slice(0, -1).reduce((node: Json, k) => node[k], without);
      delete parent[keys.at(-1)!];
      expect(requestErrors(op, without)).toEqual([]);
      const control = await call(op, path, { ...c, body: without });
      expect(control.status).not.toBe(400);
      return control;
    }

    async function signIn(email = EMAIL, clientType = "ios") {
      await ok("POST /v1/auth/email/start", "/v1/auth/email/start", 202, { body: { email } });
      const res = await ok("POST /v1/auth/email/verify", "/v1/auth/email/verify", 200, {
        body: { email, code: target.lastCode(email), clientType },
      });
      return res.json as { accessToken: string; refreshToken: string };
    }

    it("health", async () => {
      await ok("GET /v1/health", "/v1/health", 200);
    });

    it("auth: start, verify, refresh, and their errors", async () => {
      const tokens = await signIn();
      await ok("POST /v1/auth/refresh", "/v1/auth/refresh", 200, { body: { refreshToken: tokens.refreshToken } });
      // The rotated token is now reused: the family is revoked.
      await ok("POST /v1/auth/refresh", "/v1/auth/refresh", 401, { body: { refreshToken: tokens.refreshToken } });

      await ok("POST /v1/auth/email/start", "/v1/auth/email/start", 202, { body: { email: "other@example.com" } });
      await ok("POST /v1/auth/email/verify", "/v1/auth/email/verify", 401, {
        body: { email: "other@example.com", code: target.lastCode("other@example.com") === "000000" ? "111111" : "000000", clientType: "ios" },
      });

      await rejected("POST /v1/auth/email/start", "/v1/auth/email/start", { body: { email: EMAIL, extra: 1 } }, "/extra");
      await rejected("POST /v1/auth/email/verify", "/v1/auth/email/verify", { body: { email: EMAIL, code: "123456", clientType: "ios", extra: 1 } }, "/extra");
      await rejected("POST /v1/auth/refresh", "/v1/auth/refresh", { body: { refreshToken: "x", extra: 1 } }, "/extra");
      const badEmail = { email: "not an email" };
      expect(requestErrors("POST /v1/auth/email/start", badEmail)).not.toEqual([]);
      expect((await call("POST /v1/auth/email/start", "/v1/auth/email/start", { body: badEmail })).status).toBe(400);
    });

    it("account delete", async () => {
      const { accessToken } = await signIn();
      await ok("DELETE /v1/account", "/v1/account", 401);
      await ok("DELETE /v1/account", "/v1/account", 204, { token: accessToken });
      await ok("GET /v1/profile", "/v1/profile", 401, { token: accessToken });
    });

    it("account export: empty, then with a plan, a confirmed match and a check-in, and the rate limit", async () => {
      const { accessToken: token } = await signIn();
      const X = "/v1/account/export";
      await ok("POST /v1/account/export", X, 401);
      const empty = await ok("POST /v1/account/export", X, 200, { token });
      expect(empty.json).toMatchObject({ email: EMAIL, plans: [], activities: [], checkins: [], proposals: [] });
      await ok("POST /v1/plans", "/v1/plans", 201, { token, body: planBody(1) });
      const up = await ok("POST /v1/activities:batch", "/v1/activities:batch", 200, { token, body: { activities: [run(1, "2026-11-03"), run(2, "2026-11-04")] } });
      const [a1] = (up.json.results as { activityId: string }[]).map((r) => r.activityId);
      await ok("PUT /v1/sessions/{sessionId}/match", `/v1/sessions/${id(211)}/match`, 200, { token, body: { activityId: a1, status: "confirmed" } });
      await ok("POST /v1/sessions/{sessionId}/checkins", `/v1/sessions/${id(211)}/checkins`, 201, { token, body: { id: id(301), when: "after", feel: 4, effortFelt: 6, note: "ok" } });
      const full = await ok("POST /v1/account/export", X, 200, { token });
      expect(full.json.plans).toHaveLength(1);
      expect(full.json.plans[0].sessions).toHaveLength(2);
      expect(full.json.activities).toHaveLength(2);
      expect(full.json.activities.find((a: Json) => a.id === a1).match).toMatchObject({ sessionId: id(211), status: "confirmed" });
      expect(full.json.checkins).toHaveLength(1);
      // Two used so far; the fifth still answers, the sixth is rate limited.
      for (let i = 0; i < 3; i++) await ok("POST /v1/account/export", X, 200, { token });
      const limited = await ok("POST /v1/account/export", X, 429, { token });
      expect(Number(limited.headers.get("retry-after"))).toBeGreaterThan(0);
    });

    it("profile: read, update, conflicts, unknown fields", async () => {
      const { accessToken: token } = await signIn();
      await ok("GET /v1/profile", "/v1/profile", 401);
      const before = await ok("GET /v1/profile", "/v1/profile", 200, { token });
      const revision = `"${before.json.revision}"`;
      const updated = await ok("PATCH /v1/profile", "/v1/profile", 200, {
        token,
        body: { targetDisplay: "heart_rate" },
        headers: { "if-match": revision },
      });
      expect(updated.json.targetDisplay).toBe("heart_rate");
      await ok("PATCH /v1/profile", "/v1/profile", 409, { token, body: { targetDisplay: "pace" }, headers: { "if-match": revision } });
      const current = { "if-match": `"${updated.json.revision}"` };
      await ok("PATCH /v1/profile", "/v1/profile", 400, { token, body: { targetDisplay: "pace" } }); // no If-Match
      // The control call in `rejected` saves, so the second case needs the revision after it.
      await rejected("PATCH /v1/profile", "/v1/profile", { token, body: { targetDisplay: "pace", extra: 1 }, headers: current }, "/extra");
      const latest = await ok("GET /v1/profile", "/v1/profile", 200, { token });
      await rejected(
        "PATCH /v1/profile",
        "/v1/profile",
        { token, body: { paces: { easy: { minSecPerKm: 380, maxSecPerKm: 420 }, extra: 1 } }, headers: { "if-match": `"${latest.json.revision}"` } },
        "/paces/extra",
      );
    });

    it("generate: a draft and bad input", async () => {
      await ok("POST /v1/plans/generate", "/v1/plans/generate", 200, { body: GENERATE_BODY });
      await rejected("POST /v1/plans/generate", "/v1/plans/generate", { body: { ...GENERATE_BODY, extra: 1 } }, "/extra");
      await rejected(
        "POST /v1/plans/generate",
        "/v1/plans/generate",
        { body: { ...GENERATE_BODY, answers: { ...GENERATE_BODY.answers, goal: { ...GENERATE_BODY.answers.goal, extra: 1 } } } },
        "/answers/goal/extra",
      );
    });

    it("plans: create, read, list, update, delete", async () => {
      const { accessToken: token } = await signIn();
      const P = `/v1/plans/${id(101)}`;
      await ok("GET /v1/plans", "/v1/plans", 401);
      const created = await ok("POST /v1/plans", "/v1/plans", 201, { token, body: planBody(1) });
      await ok("POST /v1/plans", "/v1/plans", 200, { token, body: planBody(1) }); // the same create again
      await ok("POST /v1/plans", "/v1/plans", 409, { token, body: planBody(1, { weekCount: 9 }) });
      await rejected("POST /v1/plans", "/v1/plans", { token, body: planBody(2, { extra: 1 }) }, "/extra");
      await rejected("POST /v1/plans", "/v1/plans", { token, body: planBody(3, { sessions: [easy(31, "2026-11-03", { extra: 1 })] }) }, "/sessions/0/extra");

      await ok("GET /v1/plans", "/v1/plans", 200, { token });
      await ok("GET /v1/plans/{planId}", P, 200, { token });
      await ok("GET /v1/plans/{planId}", `/v1/plans/${id(199)}`, 404, { token });

      const updated = await ok("PATCH /v1/plans/{planId}", P, 200, { token, body: { adaptive: false }, headers: etag(created) });
      await ok("PATCH /v1/plans/{planId}", P, 409, { token, body: { adaptive: true }, headers: etag(created) });
      await rejected("PATCH /v1/plans/{planId}", P, { token, body: { adaptive: true, extra: 1 }, headers: etag(updated) }, "/extra");
      const latest = await ok("GET /v1/plans/{planId}", P, 200, { token });
      await ok("DELETE /v1/plans/{planId}", P, 409, { token, headers: etag(created) });
      await ok("DELETE /v1/plans/{planId}", P, 204, { token, headers: etag(latest) });
      await ok("DELETE /v1/plans/{planId}", P, 404, { token, headers: etag(latest) });
    });

    it("sessions: add, update, delete", async () => {
      const { accessToken: token } = await signIn();
      await ok("POST /v1/plans", "/v1/plans", 201, { token, body: planBody(1) });
      const S = `/v1/plans/${id(101)}/sessions`;
      const added = await ok("POST /v1/plans/{planId}/sessions", S, 201, { token, body: easy(1, "2026-11-07") });
      await ok("POST /v1/plans/{planId}/sessions", S, 200, { token, body: easy(1, "2026-11-07") });
      await ok("POST /v1/plans/{planId}/sessions", S, 409, { token, body: easy(1, "2026-11-08") });
      await rejected("POST /v1/plans/{planId}/sessions", S, { token, body: easy(2, "2026-11-08", { extra: 1 }) }, "/extra");
      const nested = easy(3, "2026-11-09", { steps: [{ kind: "work", goal: { type: "distance", value: 5000 }, extra: 1 }] });
      await rejected("POST /v1/plans/{planId}/sessions", S, { token, body: nested }, "/steps/0/extra");

      const one = `/v1/sessions/${id(201)}`;
      const patched = await ok("PATCH /v1/sessions/{sessionId}", one, 200, { token, body: { title: "Easy jog" }, headers: sessionTag(added) });
      await ok("PATCH /v1/sessions/{sessionId}", one, 409, { token, body: { title: "Again" }, headers: sessionTag(added) });
      const saved = await rejected("PATCH /v1/sessions/{sessionId}", one, { token, body: { title: "Jog", extra: 1 }, headers: sessionTag(patched) }, "/extra");
      await ok("PATCH /v1/sessions/{sessionId}", `/v1/sessions/${id(299)}`, 404, { token, body: { title: "x" }, headers: { "if-match": '"1"' } });
      const latest = await ok("PATCH /v1/sessions/{sessionId}", one, 200, { token, body: { title: "Last" }, headers: sessionTag(saved) });
      await ok("DELETE /v1/sessions/{sessionId}", one, 409, { token, headers: sessionTag(saved) });
      await ok("DELETE /v1/sessions/{sessionId}", one, 200, { token, headers: sessionTag(latest) });
      await ok("DELETE /v1/sessions/{sessionId}", one, 404, { token, headers: sessionTag(latest) });
    });

    it("activities, matches and check-ins", async () => {
      const { accessToken: token } = await signIn();
      await ok("POST /v1/plans", "/v1/plans", 201, { token, body: planBody(1) });
      const batch = "/v1/activities:batch";
      await ok("POST /v1/activities:batch", batch, 401, { body: { activities: [run(1, "2026-11-03")] } });
      const web = await signIn("web@example.com", "web"); // a web token cannot write activities
      await ok("POST /v1/activities:batch", batch, 403, { token: web.accessToken, body: { activities: [run(1, "2026-11-03")] } });
      const up = await ok("POST /v1/activities:batch", batch, 200, { token, body: { activities: [run(1, "2026-11-03"), run(2, "2026-11-04")] } });
      await rejected("POST /v1/activities:batch", batch, { token, body: { activities: [run(3, "2026-11-04", { extra: 1 })] } }, "/activities/0/extra");
      await rejected("POST /v1/activities:batch", batch, { token, body: { activities: [run(4, "2026-11-05")], extra: 1 } }, "/extra");
      await ok("GET /v1/activities", "/v1/activities?from=2026-11-01&to=2026-11-30", 200, { token });
      await ok("GET /v1/activities", "/v1/activities?inbox=true", 200, { token });

      const [a1, a2] = (up.json.results as { activityId: string }[]).map((r) => r.activityId);
      const A2 = `/v1/activities/${a2}`;
      await ok("PATCH /v1/activities/{activityId}", A2, 200, { token, body: { disposition: "extra" } });
      await ok("PATCH /v1/activities/{activityId}", `/v1/activities/${id(999)}`, 404, { token, body: { disposition: "extra" } });
      await rejected("PATCH /v1/activities/{activityId}", A2, { token, body: { disposition: "ignored", extra: 1 } }, "/extra");

      const M = `/v1/sessions/${id(211)}/match`;
      await ok("PUT /v1/sessions/{sessionId}/match", M, 200, { token, body: { activityId: a1, status: "confirmed" } });
      await ok("PUT /v1/sessions/{sessionId}/match", `/v1/sessions/${id(299)}/match`, 404, { token, body: { activityId: a1, status: "confirmed" } });
      await rejected("PUT /v1/sessions/{sessionId}/match", M, { token, body: { activityId: a1, status: "suggested", extra: 1 } }, "/extra");
      await ok("DELETE /v1/sessions/{sessionId}/match", M, 200, { token });
      await ok("DELETE /v1/sessions/{sessionId}/match", M, 404, { token });

      const G = `/v1/plans/${id(101)}/progress`;
      await ok("GET /v1/plans/{planId}/progress", `${G}?today=2026-11-03`, 401);
      await ok("GET /v1/plans/{planId}/progress", `${G}?today=2026-11-03`, 200, { token });
      await ok("GET /v1/plans/{planId}/progress", `/v1/plans/${id(299)}/progress?today=2026-11-03`, 404, { token });

      const C = `/v1/sessions/${id(211)}/checkins`;
      const checkIn = { id: id(301), when: "after", feel: 4, effortFelt: 6 };
      await ok("POST /v1/sessions/{sessionId}/checkins", C, 201, { token, body: checkIn });
      await ok("POST /v1/sessions/{sessionId}/checkins", C, 200, { token, body: checkIn });
      await rejected("POST /v1/sessions/{sessionId}/checkins", C, { token, body: { id: id(302), when: "after", feel: 3, extra: 1 } }, "/extra");
      await ok("POST /v1/sessions/{sessionId}/checkins", `/v1/sessions/${id(299)}/checkins`, 404, { token, body: { id: id(303), when: "after", feel: 3 } });
    });

    it("sync: push, conflict, duplicate, pull and forbidden shapes", async () => {
      const { accessToken: token } = await signIn();
      const S = "/v1/sync";
      const op = (n: number, over: Json) => ({ idempotencyKey: id(800 + n), id: id(211), ...over });
      await ok("POST /v1/sync", S, 401, { body: { operations: [] } });
      await ok("POST /v1/sync", S, 200, { token, body: { operations: [{ idempotencyKey: id(800), kind: "plan.create", id: id(101), data: planBody(1) }] } });
      const pulled = await ok("POST /v1/sync", S, 200, { token, body: { operations: [] } });
      expect(pulled.json.changes.sessions).toHaveLength(2);
      const edit = op(1, { kind: "session.update", baseRevision: 1, data: { status: "done" } });
      const first = await ok("POST /v1/sync", S, 200, { token, body: { cursor: pulled.json.cursor, operations: [edit] } });
      expect(first.json.results[0]).toMatchObject({ status: "applied", revision: 2 });
      expect(first.json.changes.sessions).toHaveLength(1);
      const again = await ok("POST /v1/sync", S, 200, { token, body: { operations: [edit] } });
      expect(again.json.results[0]).toMatchObject({ status: "duplicate", revision: 2 });
      const stale = await ok("POST /v1/sync", S, 200, { token, body: { operations: [op(2, { kind: "session.update", baseRevision: 1, data: { notes: "x" } })] } });
      expect(stale.json.results[0]).toMatchObject({ status: "conflict", server: { revision: 2 } });
      const gone = await ok("POST /v1/sync", S, 200, { token, body: { operations: [op(3, { kind: "session.delete", baseRevision: 2 })] } });
      expect(gone.json.changes.sessions.find((s: Json) => s.id === id(211)).deletedAt).not.toBeNull();
      // More shapes the response schema must hold: a created session, a check-in in the pull, a plan conflict, a rejection.
      const rest = await ok("POST /v1/sync", S, 200, {
        token,
        body: {
          cursor: gone.json.cursor,
          operations: [
            op(5, { kind: "session.create", id: id(230), planId: id(101), data: (({ id: _id, ...content }) => content)(easy(30, "2026-11-10")) }),
            op(6, { kind: "checkin.create", id: id(330), sessionId: id(212), data: { when: "after", feel: 4, effortFelt: 5, pain: false, note: "ok" } }),
            op(7, { kind: "plan.update", id: id(101), baseRevision: 1, data: { adaptive: false } }),
            op(8, { kind: "plan.update", id: id(101), baseRevision: 1, data: { adaptive: true } }),
            op(9, { kind: "session.update", id: id(299), baseRevision: 1, data: { notes: "x" } }),
          ],
        },
      });
      expect(rest.json.results.map((r: Json) => r.status)).toEqual(["applied", "applied", "applied", "conflict", "rejected"]);
      expect(rest.json.results[3].server).toMatchObject({ id: id(101), revision: 2 });
      expect(rest.json.results[4].problem.status).toBe(404);
      expect(rest.json.changes.checkins).toMatchObject([{ id: id(330), sessionId: id(212), when: "after" }]);
      await ok("POST /v1/sync", S, 400, { token, body: { operations: [], cursor: "garbage!" } });
      await rejected("POST /v1/sync", S, { token, body: { operations: [], extra: 1 } }, "/extra");
      await rejected("POST /v1/sync", S, { token, body: { operations: [op(4, { kind: "session.delete", baseRevision: 1, extra: 1 })] } }, "/operations/0/extra");
    });

    it("operations listed as not built have no route yet", async () => {
      const { accessToken } = await signIn();
      for (const op of NOT_BUILT) {
        const [method, path] = op.split(" ") as [string, string];
        const res = await target.fetch(
          new Request(`http://localhost${placeholderPath(path)}`, { method, headers: { authorization: `Bearer ${accessToken}` } }),
        );
        expect(`${op} ${res.status}`).toBe(`${op} 404`);
      }
    });

    // Keep this last: it reads what the cases above covered (vitest runs a file's tests in order), so running
    // a single case with `-t` makes it report the rest as missing.
    it("every built operation in the spec has a contract case", () => {
      const missing = specOperations().filter((op) => !NOT_BUILT.has(op) && !covered.has(op));
      expect(missing).toEqual([]);
    });
  });
}
