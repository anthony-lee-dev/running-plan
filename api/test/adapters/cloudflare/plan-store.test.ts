import { env } from "cloudflare:workers";
import { applyD1Migrations } from "cloudflare:test";
import { beforeAll } from "vitest";
import { D1AuthStore } from "../../../src/adapters/cloudflare/d1-auth-store";
import { D1PlanStore } from "../../../src/adapters/cloudflare/d1-plan-store";
import { planStoreContract } from "../../support/plan-store-contract";

beforeAll(async () => {
  await applyD1Migrations(env.DB, env.TEST_MIGRATIONS);
});

planStoreContract("D1", async () => ({
  store: new D1PlanStore(env.DB),
  auth: new D1AuthStore(env.DB),
  reset: async () => {
    await env.DB.prepare("DELETE FROM users").run();
  },
}));
