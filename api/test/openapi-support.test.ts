// The contract checker must fail bad responses, or the contract suite proves nothing.
import { describe, expect, it } from "vitest";
import { requestErrors, responseErrors } from "./support/openapi";

const json = (body: unknown, status = 200, type = "application/json") =>
  new Response(JSON.stringify(body), { status, headers: { "content-type": type } });
const health = { status: "ok", storage: true, time: "2026-10-30T12:00:00.000Z" };

describe("contract checker", () => {
  it("passes a response that matches the spec", async () => {
    expect(await responseErrors("GET /v1/health", json(health))).toEqual([]);
  });

  it("fails an undocumented status, a wrong content type, a missing field and a wrong type", async () => {
    expect(await responseErrors("GET /v1/health", json(health, 418))).toHaveLength(1);
    expect(await responseErrors("GET /v1/health", json(health, 200, "text/plain"))).toHaveLength(1);
    expect(await responseErrors("GET /v1/health", json({ status: "ok", storage: true }))).not.toEqual([]);
    expect(await responseErrors("GET /v1/health", json({ ...health, storage: "yes" }))).not.toEqual([]);
  });

  it("checks shared error responses as problem+json", async () => {
    const problem = { type: "unauthorized", title: "Sign in", status: 401 };
    expect(await responseErrors("GET /v1/profile", json(problem, 401, "application/problem+json"))).toEqual([]);
    expect(await responseErrors("GET /v1/profile", json(problem, 401))).toHaveLength(1);
  });

  it("fails a body on a response the spec leaves empty", async () => {
    expect(await responseErrors("DELETE /v1/account", new Response(null, { status: 204 }))).toEqual([]);
    expect(await responseErrors("POST /v1/auth/email/start", json({ ok: true }, 202))).toHaveLength(1);
  });

  it("rejects unknown fields in requests, including inside allOf compositions", () => {
    expect(requestErrors("POST /v1/auth/email/start", { email: "a@example.com" })).toEqual([]);
    expect(requestErrors("POST /v1/auth/email/start", { email: "a@example.com", extra: 1 })).not.toEqual([]);
    const checkIn = { id: "00000000-0000-4000-8000-000000000001", when: "after", feel: 4 };
    expect(requestErrors("POST /v1/sessions/{sessionId}/checkins", checkIn)).toEqual([]);
    expect(requestErrors("POST /v1/sessions/{sessionId}/checkins", { ...checkIn, extra: 1 })).not.toEqual([]);
  });
});
