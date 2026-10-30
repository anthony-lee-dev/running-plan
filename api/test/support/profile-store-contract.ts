import { beforeEach, describe, expect, it } from "vitest";
import { DEFAULT_PROFILE } from "../../src/domain/profile";
import type { AuthStore, ProfileStore } from "../../src/ports";

const NOW = "2026-10-29T09:00:00.000Z";
const LATER = "2026-10-29T10:00:00.000Z";
const U1 = "00000000-0000-4000-8000-000000000001";
const U2 = "00000000-0000-4000-8000-000000000002";

const fields = {
  targetDisplay: "heart_rate" as const,
  paces: { source: "manual" as const, easy: { minSecPerKm: 380, maxSecPerKm: 420 } },
  heartRate: { maxBpm: 188 },
  scheduling: { longRunDay: "sun" as const, unavailableDays: ["mon" as const, "tue" as const] },
  review: { frequency: "weekly" as const, day: "fri" as const },
};

/** Behaviour every ProfileStore must have; run against the in-memory store and the D1 store. */
export function profileStoreContract(
  name: string,
  make: () => Promise<{ store: ProfileStore; auth: AuthStore; reset: () => Promise<void> }>,
) {
  describe(`ProfileStore: ${name}`, () => {
    let store: ProfileStore;
    let auth: AuthStore;
    beforeEach(async () => {
      const made = await make();
      await made.reset();
      store = made.store;
      auth = made.auth;
      await auth.findOrCreateUser("a@example.com", U1, NOW);
      await auth.findOrCreateUser("b@example.com", U2, NOW);
    });

    it("has nothing stored until the first save", async () => {
      expect(await store.get(U1)).toBeUndefined();
    });

    it("creates the profile at revision 2 when saved against the default revision 1", async () => {
      const result = await store.save(U1, 1, fields, NOW);
      expect(result).toEqual({ ok: true, profile: { ...fields, revision: 2, updatedAt: NOW } });
      expect(await store.get(U1)).toEqual({ ...fields, revision: 2, updatedAt: NOW });
    });

    it("keeps JSON sections and optional fields intact, including absent ones", async () => {
      await store.save(U1, 1, { ...DEFAULT_PROFILE }, NOW);
      expect(await store.get(U1)).toEqual({ ...DEFAULT_PROFILE, revision: 2, updatedAt: NOW });
    });

    it("moves the revision by one on each save and rejects a stale base", async () => {
      await store.save(U1, 1, fields, NOW);
      expect(await store.save(U1, 2, { ...fields, targetDisplay: "effort" }, LATER)).toMatchObject({ ok: true, profile: { revision: 3, updatedAt: LATER } });
      expect(await store.save(U1, 2, fields, LATER)).toEqual({ ok: false, currentRevision: 3 });
      expect(await store.save(U1, 1, fields, LATER)).toEqual({ ok: false, currentRevision: 3 });
      expect((await store.get(U1))?.targetDisplay).toBe("effort");
    });

    it("reports the default revision when saving against a wrong base with nothing stored", async () => {
      expect(await store.save(U1, 4, fields, NOW)).toEqual({ ok: false, currentRevision: 1 });
      expect(await store.get(U1)).toBeUndefined();
    });

    it("lets only one of two racing saves win", async () => {
      const results = await Promise.all([store.save(U1, 1, fields, NOW), store.save(U1, 1, { ...fields, targetDisplay: "effort" }, NOW)]);
      expect(results.filter((r) => r.ok)).toHaveLength(1);
      expect(results.filter((r) => !r.ok)).toEqual([{ ok: false, currentRevision: 2 }]);
    });

    it("refuses to save for an account that no longer exists", async () => {
      await auth.deleteUser(U2);
      expect(await store.save(U2, 1, fields, NOW)).toEqual({ ok: false, currentRevision: 1 });
      expect(await store.get(U2)).toBeUndefined();
    });

    it("keeps each user's profile separate and removes it with the account", async () => {
      await store.save(U1, 1, fields, NOW);
      expect(await store.get(U2)).toBeUndefined();
      await auth.deleteUser(U1);
      expect(await store.get(U1)).toBeUndefined();
    });
  });
}
