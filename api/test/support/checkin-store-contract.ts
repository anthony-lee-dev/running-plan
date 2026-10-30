import { beforeEach, describe, expect, it } from "vitest";
import type { AuthStore, CheckInStore, PlanStore, StoredCheckIn, StoredPlan, StoredSession } from "../../src/ports";

const NOW = "2026-10-29T09:00:00.000Z";
const U1 = "00000000-0000-4000-8000-000000000001";
const U2 = "00000000-0000-4000-8000-000000000002";
const P1 = "00000000-0000-4000-8000-000000000101";
const S1 = "00000000-0000-4000-8000-000000000201";
const C1 = "00000000-0000-4000-8000-000000000301";

const plan: StoredPlan = { id: P1, goal: { type: "5k" }, startDate: "2026-10-26", weekCount: 8, source: "blank", adaptive: false, weeks: [], revision: 1, contentRevision: 1, updatedAt: NOW, deletedAt: null };
const session: StoredSession = {
  id: S1, planId: P1, date: "2026-10-28", type: "easy", key: false, status: "planned", owner: "system",
  steps: [{ kind: "work", goal: { type: "distance", value: 5000 }, target: { type: "effort", effort: "easy" } }], revision: 1, updatedAt: NOW, deletedAt: null,
};
const checkIn = (over: Partial<StoredCheckIn> = {}): StoredCheckIn => ({ id: C1, sessionId: S1, when: "after", feel: 4, effortFelt: 6, pain: false, note: "ok", revision: 1, updatedAt: NOW, deletedAt: null, ...over });

type Made = { store: CheckInStore; plans: PlanStore; auth: AuthStore; reset: () => Promise<void> };

/** Behaviour every CheckInStore must have; run against the in-memory store and the D1 store. */
export function checkInStoreContract(name: string, make: () => Promise<Made>) {
  describe(`CheckInStore: ${name}`, () => {
    let m: Made;
    beforeEach(async () => {
      m = await make();
      await m.reset();
      await m.auth.findOrCreateUser("a@example.com", U1, NOW);
      await m.auth.findOrCreateUser("b@example.com", U2, NOW);
      await m.plans.createPlan(U1, plan, [session], "h");
    });

    it("creates a check-in on a live session of the user", async () => {
      expect(await m.store.create(U1, checkIn())).toEqual({ status: "created", checkIn: checkIn() });
    });

    it("stores a check-in without the optional fields", async () => {
      const bare = checkIn({ effortFelt: undefined, note: undefined, when: "before" });
      delete bare.effortFelt;
      delete bare.note;
      expect(await m.store.create(U1, bare)).toEqual({ status: "created", checkIn: bare });
    });

    it("reports an existing id with what is stored, and whose it is", async () => {
      await m.store.create(U1, checkIn());
      expect(await m.store.create(U1, checkIn({ feel: 1 }))).toEqual({ status: "exists", mine: true, checkIn: checkIn() });
      // Another user with a session of their own who reuses the id.
      const P2 = "00000000-0000-4000-8000-000000000102";
      const S2 = "00000000-0000-4000-8000-000000000202";
      await m.plans.createPlan(U2, { ...plan, id: P2 }, [{ ...session, id: S2, planId: P2 }], "h2");
      expect(await m.store.create(U2, checkIn({ sessionId: S2 }))).toEqual({ status: "exists", mine: false });
    });

    it("refuses a session that is not the user's or not live", async () => {
      expect(await m.store.create(U2, checkIn())).toEqual({ status: "no_session" });
      await m.plans.deleteSession(U1, S1, 1, NOW);
      expect(await m.store.create(U1, checkIn())).toEqual({ status: "no_session" });
    });
  });
}
