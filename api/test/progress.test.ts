import { beforeEach, describe, expect, it } from "vitest";
import { createApp } from "../src/app";
import { MemoryEmailSender, memoryDeps } from "../src/adapters/memory";

const SECRET = "test-secret-test-secret-test-secret";
type Json = Record<string, any>; // eslint-disable-line @typescript-eslint/no-explicit-any
const id = (n: number) => `00000000-0000-4000-8000-${String(n).padStart(12, "0")}`;
const P = id(101);
const S1 = id(201);
const S2 = id(202);
const S3 = id(203);

let app: ReturnType<typeof createApp>;
let email: MemoryEmailSender;
let token: string;

async function signIn(address = "runner@example.com"): Promise<string> {
  const headers = { "content-type": "application/json" };
  await app.request("/v1/auth/email/start", { method: "POST", body: JSON.stringify({ email: address }), headers });
  const res = await app.request("/v1/auth/email/verify", { method: "POST", body: JSON.stringify({ email: address, code: email.sent.at(-1)!.code, clientType: "ios" }), headers });
  return ((await res.json()) as { accessToken: string }).accessToken;
}
const call = (method: string, path: string, body?: unknown, as: string | undefined = token, anonymous = false) =>
  app.request(path, {
    method,
    headers: { ...(!anonymous && as ? { authorization: `Bearer ${as}` } : {}), ...(body !== undefined ? { "content-type": "application/json" } : {}) },
    ...(body !== undefined ? { body: JSON.stringify(body) } : {}),
  });
const easy = (sid: string, date: string, key = false) => ({ id: sid, date, type: "easy", key, steps: [{ kind: "work", goal: { type: "distance", value: 5000 }, target: { type: "effort", effort: "easy" } }] });
const progress = (today = "2026-10-31", planId = P, as: string | null = token) => call("GET", `/v1/plans/${planId}/progress?today=${today}`, undefined, as ?? undefined, as === null);
const upload = async (n: number) => {
  const act = { source: "apple_health", externalId: `HK-${n}`, workoutType: "running", startedAt: "2026-10-28T07:00:00-04:00", localDate: "2026-10-28", durationSec: 2400, distanceM: 6200 };
  const up = (await (await call("POST", "/v1/activities:batch", { activities: [act] })).json()) as Json;
  return up.results[0].activityId as string;
};

beforeEach(async () => {
  email = new MemoryEmailSender();
  app = createApp(memoryDeps({ email, authConfig: { jwtSecret: SECRET } }));
  token = await signIn();
  await call("POST", "/v1/plans", {
    id: P, goal: { type: "5k", date: "2026-12-20" }, startDate: "2026-10-26", weekCount: 8, source: "blank", adaptive: false, weeks: [],
    sessions: [easy(S1, "2026-10-28", true), easy(S2, "2026-10-29"), easy(S3, "2026-10-30")],
  });
});

describe("GET /v1/plans/{id}/progress", () => {
  it("counts a confirmed run at the activity's numbers and the rest as missed", async () => {
    await call("PUT", `/v1/sessions/${S1}/match`, { activityId: await upload(1), status: "confirmed" });
    const res = await progress("2026-10-31");
    expect(res.status).toBe(200);
    const body = (await res.json()) as Json;
    expect(body).toMatchObject({
      planId: P,
      asOf: "2026-10-31",
      adherence: { due: 3, done: 1, skipped: 0, missed: 2 },
      keySessions: { planned: 1, completed: 1 },
      strengthSessions: { planned: 0, completed: 0 },
      goal: { date: "2026-12-20", daysToGo: 50, onTrack: "behind" },
    });
    expect(body.weeks).toHaveLength(8);
    expect(body.weeks[0]).toMatchObject({ index: 0, plannedDistanceM: 15000, actualDistanceM: 6200, actualTimeSec: 2400 });
  });

  it("ignores a suggested match", async () => {
    await call("PUT", `/v1/sessions/${S1}/match`, { activityId: await upload(2), status: "suggested" });
    expect(((await (await progress()).json()) as Json).adherence.done).toBe(0);
  });

  it("answers 401 without a token, 404 for an unknown or another user's plan, 400 for a bad date", async () => {
    expect((await progress("2026-10-31", P, null)).status).toBe(401);
    expect((await progress("2026-10-31", id(999))).status).toBe(404);
    expect((await progress("2026-10-31", "nope")).status).toBe(404);
    expect((await progress("2026-10-31", P, await signIn("other@example.com"))).status).toBe(404);
    expect((await progress("2026-02-30")).status).toBe(400);
    expect((await call("GET", `/v1/plans/${P}/progress`)).status).toBe(400);
  });
});
