import { beforeEach, describe, expect, it } from "vitest";
import type { StoredActivity } from "../../src/domain/activities";
import type { ActivityStore, AuthStore } from "../../src/ports";

const NOW = "2026-10-29T09:00:00.000Z";
const U1 = "00000000-0000-4000-8000-000000000001";
const U2 = "00000000-0000-4000-8000-000000000002";
const aid = (n: number) => `00000000-0000-4000-8000-${String(900 + n).padStart(12, "0")}`;

const activity = (n: number, localDate: string, over: Partial<StoredActivity> = {}): StoredActivity => ({
  id: aid(n),
  source: "apple_health",
  externalId: `HK-${n}`,
  workoutType: "running",
  startedAt: `${localDate}T07:00:00-04:00`,
  localDate,
  durationSec: 1800,
  distanceM: 5000,
  disposition: "inbox",
  importedAt: NOW,
  revision: 1,
  updatedAt: NOW,
  ...over,
});

/** Behaviour every ActivityStore must have; run against the in-memory store and the D1 store. */
export function activityStoreContract(name: string, make: () => Promise<{ store: ActivityStore; auth: AuthStore; reset: () => Promise<void> }>) {
  describe(`ActivityStore: ${name}`, () => {
    let store: ActivityStore;
    beforeEach(async () => {
      const made = await make();
      await made.reset();
      store = made.store;
      await made.auth.findOrCreateUser("a@example.com", U1, NOW);
      await made.auth.findOrCreateUser("b@example.com", U2, NOW);
    });

    it("stores created activities with every field and reads them back by date range", async () => {
      const full = activity(1, "2026-10-28", { sourceApp: "Garmin Connect", avgHeartRate: 150, maxHeartRate: 170, avgCadence: 172, elevationGainM: 30 });
      const bare = activity(2, "2026-10-30", { workoutType: "strength", distanceM: undefined });
      delete bare.distanceM;
      await store.applyImport(U1, [full, bare], []);
      expect(await store.candidates(U1, "2026-10-28", "2026-10-30", [])).toEqual(expect.arrayContaining([full, bare]));
      expect(await store.candidates(U1, "2026-10-29", "2026-10-29", [])).toEqual([]);
    });

    it("applies updates", async () => {
      await store.applyImport(U1, [activity(1, "2026-10-28")], []);
      const next = activity(1, "2026-10-28", { externalId: "HK-9", durationSec: 1810, revision: 2, updatedAt: "2026-10-29T10:00:00.000Z", disposition: "extra" });
      await store.applyImport(U1, [], [next]);
      expect(await store.candidates(U1, "2026-10-28", "2026-10-28", [])).toEqual([next]);
    });

    it("keeps users apart", async () => {
      await store.applyImport(U1, [activity(1, "2026-10-28")], []);
      expect(await store.candidates(U2, "2026-10-01", "2026-10-31", [{ source: "apple_health", externalId: "HK-1" }])).toEqual([]);
      expect(await store.list(U2, { limit: 10 })).toEqual([]);
      // Another user's id is never changed by an update (whether the store throws or skips it).
      await store.applyImport(U2, [], [activity(1, "2026-10-28", { durationSec: 9, revision: 2 })]).catch(() => undefined);
      expect((await store.candidates(U1, "2026-10-28", "2026-10-28", []))[0]!.durationSec).toBe(1800);
    });

    it("gets one activity by id, for its owner only", async () => {
      await store.applyImport(U1, [activity(1, "2026-10-28")], []);
      expect(await store.get(U1, aid(1))).toEqual(activity(1, "2026-10-28"));
      expect(await store.get(U2, aid(1))).toBeUndefined();
    });

    it("finds activities by source id whatever their date", async () => {
      await store.applyImport(U1, [activity(1, "2026-01-05"), activity(2, "2026-10-28")], []);
      const found = await store.candidates(U1, "2026-10-28", "2026-10-28", [{ source: "apple_health", externalId: "HK-1" }, { source: "manual", externalId: "HK-2" }]);
      expect(found.map((a) => a.id).sort()).toEqual([aid(1), aid(2)]);
    });

    it("fails the whole import rather than drop a write that clashes with a stored source id", async () => {
      await store.applyImport(U1, [activity(1, "2026-10-28")], []);
      await expect(store.applyImport(U1, [activity(5, "2026-10-29"), activity(2, "2026-10-28", { externalId: "HK-1" })], [])).rejects.toThrow();
      expect(await store.candidates(U1, "2026-10-29", "2026-10-29", [])).toEqual([]);
    });

    it("breaks ties on date and start by id", async () => {
      await store.applyImport(U1, [activity(1, "2026-10-28"), activity(2, "2026-10-28")], []);
      expect((await store.list(U1, { limit: 10 })).map((a) => a.id)).toEqual([aid(2), aid(1)]);
    });

    it("lists newest first, filters by date and inbox, and pages", async () => {
      await store.applyImport(U1, [
        activity(1, "2026-10-26"),
        activity(2, "2026-10-27"),
        activity(3, "2026-10-28", { disposition: "extra" }),
        activity(4, "2026-10-28", { startedAt: "2026-10-28T18:00:00-04:00" }),
      ], []);
      const ids = (list: StoredActivity[]) => list.map((a) => a.id);
      expect(ids(await store.list(U1, { limit: 10 }))).toEqual([aid(4), aid(3), aid(2), aid(1)]);
      expect(ids(await store.list(U1, { limit: 10, inbox: true }))).toEqual([aid(4), aid(2), aid(1)]);
      expect(ids(await store.list(U1, { limit: 10, from: "2026-10-27", to: "2026-10-28" }))).toEqual([aid(4), aid(3), aid(2)]);
      const first = await store.list(U1, { limit: 2 });
      const last = first.at(-1)!;
      expect(ids(await store.list(U1, { limit: 2, after: { localDate: last.localDate, startedAt: last.startedAt, id: last.id } }))).toEqual([aid(2), aid(1)]);
    });
  });
}
