import { env } from "cloudflare:workers";
import { applyD1Migrations } from "cloudflare:test";
import { beforeAll } from "vitest";
import { D1ActivityStore } from "../../../src/adapters/cloudflare/d1-activity-store";
import { D1AuthStore } from "../../../src/adapters/cloudflare/d1-auth-store";
import { D1CheckInStore } from "../../../src/adapters/cloudflare/d1-checkin-store";
import { D1MatchStore } from "../../../src/adapters/cloudflare/d1-match-store";
import { D1PlanStore } from "../../../src/adapters/cloudflare/d1-plan-store";
import { D1ProposalStore } from "../../../src/adapters/cloudflare/d1-proposal-store";
import { proposalStoreContract } from "../../support/proposal-store-contract";

beforeAll(async () => {
  await applyD1Migrations(env.DB, env.TEST_MIGRATIONS);
});

proposalStoreContract("D1", async () => ({
  store: new D1ProposalStore(env.DB),
  plans: new D1PlanStore(env.DB),
  checkIns: new D1CheckInStore(env.DB),
  matches: new D1MatchStore(env.DB),
  activities: new D1ActivityStore(env.DB),
  auth: new D1AuthStore(env.DB),
  reset: async () => {
    await env.DB.prepare("DELETE FROM users").run();
  },
}));
