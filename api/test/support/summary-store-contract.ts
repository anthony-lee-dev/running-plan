import { beforeEach, describe, expect, it } from "vitest";
import type { StoredActivity } from "../../src/domain/activities";
import type { ActivityStore, AuthStore, StoredSummary, SummaryStore } from "../../src/ports";

const NOW = "2026-11-10T09:00:00.000Z";
const U1 = "00000000-0000-4000-8000-000000000001";
const U2 = "00000000-0000-4000-8000-000000000002";
const A1 = "00000000-0000-4000-8000-000000000901";
const activity = (over: Partial<StoredActivity> = {}): StoredActivity => ({
  id: A1, source: "apple_health", externalId: "HK-1", workoutType: "running", startedAt: "2026-11-09T07:00:00-05:00", localDate: "2026-11-09",
  durationSec: 1800, distanceM: 5000, disposition: "inbox", importedAt: NOW, revision: 1, updatedAt: NOW, ...over,
});
const summary = (over: Partial<StoredSummary> = {}): StoredSummary => ({ activityId: A1, factsHash: "h1", promptVersion: "v1", model: "m", source: "ai", text: "Five km in 30 min.", createdAt: NOW, ...over });

type Made = { store: SummaryStore; activities: ActivityStore; auth: AuthStore; reset: () => Promise<void> };

/** Behaviour every SummaryStore must have; run against the in-memory store and the D1 store. */
export function summaryStoreContract(name: string, make: () => Promise<Made>) {
  describe(`SummaryStore: ${name}`, () => {
    let m: Made;
    beforeEach(async () => {
      m = await make();
      await m.reset();
      await m.auth.findOrCreateUser("a@example.com", U1, NOW);
      await m.auth.findOrCreateUser("b@example.com", U2, NOW);
      await m.activities.applyImport(U1, [activity()], []);
    });

    it("has nothing until one is put", async () => {
      expect(await m.store.get(U1, A1)).toBeUndefined();
    });

    it("stores and reads back a summary, and replaces it", async () => {
      await m.store.put(U1, summary());
      expect(await m.store.get(U1, A1)).toEqual(summary());
      const next = summary({ factsHash: "h2", source: "template", reason: "check_failed", text: "Template text.", createdAt: "2026-11-10T10:00:00.000Z" });
      await m.store.put(U1, next);
      expect(await m.store.get(U1, A1)).toEqual(next);
    });

    it("is the user's alone: another user reads and writes nothing", async () => {
      await m.store.put(U1, summary());
      expect(await m.store.get(U2, A1)).toBeUndefined();
      await m.store.put(U2, summary({ text: "Not mine." }));
      expect((await m.store.get(U1, A1))?.text).toBe("Five km in 30 min.");
    });

    it("writes nothing for an activity that does not exist", async () => {
      const ghost = "00000000-0000-4000-8000-000000000999";
      await m.store.put(U1, summary({ activityId: ghost }));
      expect(await m.store.get(U1, ghost)).toBeUndefined();
    });
  });
}
