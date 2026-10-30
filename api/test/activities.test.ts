import { beforeEach, describe, expect, it } from "vitest";
import { createApp } from "../src/app";
import { MemoryEmailSender, memoryDeps } from "../src/adapters/memory";

const SECRET = "test-secret-test-secret-test-secret";
type Json = Record<string, any>; // eslint-disable-line @typescript-eslint/no-explicit-any

let app: ReturnType<typeof createApp>;
let email: MemoryEmailSender;
beforeEach(() => {
  email = new MemoryEmailSender();
  app = createApp(memoryDeps({ email, authConfig: { jwtSecret: SECRET } }));
});

async function signIn(address = "runner@example.com", clientType = "ios"): Promise<string> {
  const headers = { "content-type": "application/json" };
  await app.request("/v1/auth/email/start", { method: "POST", body: JSON.stringify({ email: address }), headers });
  const res = await app.request("/v1/auth/email/verify", { method: "POST", body: JSON.stringify({ email: address, code: email.sent.at(-1)!.code, clientType }), headers });
  return ((await res.json()) as { accessToken: string }).accessToken;
}

const upload = (token: string | undefined, body: unknown) =>
  app.request("/v1/activities:batch", {
    method: "POST",
    headers: { "content-type": "application/json", ...(token ? { authorization: `Bearer ${token}` } : {}) },
    body: typeof body === "string" ? body : JSON.stringify(body),
  });
const list = (token: string, query = "") => app.request(`/v1/activities${query}`, { headers: { authorization: `Bearer ${token}` } });

const run = (n: number, localDate: string, over: Record<string, unknown> = {}) => ({
  source: "apple_health",
  externalId: `HK-${n}`,
  workoutType: "running",
  startedAt: `${localDate}T07:00:00-04:00`,
  localDate,
  durationSec: 1800,
  distanceM: 5000,
  ...over,
});

describe("POST /v1/activities:batch", () => {
  it("needs a token", async () => {
    expect((await upload(undefined, { activities: [run(1, "2026-10-28")] })).status).toBe(401);
  });

  it("is for native clients only: a web token gets 403", async () => {
    const web = await signIn("runner@example.com", "web");
    expect((await upload(web, { activities: [run(1, "2026-10-28")] })).status).toBe(403);
  });

  it("creates activities, then reports a re-send as duplicate and a Garmin re-write as updated", async () => {
    const token = await signIn();
    const first = (await (await upload(token, { activities: [run(1, "2026-10-28"), run(2, "2026-10-29")] })).json()) as Json;
    expect(first.results.map((r: Json) => [r.externalId, r.status])).toEqual([["HK-1", "created"], ["HK-2", "created"]]);
    const again = await upload(token, {
      activities: [run(1, "2026-10-28"), run(3, "2026-10-29", { startedAt: "2026-10-29T07:00:40-04:00", sourceApp: "Garmin Connect" })],
    });
    expect(again.status).toBe(200);
    const body = (await again.json()) as Json;
    expect(body.results).toEqual([
      { externalId: "HK-1", status: "duplicate", activityId: first.results[0].activityId },
      { externalId: "HK-3", status: "updated", activityId: first.results[1].activityId },
    ]);
  });

  it("answers 400 with every invalid field", async () => {
    const token = await signIn();
    const res = await upload(token, { activities: [run(1, "2026-10-28", { durationSec: 0 }), run(2, "nope")] });
    expect(res.status).toBe(400);
    const problem = (await res.json()) as Json;
    expect(problem.errors.map((e: Json) => e.path).sort()).toEqual(["/activities/0/durationSec", "/activities/1/localDate", "/activities/1/startedAt"]);
  });

  it("answers 400 to a body that is not JSON and 413 to one over the limit", async () => {
    const token = await signIn();
    expect((await upload(token, "{nope")).status).toBe(400);
    expect((await upload(token, JSON.stringify({ activities: [run(1, "2026-10-28", { sourceApp: "x".repeat(300_000) })] }))).status).toBe(413);
  });
});

describe("GET /v1/activities", () => {
  let token: string;
  beforeEach(async () => {
    token = await signIn();
    await upload(token, { activities: [run(1, "2026-10-26"), run(2, "2026-10-27"), run(3, "2026-10-28")] });
  });

  it("lists newest first in the spec's Activity shape", async () => {
    const res = await list(token);
    expect(res.status).toBe(200);
    const body = (await res.json()) as Json;
    expect(body.activities.map((a: Json) => a.externalId)).toEqual(["HK-3", "HK-2", "HK-1"]);
    expect(Object.keys(body.activities[0]).sort()).toEqual(["disposition", "distanceM", "durationSec", "externalId", "id", "importedAt", "localDate", "source", "startedAt", "workoutType"]);
    expect(body.activities[0].disposition).toBe("inbox");
    expect(body.nextCursor).toBeUndefined();
  });

  it("works with a web token, which reads but cannot upload", async () => {
    const web = await signIn("runner@example.com", "web");
    expect((await list(web)).status).toBe(200);
  });

  it("filters by date and pages with a cursor", async () => {
    const ranged = (await (await list(token, "?from=2026-10-27&to=2026-10-27")).json()) as Json;
    expect(ranged.activities.map((a: Json) => a.externalId)).toEqual(["HK-2"]);
    const page1 = (await (await list(token, "?limit=2")).json()) as Json;
    expect(page1.activities).toHaveLength(2);
    const page2 = (await (await list(token, `?limit=2&cursor=${page1.nextCursor}`)).json()) as Json;
    expect(page2.activities.map((a: Json) => a.externalId)).toEqual(["HK-1"]);
    expect(page2.nextCursor).toBeUndefined();
  });

  it("keeps another user's activities out", async () => {
    const other = await signIn("other@example.com");
    expect(((await (await list(other)).json()) as Json).activities).toEqual([]);
  });

  it.each(["?from=2026-02-30", "?to=x", "?inbox=yes", "?limit=0", "?limit=201", "?cursor=@@"])("answers 400 to %s", async (query) => {
    expect((await list(token, query)).status).toBe(400);
  });

  it("accepts inbox=true", async () => {
    expect(((await (await list(token, "?inbox=true")).json()) as Json).activities).toHaveLength(3);
  });
});
