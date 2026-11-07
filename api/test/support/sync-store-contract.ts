import { beforeEach, describe, expect, it } from "vitest";
import type { StoredProposal } from "../../src/domain/proposal-model";
import type { AuthStore, CheckInStore, PlanStore, ProposalStore, StoredPlan, StoredSession, SyncStore } from "../../src/ports";

const T = (n: number) => `2026-10-29T09:00:${String(n).padStart(2, "0")}.000Z`;
const id = (n: number) => `00000000-0000-4000-8000-${String(n).padStart(12, "0")}`;
const U1 = id(1);
const U2 = id(2);
const LIMITS = { plans: 10, sessions: 10, checkins: 10, proposals: 10 };

const plan = (n: number, at: string, over: Partial<StoredPlan> = {}): StoredPlan => ({
  id: id(100 + n), goal: { type: "5k" }, startDate: "2026-10-26", weekCount: 8, source: "blank", adaptive: false,
  weeks: [{ index: 0, phase: "base", notes: "go easy" }], revision: 1, contentRevision: 1, updatedAt: at, deletedAt: null, ...over,
});
const session = (n: number, planId: string, at: string): StoredSession => ({
  id: id(200 + n), planId, date: "2026-10-28", type: "easy", key: false, status: "planned", owner: "system",
  steps: [{ kind: "work", goal: { type: "distance", value: 5000 }, target: { type: "effort", effort: "easy" } }], revision: 1, updatedAt: at, deletedAt: null,
});

type Made = { store: SyncStore; plans: PlanStore; checkIns: CheckInStore; proposals: ProposalStore; auth: AuthStore; reset: () => Promise<void> };

/** Behaviour every SyncStore must have; run against the in-memory store and the D1 store. */
export function syncStoreContract(name: string, make: () => Promise<Made>) {
  describe(`SyncStore: ${name}`, () => {
    let m: Made;
    beforeEach(async () => {
      m = await make();
      await m.reset();
      await m.auth.findOrCreateUser("a@example.com", U1, T(0));
      await m.auth.findOrCreateUser("b@example.com", U2, T(0));
    });

    it("remembers applied operations per user and keeps the first record of a key", async () => {
      await m.store.recordOps(U1, [{ idempotencyKey: id(900), opHash: "h1", revision: 2 }, { idempotencyKey: id(901), opHash: "h2", revision: 1 }], T(1));
      await m.store.recordOps(U1, [{ idempotencyKey: id(900), opHash: "other", revision: 9 }], T(2));
      const found = await m.store.findOps(U1, [id(900), id(901), id(902)]);
      expect(found.sort((a, b) => (a.idempotencyKey < b.idempotencyKey ? -1 : 1))).toEqual([
        { idempotencyKey: id(900), opHash: "h1", revision: 2 },
        { idempotencyKey: id(901), opHash: "h2", revision: 1 },
      ]);
      expect(await m.store.findOps(U2, [id(900)])).toEqual([]);
      await m.store.recordOps(U1, [], T(3));
    });

    it("pulls plans with their weeks, sessions and check-ins, tombstones included, only the user's own", async () => {
      await m.plans.createPlan(U1, plan(1, T(1)), [session(1, id(101), T(1)), session(2, id(101), T(1))], "h");
      await m.plans.createPlan(U2, plan(2, T(1)), [session(3, id(102), T(1))], "h");
      await m.checkIns.create(U1, { id: id(300), sessionId: id(201), when: "after", feel: 4, pain: false, revision: 1, updatedAt: T(2), deletedAt: null });
      await m.plans.deleteSession(U1, id(202), 1, T(3));
      const got = await m.store.changesSince(U1, {}, LIMITS);
      expect(got.plans.map((p) => [p.id, p.weeks])).toEqual([[id(101), [{ index: 0, phase: "base", notes: "go easy" }]]]);
      expect(got.sessions.map((s) => [s.id, s.revision, s.deletedAt])).toEqual([[id(201), 1, null], [id(202), 2, T(3)]]);
      expect(got.checkins.map((c) => c.id)).toEqual([id(300)]);
      expect(got.hasMore).toBe(false);
      // The cursor it returns leaves nothing new; a later change shows up alone.
      expect(await m.store.changesSince(U1, got.cursor, LIMITS)).toMatchObject({ plans: [], sessions: [], checkins: [], hasMore: false });
      await m.plans.writeSession(U1, id(201), 1, { ...session(1, id(101), T(4)), status: "done" }, T(4));
      const later = await m.store.changesSince(U1, got.cursor, LIMITS);
      expect(later.sessions.map((s) => [s.id, s.status, s.revision])).toEqual([[id(201), "done", 2]]);
      // The session write moved the plan's contentRevision, so the plan is pulled again with the new number.
      expect(later.plans.map((p) => [p.id, p.contentRevision])).toEqual([[id(101), 3]]);
    });

    it("pages rows that share one update time without losing or repeating any", async () => {
      const sessions = Array.from({ length: 7 }, (_, i) => session(i + 1, id(101), T(1)));
      await m.plans.createPlan(U1, plan(1, T(1)), sessions, "h");
      const seen: string[] = [];
      let cursor = {};
      let pages = 0;
      for (;;) {
        const got = await m.store.changesSince(U1, cursor, { plans: 1, sessions: 3, checkins: 1, proposals: 1 });
        seen.push(...got.sessions.map((s) => s.id));
        cursor = got.cursor;
        pages += 1;
        if (!got.hasMore) break;
      }
      expect(pages).toBe(3);
      expect(seen).toEqual(sessions.map((s) => s.id));
    });

    it("pulls proposals as stored, with a stale and a deleted one, paged on their own position", async () => {
      await m.plans.createPlan(U1, plan(1, T(1)), [session(1, id(101), T(1))], "h");
      await m.plans.createPlan(U2, plan(2, T(1)), [session(3, id(102), T(1))], "h");
      const made = (n: number, planId: string, at: string): StoredProposal => ({
        id: id(400 + n), planId, baseContentRevision: 1, kind: "adjustment", creator: { type: "rules", version: "0.1.0" }, reason: "Because.", urgent: true,
        changes: [], status: "pending", createdAt: at, updatedAt: at, deletedAt: null, resolvedAt: null, revision: 1, key: `k${n}`,
      });
      await m.proposals.create(U1, [made(1, id(101), T(2)), made(2, id(101), T(2))]);
      await m.proposals.create(U2, [made(3, id(102), T(2))]);
      const first = await m.store.changesSince(U1, {}, { ...LIMITS, proposals: 1 });
      expect(first.proposals.map((p) => p.id)).toEqual([id(401)]);
      expect(first.hasMore).toBe(true);
      const second = await m.store.changesSince(U1, first.cursor, LIMITS);
      expect(second.proposals.map((p) => p.id)).toEqual([id(402)]);
      expect(second.hasMore).toBe(false);
      // Going stale, then a deleted plan, each move the row so the next pull carries it.
      await m.plans.writeSession(U1, id(201), 1, { ...session(1, id(101), T(4)), status: "done" }, T(4));
      await m.proposals.markStale(U1, T(5));
      const stale = await m.store.changesSince(U1, second.cursor, LIMITS);
      expect(stale.proposals.map((p) => [p.id, p.status, p.updatedAt])).toEqual([[id(401), "stale", T(5)], [id(402), "stale", T(5)]]);
      await m.plans.deletePlan(U1, id(101), 1, T(6));
      const gone = await m.store.changesSince(U1, stale.cursor, LIMITS);
      expect(gone.proposals.map((p) => [p.id, p.deletedAt])).toEqual([[id(401), T(6)], [id(402), T(6)]]);
    });
  });
}
