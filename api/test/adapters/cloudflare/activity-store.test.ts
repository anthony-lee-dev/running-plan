import { env } from "cloudflare:workers";
import { applyD1Migrations } from "cloudflare:test";
import { beforeAll } from "vitest";
import { D1ActivityStore } from "../../../src/adapters/cloudflare/d1-activity-store";
import { D1AuthStore } from "../../../src/adapters/cloudflare/d1-auth-store";
import { activityStoreContract } from "../../support/activity-store-contract";

beforeAll(async () => {
  await applyD1Migrations(env.DB, env.TEST_MIGRATIONS);
});

activityStoreContract("D1", async () => ({
  store: new D1ActivityStore(env.DB),
  auth: new D1AuthStore(env.DB),
  reset: async () => {
    await env.DB.prepare("DELETE FROM users").run();
  },
}));
