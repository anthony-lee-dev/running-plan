import { env } from "cloudflare:workers";
import { applyD1Migrations } from "cloudflare:test";
import { beforeAll } from "vitest";
import { D1AuthStore } from "../../../src/adapters/cloudflare/d1-auth-store";
import { D1CheckInStore } from "../../../src/adapters/cloudflare/d1-checkin-store";
import { D1PlanStore } from "../../../src/adapters/cloudflare/d1-plan-store";
import { D1SyncStore } from "../../../src/adapters/cloudflare/d1-sync-store";
import { syncStoreContract } from "../../support/sync-store-contract";

beforeAll(async () => {
  await applyD1Migrations(env.DB, env.TEST_MIGRATIONS);
});

syncStoreContract("D1", async () => ({
  store: new D1SyncStore(env.DB),
  plans: new D1PlanStore(env.DB),
  checkIns: new D1CheckInStore(env.DB),
  auth: new D1AuthStore(env.DB),
  reset: async () => {
    await env.DB.prepare("DELETE FROM users").run();
  },
}));
