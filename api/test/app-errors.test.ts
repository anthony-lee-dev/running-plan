import { describe, expect, it, vi } from "vitest";
import { createApp } from "../src/app";
import { memoryDeps } from "../src/adapters/memory";

describe("unhandled errors", () => {
  it("answers 500 and logs the error name and message so a failure shows up in the Workers logs", async () => {
    const log = vi.spyOn(console, "error").mockImplementation(() => {});
    const email = { sendCode: async () => Promise.reject(new Error("Cloudflare Email Sending refused the email (E_TEST)")) };
    const app = createApp(memoryDeps({ email, authConfig: { jwtSecret: "x".repeat(32) } }));
    const res = await app.request("/v1/auth/email/start", {
      method: "POST",
      body: JSON.stringify({ email: "runner@example.com" }),
      headers: { "content-type": "application/json" },
    });
    expect(res.status).toBe(500);
    expect(JSON.stringify(log.mock.calls)).toContain("E_TEST");
    expect(JSON.stringify(log.mock.calls)).not.toContain("runner@example.com");
    log.mockRestore();
  });
});
