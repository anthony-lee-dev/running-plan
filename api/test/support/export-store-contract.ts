import { beforeEach, describe, expect, it } from "vitest";
import type { StoredActivity } from "../../src/domain/activities";
import { planMatchChange } from "../../src/domain/matches";
import type { AccountExportStore, ActivityStore, AuthStore, CheckInStore, MatchStore, PlanStore, StoredCheckIn, StoredPlan, StoredSession } from "../../src/ports";

const NOW = "2026-10-29T09:00:00.000Z";
const LATER = "2026-10-29T10:00:00.000Z";
const U1 = "00000000-0000-4000-8000-000000000001";
const U2 = "00000000-0000-4000-8000-000000000002";
const P1 = "00000000-0000-4000-8000-000000000101";
const P2 = "00000000-0000-4000-8000-000000000102";
const P3 = "00000000-0000-4000-8000-000000000103";
const S1 = "00000000-0000-4000-8000-000000000201";
const S2 = "00000000-0000-4000-8000-000000000202";
const S3 = "00000000-0000-4000-8000-000000000203";
const S9 = "00000000-0000-4000-8000-000000000209";
const A1 = "00000000-0000-4000-8000-000000000901";
const A2 = "00000000-0000-4000-8000-000000000902";
const A9 = "00000000-0000-4000-8000-000000000909";
const C1 = "00000000-0000-4000-8000-000000000301";
const C2 = "00000000-0000-4000-8000-000000000302";
const C9 = "00000000-0000-4000-8000-000000000309";

const plan = (id: string, startDate: string, over: Partial<StoredPlan> = {}): StoredPlan => ({
  id, goal: { type: "5k", date: "2026-12-20", label: "Parkrun" }, startDate, weekCount: 8, source: "rules",
  engine: { presetId: "5k", version: "1.0.0", interview: { weeklyDistanceM: 15000 } }, adaptive: true,
  weeks: [{ index: 0, phase: "base", notes: "Easy start" }, { index: 1 }],
  revision: 1, contentRevision: 1, updatedAt: NOW, deletedAt: null, ...over,
});
const session = (id: string, planId: string, date: string): StoredSession => ({
  id, planId, date, type: "easy", title: "Easy run", key: false, status: "planned", owner: "system", notes: "Chat pace",
  steps: [{ kind: "work", goal: { type: "distance", value: 5000 }, target: { type: "effort", effort: "easy" } }],
  revision: 1, updatedAt: NOW, deletedAt: null,
});
const activity = (id: string, n: number, localDate: string): StoredActivity => ({
  id, source: "apple_health", externalId: `HK-${n}`, sourceApp: "Strava", workoutType: "running", startedAt: `${localDate}T07:00:00-04:00`,
  localDate, durationSec: 1800, distanceM: 5000, avgHeartRate: 150, disposition: "inbox", importedAt: NOW, revision: 1, updatedAt: NOW,
});
const checkIn = (id: string, sessionId: string, over: Partial<StoredCheckIn> = {}): StoredCheckIn => ({
  id, sessionId, when: "after", feel: 4, effortFelt: 6, pain: false, note: "ok", revision: 1, updatedAt: NOW, deletedAt: null, ...over,
});

type Made = {
  store: AccountExportStore;
  auth: AuthStore;
  plans: PlanStore;
  activities: ActivityStore;
  matches: MatchStore;
  checkIns: CheckInStore;
  reset: () => Promise<void>;
};

/** Behaviour every AccountExportStore must have; run against the in-memory store and the D1 store. */
export function accountExportStoreContract(name: string, make: () => Promise<Made>) {
  describe(`AccountExportStore: ${name}`, () => {
    let m: Made;
    beforeEach(async () => {
      m = await make();
      await m.reset();
      await m.auth.findOrCreateUser("a@example.com", U1, NOW);
      await m.auth.findOrCreateUser("b@example.com", U2, NOW);
    });

    const confirm = async (userId: string, sessionId: string, activityId: string) => {
      const state = await m.matches.load(userId, { sessionId, activityId });
      await m.matches.apply(userId, state, planMatchChange(state, { kind: "put", sessionId, activityId, status: "confirmed" }, LATER), LATER);
    };

    it("is undefined for a user that does not exist", async () => {
      expect(await m.store.read("00000000-0000-4000-8000-0000000000ff")).toBeUndefined();
    });

    it("an account with nothing stored has its email and empty lists", async () => {
      expect(await m.store.read(U1)).toEqual({ email: "a@example.com", plans: [], sessions: [], activities: [], matches: [], checkins: [], proposals: [] });
    });

    it("returns everything the user has, in a stable order", async () => {
      await m.plans.createPlan(U1, plan(P1, "2026-10-26"), [session(S2, P1, "2026-10-29"), session(S1, P1, "2026-10-28")], "h1");
      await m.plans.createPlan(U1, plan(P2, "2026-12-01", { weeks: [] }), [session(S3, P2, "2026-12-02")], "h2");
      await m.activities.applyImport(U1, [activity(A1, 1, "2026-10-28"), activity(A2, 2, "2026-10-29")], []);
      await confirm(U1, S1, A1);
      await m.checkIns.create(U1, checkIn(C1, S1));

      const data = (await m.store.read(U1))!;
      expect(data.email).toBe("a@example.com");
      // Newest start first, with weeks.
      expect(data.plans.map((p) => p.id)).toEqual([P2, P1]);
      expect(data.plans[1]).toMatchObject({ ...plan(P1, "2026-10-26"), revision: 1, contentRevision: 2, updatedAt: LATER });
      expect(data.plans[0]!.weeks).toEqual([]);
      expect(data.sessions.map((s) => s.id)).toEqual([S1, S2, S3]);
      expect(data.sessions[0]).toMatchObject({ ...session(S1, P1, "2026-10-28"), status: "done", revision: 2, updatedAt: LATER });
      expect(data.activities.map((a) => a.id)).toEqual([A2, A1]);
      expect(data.activities.find((a) => a.id === A1)).toMatchObject({ ...activity(A1, 1, "2026-10-28"), disposition: "matched", revision: 2, updatedAt: LATER });
      expect(data.matches).toEqual([{ sessionId: S1, activityId: A1, status: "confirmed", updatedAt: LATER }]);
      expect(data.checkins).toEqual([checkIn(C1, S1)]);
      expect(data.proposals).toEqual([]);
    });

    it("never includes another user's rows", async () => {
      await m.plans.createPlan(U1, plan(P1, "2026-10-26"), [session(S1, P1, "2026-10-28")], "h1");
      await m.plans.createPlan(U2, plan(P3, "2026-10-26"), [session(S9, P3, "2026-10-28")], "h3");
      await m.activities.applyImport(U2, [activity(A9, 9, "2026-10-28")], []);
      await confirm(U2, S9, A9);
      await m.checkIns.create(U2, checkIn(C9, S9));

      const data = (await m.store.read(U1))!;
      expect(data.plans.map((p) => p.id)).toEqual([P1]);
      expect(data.sessions.map((s) => s.id)).toEqual([S1]);
      expect(data).toMatchObject({ activities: [], matches: [], checkins: [] });
    });

    it("leaves out a deleted plan with its sessions, check-ins and matches", async () => {
      await m.plans.createPlan(U1, plan(P1, "2026-10-26"), [session(S1, P1, "2026-10-28")], "h1");
      await m.plans.createPlan(U1, plan(P2, "2026-12-01"), [session(S3, P2, "2026-12-02")], "h2");
      await m.activities.applyImport(U1, [activity(A1, 1, "2026-10-28")], []);
      await confirm(U1, S1, A1);
      await m.checkIns.create(U1, checkIn(C1, S1));
      await m.checkIns.create(U1, checkIn(C2, S3));
      expect(await m.plans.deletePlan(U1, P1, 1, LATER)).toEqual({ ok: true });

      const data = (await m.store.read(U1))!;
      expect(data.plans.map((p) => p.id)).toEqual([P2]);
      expect(data.sessions.map((s) => s.id)).toEqual([S3]);
      expect(data.checkins.map((c) => c.id)).toEqual([C2]);
      expect(data.matches).toEqual([]);
      // The activity is the user's own data and stays, back in the inbox.
      expect(data.activities).toMatchObject([{ id: A1, disposition: "inbox" }]);
    });

    it("leaves out a deleted session with its check-in and match", async () => {
      await m.plans.createPlan(U1, plan(P1, "2026-10-26"), [session(S1, P1, "2026-10-28"), session(S2, P1, "2026-10-29")], "h1");
      await m.activities.applyImport(U1, [activity(A1, 1, "2026-10-28")], []);
      await confirm(U1, S1, A1);
      await m.checkIns.create(U1, checkIn(C1, S1));
      await m.checkIns.create(U1, checkIn(C2, S2));
      const state = await m.matches.load(U1, { sessionId: S1 });
      expect((await m.plans.deleteSession(U1, S1, state.sessions[0]!.revision, LATER)).ok).toBe(true);

      const data = (await m.store.read(U1))!;
      expect(data.sessions.map((s) => s.id)).toEqual([S2]);
      expect(data.checkins.map((c) => c.id)).toEqual([C2]);
      expect(data.matches).toEqual([]);
    });
  });
}
