import { env } from "cloudflare:workers";
import { applyD1Migrations } from "cloudflare:test";
import { beforeAll } from "vitest";
import { D1AuthStore } from "../../../src/adapters/cloudflare/d1-auth-store";
import { D1RateLimiter } from "../../../src/adapters/cloudflare/d1-rate-limiter";
import { authStoreContract, rateLimiterContract } from "../../support/auth-store-contract";

beforeAll(async () => {
  await applyD1Migrations(env.DB, env.TEST_MIGRATIONS);
});

authStoreContract("D1", async () => ({
  store: new D1AuthStore(env.DB),
  reset: async () => {
    await env.DB.batch([env.DB.prepare("DELETE FROM users"), env.DB.prepare("DELETE FROM email_codes")]);
  },
}));
rateLimiterContract("D1", async () => ({
  limiter: new D1RateLimiter(env.DB),
  reset: async () => {
    await env.DB.prepare("DELETE FROM rate_limits").run();
  },
}));
