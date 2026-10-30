// Contract tests: each call goes through a real entry and its response must match `spec/openapi.yaml` (status,
// content type, body schema). Run against the Node app and the Workers entry so both stay on the contract.
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
  "POST /v1/account/export",
  "POST /v1/sync",
  "POST /v1/plans/{planId}/proposals:generate",
  "GET /v1/plans/{planId}/proposals",
  "POST /v1/proposals/{proposalId}:accept",
  "POST /v1/proposals/{proposalId}:dismiss",
  "GET /v1/plans/{planId}/progress",
  "GET /v1/plans/{planId}/reviews/{weekIndex}",
]);

/** Built, but their cases come in the next PR (backlog 2.7, part 2). */
export const NOT_COVERED_YET = new Set([
  "GET /v1/plans",
  "POST /v1/plans",
  "GET /v1/plans/{planId}",
  "PATCH /v1/plans/{planId}",
  "DELETE /v1/plans/{planId}",
  "POST /v1/plans/{planId}/sessions",
  "PATCH /v1/sessions/{sessionId}",
  "DELETE /v1/sessions/{sessionId}",
  "PUT /v1/sessions/{sessionId}/match",
  "DELETE /v1/sessions/{sessionId}/match",
  "POST /v1/sessions/{sessionId}/checkins",
  "POST /v1/activities:batch",
  "GET /v1/activities",
  "PATCH /v1/activities/{activityId}",
]);

type Json = Record<string, any>; // eslint-disable-line @typescript-eslint/no-explicit-any

export interface Call {
  token?: string;
  body?: unknown;
  headers?: Record<string, string>;
}

export const EMAIL = "runner@example.com";
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
      expect((await call(op, path, { ...c, body: without })).status).not.toBe(400);
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
      const missing = specOperations().filter((op) => !NOT_BUILT.has(op) && !NOT_COVERED_YET.has(op) && !covered.has(op));
      expect(missing).toEqual([]);
    });
  });
}
