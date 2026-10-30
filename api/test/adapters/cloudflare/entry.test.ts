import { env } from "cloudflare:workers";
import { applyD1Migrations } from "cloudflare:test";
import { beforeAll, describe, expect, it } from "vitest";
import worker, { type Env } from "../../../src/index";

const ctx = { waitUntil() {}, passThroughOnException() {} } as unknown as ExecutionContext;
const fakeEmail = { send: async () => ({}) };
const SECRET = "worker-test-secret-worker-test-secret";

beforeAll(async () => {
  await applyD1Migrations(env.DB, env.TEST_MIGRATIONS);
});

const call = (overrides: Partial<Env>, path = "/v1/auth/email/start", body: unknown = { email: "runner@example.com" }) =>
  worker.fetch(
    new Request(`http://localhost${path}`, { method: "POST", body: JSON.stringify(body), headers: { "content-type": "application/json" } }),
    { DB: env.DB, ...overrides },
    ctx,
  );

describe("Workers entry configuration", () => {
  it("refuses to run without a signing secret, or with a short one", async () => {
    for (const JWT_SECRET of [undefined, "", "too-short"]) {
      const res = await call({ JWT_SECRET, EMAIL: fakeEmail, MAIL_FROM: "a@example.com" });
      expect(res.status).toBe(500);
      expect((await res.json()) as { type: string }).toMatchObject({ type: "misconfigured" });
    }
  });

  it("refuses to run without email configured, so codes are never logged by accident", async () => {
    expect((await call({ JWT_SECRET: SECRET })).status).toBe(500);
    expect((await call({ JWT_SECRET: SECRET, EMAIL: fakeEmail })).status).toBe(500);
    expect((await call({ JWT_SECRET: SECRET, ALLOW_LOG_EMAIL: "yes" })).status).toBe(500);
  });

  it("runs with the explicit local-dev opt-in, which only logs the code", async () => {
    const res = await call({ JWT_SECRET: SECRET, ALLOW_LOG_EMAIL: "1" });
    expect(res.status).toBe(202);
  });

  it("serves the health check once configured", async () => {
    const res = await worker.fetch(new Request("http://localhost/v1/health"), { DB: env.DB, JWT_SECRET: SECRET, ALLOW_LOG_EMAIL: "1" }, ctx);
    expect(res.status).toBe(200);
  });
});
