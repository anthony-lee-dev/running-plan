import { beforeEach, describe, expect, it } from "vitest";
import type { AuthStore, RateLimiter, RefreshRecord } from "../../src/ports";

const NOW = "2026-10-29T09:00:00.000Z";
const LATER = "2026-10-29T09:10:00.000Z";
const U1 = "00000000-0000-4000-8000-000000000001";
const U2 = "00000000-0000-4000-8000-000000000002";

export function refreshRecord(over: Partial<RefreshRecord> = {}): RefreshRecord {
  return {
    id: "00000000-0000-4000-8000-0000000000f1",
    userId: U1,
    familyId: "00000000-0000-4000-8000-0000000000e1",
    tokenHash: "hash-1",
    clientType: "ios",
    scopes: ["app", "activities:write"],
    createdAt: NOW,
    expiresAt: "2026-12-29T09:00:00.000Z",
    rotatedAt: null,
    revokedAt: null,
    ...over,
  };
}

/** Behaviour every AuthStore must have; run against the in-memory store and the D1 store. */
export function authStoreContract(name: string, make: () => Promise<{ store: AuthStore; reset: () => Promise<void> }>) {
  describe(`AuthStore: ${name}`, () => {
    let store: AuthStore;
    beforeEach(async () => {
      const made = await make();
      await made.reset();
      store = made.store;
    });

    it("creates a user once per email and then finds it", async () => {
      const first = await store.findOrCreateUser("a@example.com", U1, NOW);
      expect(first).toMatchObject({ created: true, user: { id: U1, email: "a@example.com" } });
      const again = await store.findOrCreateUser("a@example.com", U2, LATER);
      expect(again).toMatchObject({ created: false, user: { id: U1 } });
      expect(await store.userExists(U1)).toBe(true);
      expect(await store.userExists(U2)).toBe(false);
    });

    it("keeps one code per email, replacing the old one and resetting attempts", async () => {
      await store.saveCode("a@example.com", "h1", LATER, NOW);
      expect(await store.useCodeAttempt("a@example.com", 5)).toBe(true);
      expect(await store.useCodeAttempt("a@example.com", 5)).toBe(true);
      await store.saveCode("a@example.com", "h2", LATER, NOW);
      expect(await store.getCode("a@example.com")).toEqual({ codeHash: "h2", expiresAt: LATER, attempts: 0 });
      expect(await store.deleteCode("a@example.com")).toBe(true);
      expect(await store.deleteCode("a@example.com")).toBe(false); // single use, even when two requests race
      expect(await store.getCode("a@example.com")).toBeUndefined();
    });

    it("allows exactly the maximum number of attempts, even when they race", async () => {
      await store.saveCode("a@example.com", "h1", LATER, NOW);
      const results = await Promise.all(Array.from({ length: 12 }, () => store.useCodeAttempt("a@example.com", 5)));
      expect(results.filter(Boolean)).toHaveLength(5);
      expect(await store.useCodeAttempt("a@example.com", 5)).toBe(false);
      expect(await store.useCodeAttempt("nobody@example.com", 5)).toBe(false);
    });

    it("stores and finds a refresh token by hash", async () => {
      await store.findOrCreateUser("a@example.com", U1, NOW);
      await store.saveRefresh(refreshRecord());
      expect(await store.findRefresh("hash-1")).toEqual(refreshRecord());
      expect(await store.findRefresh("nope")).toBeUndefined();
    });

    it("rotates a refresh token only once", async () => {
      await store.findOrCreateUser("a@example.com", U1, NOW);
      await store.saveRefresh(refreshRecord());
      expect(await store.markRefreshRotated(refreshRecord().id, LATER)).toBe(true);
      expect(await store.markRefreshRotated(refreshRecord().id, LATER)).toBe(false);
      expect((await store.findRefresh("hash-1"))?.rotatedAt).toBe(LATER);
    });

    it("revokes a whole family and nothing else", async () => {
      await store.findOrCreateUser("a@example.com", U1, NOW);
      await store.saveRefresh(refreshRecord());
      await store.saveRefresh(refreshRecord({ id: "00000000-0000-4000-8000-0000000000f2", tokenHash: "hash-2" }));
      await store.saveRefresh(
        refreshRecord({ id: "00000000-0000-4000-8000-0000000000f3", tokenHash: "hash-3", familyId: "other-family" }),
      );
      await store.revokeFamily(refreshRecord().familyId, LATER);
      expect((await store.findRefresh("hash-1"))?.revokedAt).toBe(LATER);
      expect((await store.findRefresh("hash-2"))?.revokedAt).toBe(LATER);
      expect((await store.findRefresh("hash-3"))?.revokedAt).toBeNull();
      expect(await store.markRefreshRotated(refreshRecord().id, LATER)).toBe(false);
    });

    it("deleting a user removes the user and its refresh tokens", async () => {
      await store.findOrCreateUser("a@example.com", U1, NOW);
      await store.saveRefresh(refreshRecord());
      await store.deleteUser(U1);
      expect(await store.userExists(U1)).toBe(false);
      expect(await store.findRefresh("hash-1")).toBeUndefined();
    });
  });
}

/** Behaviour every RateLimiter must have. */
export function rateLimiterContract(name: string, make: () => Promise<{ limiter: RateLimiter; reset: () => Promise<void> }>) {
  describe(`RateLimiter: ${name}`, () => {
    let limiter: RateLimiter;
    beforeEach(async () => {
      const made = await make();
      await made.reset();
      limiter = made.limiter;
    });
    const at = (s: number) => new Date(Date.UTC(2026, 9, 29, 9, 0, s));

    it("allows up to the limit in a window, then says how long to wait", async () => {
      for (let i = 0; i < 3; i++) expect((await limiter.hit("k", 3, 60, at(i))).allowed).toBe(true);
      const blocked = await limiter.hit("k", 3, 60, at(10));
      expect(blocked.allowed).toBe(false);
      expect(blocked.retryAfterSec).toBeGreaterThan(0);
      expect(blocked.retryAfterSec).toBeLessThanOrEqual(60);
    });

    it("counts keys separately and starts a new window later", async () => {
      for (let i = 0; i < 3; i++) await limiter.hit("a", 3, 60, at(i));
      expect((await limiter.hit("b", 3, 60, at(5))).allowed).toBe(true);
      expect((await limiter.hit("a", 3, 60, at(5))).allowed).toBe(false);
      expect((await limiter.hit("a", 3, 60, at(0 + 61))).allowed).toBe(true);
    });
  });
}
