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
});
