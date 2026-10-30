import { env } from "cloudflare:workers";
import { applyD1Migrations } from "cloudflare:test";
import { beforeAll } from "vitest";
import { D1ActivityStore } from "../../../src/adapters/cloudflare/d1-activity-store";
import { D1AuthStore } from "../../../src/adapters/cloudflare/d1-auth-store";
import { D1MatchStore } from "../../../src/adapters/cloudflare/d1-match-store";
import { D1PlanStore } from "../../../src/adapters/cloudflare/d1-plan-store";
import { matchStoreContract } from "../../support/match-store-contract";

beforeAll(async () => {
  await applyD1Migrations(env.DB, env.TEST_MIGRATIONS);
});

matchStoreContract("D1", async () => ({
  store: new D1MatchStore(env.DB),
  plans: new D1PlanStore(env.DB),
  activities: new D1ActivityStore(env.DB),
  auth: new D1AuthStore(env.DB),
  reset: async () => {
    await env.DB.prepare("DELETE FROM users").run();
  },
}));
