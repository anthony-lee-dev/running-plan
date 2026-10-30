import { beforeEach, describe, expect, it } from "vitest";
import { createApp } from "../src/app";
import { MemoryEmailSender, memoryDeps } from "../src/adapters/memory";
import { parseCheckInCreate } from "../src/domain/checkins";

const SECRET = "test-secret-test-secret-test-secret";
type Json = Record<string, any>; // eslint-disable-line @typescript-eslint/no-explicit-any
const id = (n: number) => `00000000-0000-4000-8000-${String(n).padStart(12, "0")}`;
const P = id(101);
const S1 = id(201);
const C1 = id(301);

describe("parseCheckInCreate", () => {
  it("accepts a full after-session check-in and a minimal before one", () => {
    const full = { id: C1, when: "after", feel: 4, effortFelt: 7, pain: false, note: "Felt good" };
    expect(parseCheckInCreate(full)).toEqual({ ok: true, value: full });
    expect(parseCheckInCreate({ id: C1, when: "before", feel: 3 })).toEqual({ ok: true, value: { id: C1, when: "before", feel: 3 } });
  });

  it.each<[string, unknown, string]>([
    ["not an object", 1, "/"],
    ["no id", { when: "after", feel: 3 }, "/id"],
    ["an id that is not a UUID", { id: "x", when: "after", feel: 3 }, "/id"],
    ["an unknown when", { id: C1, when: "during", feel: 3 }, "/when"],
    ["feel 0", { id: C1, when: "after", feel: 0 }, "/feel"],
    ["feel 6", { id: C1, when: "after", feel: 6 }, "/feel"],
    ["effort 11", { id: C1, when: "after", feel: 3, effortFelt: 11 }, "/effortFelt"],
    ["effort before a session", { id: C1, when: "before", feel: 3, effortFelt: 5 }, "/effortFelt"],
    ["pain as text", { id: C1, when: "after", feel: 3, pain: "yes" }, "/pain"],
    ["a long note", { id: C1, when: "after", feel: 3, note: "x".repeat(501) }, "/note"],
    ["an unknown field", { id: C1, when: "after", feel: 3, mood: "ok" }, "/mood"],
  ])("rejects %s", (_name, body, path) => {
    const result = parseCheckInCreate(body);
    expect(result.ok).toBe(false);
    if (!result.ok) expect(result.errors.map((e) => e.path)).toContain(path);
  });
});

describe("POST /v1/sessions/{id}/checkins", () => {
  let app: ReturnType<typeof createApp>;
  let email: MemoryEmailSender;
  let token: string;
  async function signIn(address = "runner@example.com"): Promise<string> {
    const headers = { "content-type": "application/json" };
    await app.request("/v1/auth/email/start", { method: "POST", body: JSON.stringify({ email: address }), headers });
    const res = await app.request("/v1/auth/email/verify", { method: "POST", body: JSON.stringify({ email: address, code: email.sent.at(-1)!.code, clientType: "ios" }), headers });
    return ((await res.json()) as { accessToken: string }).accessToken;
  }
  const call = (method: string, path: string, body?: unknown, as = token) =>
    app.request(path, { method, headers: { authorization: `Bearer ${as}`, "content-type": "application/json" }, ...(body !== undefined ? { body: JSON.stringify(body) } : {}) });
  const post = (body: unknown, sessionId = S1, as = token) => call("POST", `/v1/sessions/${sessionId}/checkins`, body, as);

  beforeEach(async () => {
    email = new MemoryEmailSender();
    app = createApp(memoryDeps({ email, authConfig: { jwtSecret: SECRET } }));
    token = await signIn();
    await call("POST", "/v1/plans", {
      id: P, goal: { type: "5k" }, startDate: "2026-10-26", weekCount: 8, source: "blank", adaptive: false, weeks: [],
      sessions: [{ id: S1, date: "2026-10-28", type: "easy", steps: [{ kind: "work", goal: { type: "distance", value: 5000 }, target: { type: "effort", effort: "easy" } }] }],
    });
  });

  it("records a check-in with 201 in the CheckIn shape", async () => {
    const res = await post({ id: C1, when: "after", feel: 2, effortFelt: 8, pain: true, note: "Calf tight" });
    expect(res.status).toBe(201);
    const body = (await res.json()) as Json;
    expect(body).toEqual({ id: C1, sessionId: S1, revision: 1, updatedAt: expect.any(String), deletedAt: null, when: "after", feel: 2, effortFelt: 8, pain: true, note: "Calf tight" });
  });

  it("answers a repeat with the same id and body with 200 and the stored check-in", async () => {
    const first = (await (await post({ id: C1, when: "before", feel: 3 })).json()) as Json;
    const again = await post({ id: C1, when: "before", feel: 3 });
    expect(again.status).toBe(200);
    expect(await again.json()).toEqual(first);
    expect(first.pain).toBe(false);
  });

  it("answers the same id with another body, or another user's id, with 409", async () => {
    await post({ id: C1, when: "before", feel: 3 });
    expect((await post({ id: C1, when: "before", feel: 4 })).status).toBe(409);
    const other = await signIn("other@example.com");
    expect((await post({ id: C1, when: "before", feel: 3 }, S1, other)).status).toBe(404);
  });

  it("answers 404 for an unknown or deleted session", async () => {
    expect((await post({ id: C1, when: "after", feel: 3 }, id(299))).status).toBe(404);
    const del = await app.request(`/v1/sessions/${S1}`, { method: "DELETE", headers: { authorization: `Bearer ${token}`, "if-match": '"1"' } });
    expect(del.status).toBe(200);
    expect((await post({ id: C1, when: "after", feel: 3 })).status).toBe(404);
  });

  it("answers 400 with the invalid fields", async () => {
    const res = await post({ id: C1, when: "before", feel: 9, effortFelt: 5 });
    expect(res.status).toBe(400);
    expect(((await res.json()) as Json).errors.map((e: Json) => e.path).sort()).toEqual(["/effortFelt", "/feel"]);
  });
});
