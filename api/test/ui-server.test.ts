import { describe, expect, it } from "vitest";
import { buildUiTestServer } from "./ui-server/app";

const json = { "content-type": "application/json" };

describe("UI-test API server", () => {
  it("serves the real API and counts what it answered", async () => {
    const { app } = buildUiTestServer();
    const body = { answers: { goal: { distance: "10k" } }, today: "2026-11-02" };
    expect((await app.request("/v1/plans/generate", { method: "POST", headers: json, body: JSON.stringify(body) })).status).toBe(200);
    const stats = (await (await app.request("/__test/stats")).json()) as { requests: Record<string, number> };
    expect(stats.requests["POST /v1/plans/generate"]).toBe(1);
    // A failed generate does not count: verify.sh reads this to know a plan really came from here.
    await app.request("/v1/plans/generate", { method: "POST", headers: json, body: JSON.stringify({ ...body, extra: 1 }) });
    const after = (await (await app.request("/__test/stats")).json()) as { requests: Record<string, number> };
    expect(after.requests["POST /v1/plans/generate"]).toBe(1);
  });

  it("logs every request with its status and time, so a stalled or failed call shows in a CI failure", async () => {
    const lines: string[] = [];
    const { app } = buildUiTestServer({ log: (line) => lines.push(line) });
    await app.request("/v1/plans/generate", { method: "POST", headers: json, body: JSON.stringify({ answers: {}, today: "x" }) });
    await app.request("/__test/stats");
    // Each request logs when it arrives (so one that never answers still shows) and when it is answered.
    expect(lines).toHaveLength(4);
    expect(lines[0]).toMatch(/^\d{4}-\d\d-\d\dT[\d:.]+Z #1 > POST \/v1\/plans\/generate$/);
    expect(lines[1]).toMatch(/^\d{4}-\d\d-\d\dT[\d:.]+Z #1 < POST \/v1\/plans\/generate 4\d\d \d+ms$/);
    expect(lines[2]).toMatch(/ #2 > GET \/__test\/stats$/);
    expect(lines[3]).toMatch(/ #2 < GET \/__test\/stats 200 \d+ms$/);
  });

  it("gives a test the last sign-in code for an address, which signs in", async () => {
    const { app } = buildUiTestServer();
    expect((await app.request("/__test/codes/latest?email=runner@example.com")).status).toBe(404);
    await app.request("/v1/auth/email/start", { method: "POST", headers: json, body: JSON.stringify({ email: "runner@example.com" }) });
    const { code } = (await (await app.request("/__test/codes/latest?email=runner@example.com")).json()) as { code: string };
    const res = await app.request("/v1/auth/email/verify", {
      method: "POST",
      headers: json,
      body: JSON.stringify({ email: "runner@example.com", code, clientType: "ios" }),
    });
    expect(res.status).toBe(200);
  });

  it("seeds a signed-in account with a saved plan, so a UI test can skip the interview and sign-in", async () => {
    const { app } = buildUiTestServer();
    const res = await app.request("/__test/seed", { method: "POST", headers: json, body: JSON.stringify({ email: "seed@example.com", today: "2026-11-02" }) });
    expect(res.status).toBe(200);
    const seed = (await res.json()) as { accessToken: string; refreshToken: string; userId: string; planId: string };
    const plans = await app.request("/v1/plans", { headers: { authorization: `Bearer ${seed.accessToken}` } });
    expect(plans.status).toBe(200);
    const list = (await plans.json()) as { plans: { id: string }[] };
    expect(list.plans.map((p) => p.id)).toEqual([seed.planId]);
    // The refresh token works too.
    const refreshed = await app.request("/v1/auth/refresh", { method: "POST", headers: json, body: JSON.stringify({ refreshToken: seed.refreshToken }) });
    expect(refreshed.status).toBe(200);
  });

  it("refuses a seed request without a valid body", async () => {
    const { app } = buildUiTestServer();
    expect((await app.request("/__test/seed", { method: "POST", headers: json, body: "{}" })).status).toBe(400);
  });
});
