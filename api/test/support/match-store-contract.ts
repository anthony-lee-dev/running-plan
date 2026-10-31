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

    it("refuses a write when a suggestion landed in between, which moves no revision", async () => {
      const stale = await m.store.load(U1, { sessionId: S1, activityId: A1 });
      const between = await m.store.load(U1, { sessionId: S1, activityId: A2 });
      await m.store.apply(U1, between, planMatchChange(between, { kind: "put", sessionId: S1, activityId: A2, status: "suggested" }, NOW), NOW);
      await expect(m.store.apply(U1, stale, planMatchChange(stale, { kind: "put", sessionId: S1, activityId: A1, status: "confirmed" }, LATER), LATER)).rejects.toBeInstanceOf(MatchConflictError);
    });

    it("refuses a write when a match changed only its time", async () => {
      const suggest = async (at: string) => {
        const s = await m.store.load(U1, { sessionId: S1, activityId: A1 });
        await m.store.apply(U1, s, planMatchChange(s, { kind: "put", sessionId: S1, activityId: A1, status: "suggested" }, at), at);
      };
      await suggest(NOW);
      const stale = await m.store.load(U1, { sessionId: S1, activityId: A1 });
      await suggest(LATER);
      await expect(m.store.apply(U1, stale, planMatchChange(stale, { kind: "delete", sessionId: S1 }, LATER), LATER)).rejects.toBeInstanceOf(MatchConflictError);
    });

    it.each(["session", "plan"])("frees an activity whose matched %s was deleted", async (what) => {
      await confirm(S1, A1);
      if (what === "session") await m.plans.deleteSession(U1, S1, 2, LATER);
      else {
        await m.plans.createPlan(U1, { ...plan, id: "00000000-0000-4000-8000-000000000102" }, [{ ...session("00000000-0000-4000-8000-000000000203", "2026-10-29"), planId: "00000000-0000-4000-8000-000000000102" }], "h2");
        await m.plans.deletePlan(U1, P1, 1, LATER);
      }
      const target = what === "session" ? S2 : "00000000-0000-4000-8000-000000000203";
      const state = await m.store.load(U1, { sessionId: target, activityId: A1 });
      await m.store.apply(U1, state, planMatchChange(state, { kind: "put", sessionId: target, activityId: A1, status: "confirmed" }, LATER), LATER);
      expect(await m.store.forActivities(U1, [A1])).toEqual([{ sessionId: target, activityId: A1, status: "confirmed", updatedAt: LATER }]);
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

    // Backlog 2.21: deleting what an activity is matched to puts the activity back in the inbox.
    it("deleting a session unlinks its match and puts a confirmed activity back in the inbox", async () => {
      await confirm(S1, A1);
      const before = await m.store.load(U1, { activityId: A1 });
      expect(before.activities[0]).toMatchObject({ disposition: "matched" });
      expect(await m.plans.deleteSession(U1, S1, 2, LATER)).toMatchObject({ ok: true });

      const after = await m.store.load(U1, { activityId: A1 });
      expect(after.matches).toEqual([]);
      expect(after.activities[0]).toEqual({ id: A1, disposition: "inbox", revision: before.activities[0]!.revision + 1 });
    });

    it("deleting a session drops a suggested match and leaves its activity as it was", async () => {
      const state = await m.store.load(U1, { sessionId: S1, activityId: A1 });
      await m.store.apply(U1, state, planMatchChange(state, { kind: "put", sessionId: S1, activityId: A1, status: "suggested" }, NOW), NOW);
      await m.plans.deleteSession(U1, S1, 1, LATER);

      const after = await m.store.load(U1, { activityId: A1 });
      expect(after.matches).toEqual([]);
      expect(after.activities[0]).toEqual({ id: A1, disposition: "inbox", revision: 1 });
    });

    it("deleting a plan unlinks every match of its sessions", async () => {
      await confirm(S1, A1);
      await confirm(S2, A2);
      const revision = (await m.plans.getPlan(U1, P1))!.plan.revision;
      expect(await m.plans.deletePlan(U1, P1, revision, LATER)).toMatchObject({ ok: true });

      for (const id of [A1, A2]) {
        const after = await m.store.load(U1, { activityId: id });
        expect(after.matches).toEqual([]);
        expect(after.activities[0]).toMatchObject({ id, disposition: "inbox" });
      }
    });

    it("a refused plan delete unlinks nothing", async () => {
      await confirm(S1, A1);
      const revision = (await m.plans.getPlan(U1, P1))!.plan.revision;
      expect(await m.plans.deletePlan(U1, P1, revision - 1, LATER)).toMatchObject({ ok: false, reason: "conflict" });
      const after = await m.store.load(U1, { activityId: A1 });
      expect(after.matches).toHaveLength(1);
      expect(after.activities[0]).toMatchObject({ disposition: "matched" });
    });

    it("another user's matches survive a delete", async () => {
      const P2 = "00000000-0000-4000-8000-000000000102";
      const S3 = "00000000-0000-4000-8000-000000000203";
      const A3 = "00000000-0000-4000-8000-000000000903";
      await m.plans.createPlan(U2, { ...plan, id: P2 }, [{ ...session(S3, "2026-10-28"), planId: P2 }], "h");
      await m.activities.applyImport(U2, [activity(A3, 3)], []);
      const theirs = await m.store.load(U2, { sessionId: S3, activityId: A3 });
      await m.store.apply(U2, theirs, planMatchChange(theirs, { kind: "put", sessionId: S3, activityId: A3, status: "confirmed" }, NOW), NOW);
      await confirm(S1, A1);

      const revision = (await m.plans.getPlan(U1, P1))!.plan.revision;
      await m.plans.deletePlan(U1, P1, revision, LATER);

      const after = await m.store.load(U2, { activityId: A3 });
      expect(after.matches).toHaveLength(1);
      expect(after.activities[0]).toMatchObject({ disposition: "matched" });
    });

    describe("suggestionCandidates", () => {
      const ids = async (userId: string, from: string, to: string) => (await m.store.suggestionCandidates(userId, from, to)).map((s) => s.id).sort();

      it("returns planned, unmatched, live sessions in the date range, with their content", async () => {
        expect(await ids(U1, "2026-10-28", "2026-10-28")).toEqual([S1]);
        expect(await ids(U1, "2026-10-28", "2026-10-29")).toEqual([S1, S2]);
        expect(await ids(U1, "2026-11-01", "2026-11-02")).toEqual([]);
        const [first] = await m.store.suggestionCandidates(U1, "2026-10-28", "2026-10-28");
        expect(first).toMatchObject({ id: S1, date: "2026-10-28", type: "easy", steps: [{ kind: "work" }] });
      });

      it("leaves out matched, done, other users' and deleted sessions", async () => {
        const state = await m.store.load(U1, { sessionId: S1, activityId: A1 });
        await m.store.apply(U1, state, planMatchChange(state, { kind: "put", sessionId: S1, activityId: A1, status: "suggested" }, NOW), NOW);
        expect(await ids(U1, "2026-10-28", "2026-10-29")).toEqual([S2]);
        await confirm(S2, A2);
        expect(await ids(U1, "2026-10-28", "2026-10-29")).toEqual([]);
        expect(await ids(U2, "2026-10-28", "2026-10-29")).toEqual([]);
      });

      it("leaves out a deleted session and a deleted plan", async () => {
        await m.plans.deleteSession(U1, S1, 1, LATER);
        expect(await ids(U1, "2026-10-28", "2026-10-29")).toEqual([S2]);
        await m.plans.deletePlan(U1, P1, (await m.plans.getPlan(U1, P1))!.plan.revision, LATER);
        expect(await ids(U1, "2026-10-28", "2026-10-29")).toEqual([]);
      });
    });

    it("a refused session delete unlinks nothing", async () => {
      await confirm(S1, A1);
      expect(await m.plans.deleteSession(U1, S1, 1, LATER)).toMatchObject({ ok: false, reason: "conflict" });
      const after = await m.store.load(U1, { activityId: A1 });
      expect(after.matches).toHaveLength(1);
      expect(after.activities[0]).toMatchObject({ disposition: "matched" });
    });
  });
}
