import { describe, expect, it } from "vitest";
import { createApp } from "../src/app";
import { FixedClock, memoryDeps } from "../src/adapters/memory";

describe("GET /v1/health", () => {
  it("reports ok when storage answers", async () => {
    const at = new Date("2026-10-28T12:00:00Z");
    const app = createApp(memoryDeps({ clock: new FixedClock(at) }));
    const res = await app.request("/v1/health");
    expect(res.status).toBe(200);
    expect(await res.json()).toEqual({ status: "ok", storage: true, time: at.toISOString() });
  });

  it("reports degraded with 503 when storage is down", async () => {
    const app = createApp(memoryDeps({ health: { check: async () => false } }));
    const res = await app.request("/v1/health");
    expect(res.status).toBe(503);
  });

  it("returns a JSON 404 for unknown routes", async () => {
    const res = await createApp(memoryDeps()).request("/nope");
    expect(res.status).toBe(404);
    expect(await res.json()).toEqual({ error: "not_found" });
  });
});
