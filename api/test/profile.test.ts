import { beforeEach, describe, expect, it } from "vitest";
import { createApp } from "../src/app";
import { MemoryEmailSender, memoryDeps } from "../src/adapters/memory";

const SECRET = "test-secret-test-secret-test-secret";

let app: ReturnType<typeof createApp>;
let email: MemoryEmailSender;

beforeEach(() => {
  email = new MemoryEmailSender();
  app = createApp(memoryDeps({ email, authConfig: { jwtSecret: SECRET } }));
});

async function signIn(address = "runner@example.com", clientType = "ios"): Promise<string> {
  await app.request("/v1/auth/email/start", { method: "POST", body: JSON.stringify({ email: address }), headers: { "content-type": "application/json" } });
  const res = await app.request("/v1/auth/email/verify", {
    method: "POST",
    body: JSON.stringify({ email: address, code: email.sent.at(-1)!.code, clientType }),
    headers: { "content-type": "application/json" },
  });
  return ((await res.json()) as { accessToken: string }).accessToken;
}

const get = (token?: string) => app.request("/v1/profile", { headers: token ? { authorization: `Bearer ${token}` } : {} });
const patch = (token: string, body: unknown, ifMatch?: string) =>
  app.request("/v1/profile", {
    method: "PATCH",
    body: JSON.stringify(body),
    headers: { authorization: `Bearer ${token}`, "content-type": "application/json", ...(ifMatch ? { "if-match": ifMatch } : {}) },
  });

describe("GET /v1/profile", () => {
  it("needs a token", async () => {
    expect((await get()).status).toBe(401);
    expect((await get("garbage")).status).toBe(401);
  });

  it("returns the defaults at revision 1 with an ETag until first updated", async () => {
    const res = await get(await signIn());
    expect(res.status).toBe(200);
    expect(res.headers.get("etag")).toBe('"1"');
    expect(await res.json()).toMatchObject({
      targetDisplay: "pace",
      paces: { source: "none" },
      heartRate: {},
      scheduling: {},
      review: { frequency: "weekly_plus_urgent" },
      revision: 1,
    });
  });

  it("gives the default profile the same updatedAt on every read", async () => {
    const token = await signIn();
    const first = (await (await get(token)).json()) as { updatedAt: string };
    await new Promise((r) => setTimeout(r, 5));
    expect(((await (await get(token)).json()) as { updatedAt: string }).updatedAt).toBe(first.updatedAt);
  });

  it("works for web clients too (scope app)", async () => {
    expect((await get(await signIn("web@example.com", "web"))).status).toBe(200);
  });
});

describe("PATCH /v1/profile", () => {
  it("needs If-Match, as a quoted revision", async () => {
    const token = await signIn();
    for (const ifMatch of [undefined, "1", '"x"', '"-1"', 'W/"1"']) {
      const res = await patch(token, { targetDisplay: "effort" }, ifMatch);
      expect(res.status, String(ifMatch)).toBe(400);
      expect(res.headers.get("content-type")).toContain("application/problem+json");
    }
  });

  it("updates, moves the revision and returns the new profile and ETag", async () => {
    const token = await signIn();
    const res = await patch(token, { targetDisplay: "effort", review: { frequency: "weekly", day: "sun" } }, '"1"');
    expect(res.status).toBe(200);
    expect(res.headers.get("etag")).toBe('"2"');
    expect(await res.json()).toMatchObject({ targetDisplay: "effort", review: { frequency: "weekly", day: "sun" }, revision: 2 });
    expect(await (await get(token)).json()).toMatchObject({ targetDisplay: "effort", revision: 2 });
  });

  it("leaves other fields alone", async () => {
    const token = await signIn();
    await patch(token, { heartRate: { maxBpm: 190 } }, '"1"');
    const res = await patch(token, { targetDisplay: "heart_rate" }, '"2"');
    expect(await res.json()).toMatchObject({ heartRate: { maxBpm: 190 }, targetDisplay: "heart_rate", revision: 3 });
  });

  it("sets manual paces and marks them manual", async () => {
    const token = await signIn();
    const res = await patch(token, { paces: { easy: { minSecPerKm: 380, maxSecPerKm: 420 } } }, '"1"');
    expect(await res.json()).toMatchObject({ paces: { source: "manual", easy: { minSecPerKm: 380, maxSecPerKm: 420 } } });
  });

  it("answers 409 with the current revision when the base is stale", async () => {
    const token = await signIn();
    await patch(token, { targetDisplay: "effort" }, '"1"');
    const res = await patch(token, { targetDisplay: "pace" }, '"1"');
    expect(res.status).toBe(409);
    expect(res.headers.get("content-type")).toContain("application/problem+json");
    expect(await res.json()).toMatchObject({ type: "revision_conflict", status: 409, currentRevision: 2 });
    expect((await (await get(token)).json() as { targetDisplay: string }).targetDisplay).toBe("effort");
  });

  it("answers 400 with field-level errors for invalid data, and changes nothing", async () => {
    const token = await signIn();
    const res = await patch(token, { heartRate: { maxBpm: 50 }, targetDisplay: "x" }, '"1"');
    expect(res.status).toBe(400);
    const body = (await res.json()) as { errors: { path: string; message: string }[] };
    expect(body.errors.map((e) => e.path).sort()).toEqual(["/heartRate/maxBpm", "/targetDisplay"]);
    expect((await (await get(token)).json() as { revision: number }).revision).toBe(1);
  });

  it("checks the body before the revision, so a bad body is 400 even with a stale base", async () => {
    const token = await signIn();
    await patch(token, { targetDisplay: "effort" }, '"1"');
    expect((await patch(token, { nope: 1 }, '"1"')).status).toBe(400);
  });

  it("rejects a body that is not JSON", async () => {
    const token = await signIn();
    const res = await app.request("/v1/profile", { method: "PATCH", body: "nope", headers: { authorization: `Bearer ${token}`, "if-match": '"1"' } });
    expect(res.status).toBe(400);
  });

  it("keeps users apart", async () => {
    const a = await signIn("a@example.com");
    const b = await signIn("b@example.com");
    await patch(a, { targetDisplay: "effort" }, '"1"');
    expect(await (await get(b)).json()).toMatchObject({ targetDisplay: "pace", revision: 1 });
    expect((await patch(b, { targetDisplay: "heart_rate" }, '"1"')).status).toBe(200);
  });

  it("is gone with the account", async () => {
    const token = await signIn();
    await patch(token, { targetDisplay: "effort" }, '"1"');
    await app.request("/v1/account", { method: "DELETE", headers: { authorization: `Bearer ${token}` } });
    expect((await get(token)).status).toBe(401);
    const again = await signIn();
    expect(await (await get(again)).json()).toMatchObject({ targetDisplay: "pace", revision: 1 });
  });
});
