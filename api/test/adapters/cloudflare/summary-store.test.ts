import { env } from "cloudflare:workers";
import { applyD1Migrations } from "cloudflare:test";
import { beforeAll, expect, it } from "vitest";
import { D1ActivityStore } from "../../../src/adapters/cloudflare/d1-activity-store";
import { D1AuthStore } from "../../../src/adapters/cloudflare/d1-auth-store";
import { D1SummaryStore } from "../../../src/adapters/cloudflare/d1-summary-store";
import { summaryStoreContract } from "../../support/summary-store-contract";

beforeAll(async () => {
  await applyD1Migrations(env.DB, env.TEST_MIGRATIONS);
});

summaryStoreContract("D1", async () => ({
  store: new D1SummaryStore(env.DB),
  activities: new D1ActivityStore(env.DB),
  auth: new D1AuthStore(env.DB),
  reset: async () => {
    await env.DB.prepare("DELETE FROM users").run();
  },
}));

it("D1: a summary goes with its user", async () => {
  const auth = new D1AuthStore(env.DB);
  await env.DB.prepare("DELETE FROM users").run();
  await auth.findOrCreateUser("z@example.com", "00000000-0000-4000-8000-0000000000aa", "2026-11-10T09:00:00.000Z");
  await new D1ActivityStore(env.DB).applyImport("00000000-0000-4000-8000-0000000000aa", [{ id: "00000000-0000-4000-8000-0000000000ab", source: "manual", externalId: "x", workoutType: "running", startedAt: "2026-11-09T07:00:00Z", localDate: "2026-11-09", durationSec: 60, disposition: "inbox", importedAt: "2026-11-10T09:00:00.000Z", revision: 1, updatedAt: "2026-11-10T09:00:00.000Z" }], []);
  const store = new D1SummaryStore(env.DB);
  await store.put("00000000-0000-4000-8000-0000000000aa", { activityId: "00000000-0000-4000-8000-0000000000ab", factsHash: "h", promptVersion: "v", model: "m", source: "ai", text: "t", createdAt: "2026-11-10T09:00:00.000Z" });
  await auth.deleteUser("00000000-0000-4000-8000-0000000000aa");
  const left = await env.DB.prepare("SELECT COUNT(*) AS n FROM activity_summaries").first<{ n: number }>();
  expect(left?.n).toBe(0);
});
