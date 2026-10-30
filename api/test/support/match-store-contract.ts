import { beforeEach, describe, expect, it } from "vitest";
import type { StoredActivity } from "../../src/domain/activities";
import { planMatchChange } from "../../src/domain/matches";
import { MatchConflictError, type ActivityStore, type AuthStore, type MatchStore, type PlanStore, type StoredPlan, type StoredSession } from "../../src/ports";

const NOW = "2026-10-29T09:00:00.000Z";
const LATER = "2026-10-29T10:00:00.000Z";
const U1 = "00000000-0000-4000-8000-000000000001";
const U2 = "00000000-0000-4000-8000-000000000002";
const P1 = "00000000-0000-4000-8000-000000000101";
const S1 = "00000000-0000-4000-8000-000000000201";
const S2 = "00000000-0000-4000-8000-000000000202";
const A1 = "00000000-0000-4000-8000-000000000901";
const A2 = "00000000-0000-4000-8000-000000000902";

const plan: StoredPlan = {
  id: P1, goal: { type: "5k" }, startDate: "2026-10-26", weekCount: 8, source: "blank", adaptive: false, weeks: [],
  revision: 1, contentRevision: 1, updatedAt: NOW, deletedAt: null,
};
const session = (id: string, date: string): StoredSession => ({
  id, planId: P1, date, type: "easy", key: false, status: "planned", owner: "system",
  steps: [{ kind: "work", goal: { type: "distance", value: 5000 }, target: { type: "effort", effort: "easy" } }],
  revision: 1, updatedAt: NOW, deletedAt: null,
});
const activity = (id: string, n: number): StoredActivity => ({
  id, source: "apple_health", externalId: `HK-${n}`, workoutType: "running", startedAt: "2026-10-28T07:00:00-04:00",
  localDate: "2026-10-28", durationSec: 1800, distanceM: 5000, disposition: "inbox", importedAt: NOW, revision: 1, updatedAt: NOW,
});

type Made = { store: MatchStore; plans: PlanStore; activities: ActivityStore; auth: AuthStore; reset: () => Promise<void> };

/** Behaviour every MatchStore must have; run against the in-memory store and the D1 store. */
export function matchStoreContract(name: string, make: () => Promise<Made>) {
  describe(`MatchStore: ${name}`, () => {
    let m: Made;
    beforeEach(async () => {
      m = await make();
      await m.reset();
      await m.auth.findOrCreateUser("a@example.com", U1, NOW);
      await m.auth.findOrCreateUser("b@example.com", U2, NOW);
      await m.plans.createPlan(U1, plan, [session(S1, "2026-10-28"), session(S2, "2026-10-29")], "h");
      await m.activities.applyImport(U1, [activity(A1, 1), activity(A2, 2)], []);
    });

    const confirm = async (sessionId: string, activityId: string, at = NOW) => {
      const state = await m.store.load(U1, { sessionId, activityId });
      await m.store.apply(U1, state, planMatchChange(state, { kind: "put", sessionId, activityId, status: "confirmed" }, at), at);
    };

    it("loads the named session and activity with nothing matched yet", async () => {
      const state = await m.store.load(U1, { sessionId: S1, activityId: A1 });
      expect(state).toEqual({
        sessions: [{ id: S1, planId: P1, status: "planned", revision: 1 }],
        activities: [{ id: A1, disposition: "inbox", revision: 1 }],
        matches: [],
      });
    });

    it("confirming writes the match, the done session, the plan content revision and the activity", async () => {
      await confirm(S1, A1);
      expect(await m.store.forActivities(U1, [A1, A2])).toEqual([{ sessionId: S1, activityId: A1, status: "confirmed", updatedAt: NOW }]);
      const got = await m.plans.getSession(U1, S1);
      expect(got?.session).toMatchObject({ status: "done", revision: 2 });
      expect(got?.plan.contentRevision).toBe(2);
      const [a1] = await m.activities.candidates(U1, "2026-10-28", "2026-10-28", [{ source: "apple_health", externalId: "HK-1" }]).then((l) => l.filter((a) => a.id === A1));
      expect(a1).toMatchObject({ disposition: "matched", revision: 2 });
    });

    it("loads the other ends of existing matches, so a move can undo them", async () => {
      await confirm(S1, A1);
      const state = await m.store.load(U1, { sessionId: S2, activityId: A1 });
      expect(state.sessions.map((s) => s.id).sort()).toEqual([S1, S2]);
      expect(state.matches).toEqual([{ sessionId: S1, activityId: A1, status: "confirmed", updatedAt: NOW }]);
      await m.store.apply(U1, state, planMatchChange(state, { kind: "put", sessionId: S2, activityId: A1, status: "confirmed" }, LATER), LATER);
      expect(await m.store.forActivities(U1, [A1])).toEqual([{ sessionId: S2, activityId: A1, status: "confirmed", updatedAt: LATER }]);
      expect((await m.plans.getSession(U1, S1))?.session.status).toBe("planned");
      expect((await m.plans.getSession(U1, S2))?.session.status).toBe("done");
    });

    it("refuses a write based on a stale read and writes nothing", async () => {
      const stale = await m.store.load(U1, { sessionId: S1, activityId: A1 });
      await confirm(S1, A2);
      await expect(m.store.apply(U1, stale, planMatchChange(stale, { kind: "put", sessionId: S1, activityId: A1, status: "confirmed" }, LATER), LATER)).rejects.toBeInstanceOf(MatchConflictError);
      expect(await m.store.forActivities(U1, [A1, A2])).toEqual([{ sessionId: S1, activityId: A2, status: "confirmed", updatedAt: NOW }]);
    });

    it("keeps users apart", async () => {
      expect(await m.store.load(U2, { sessionId: S1, activityId: A1 })).toEqual({ sessions: [], activities: [], matches: [] });
      await confirm(S1, A1);
      expect(await m.store.forActivities(U2, [A1])).toEqual([]);
    });

    it("leaves out matches whose session was deleted", async () => {
      await confirm(S1, A1);
      await m.plans.deleteSession(U1, S1, 2, LATER);
      expect(await m.store.forActivities(U1, [A1])).toEqual([]);
    });
  });
}
