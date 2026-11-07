import { beforeEach, describe, expect, it } from "vitest";
import type { StoredActivity } from "../../src/domain/activities";
import { planMatchChange } from "../../src/domain/matches";
import type { SessionContent } from "../../src/domain/plan-input";
import type { ProposalChangeRecord, StoredProposal } from "../../src/domain/proposal-model";
import type { ActivityStore, AuthStore, CheckInStore, MatchStore, PlanStore, ProposalStore, StoredPlan, StoredSession } from "../../src/ports";

const T = (n: number) => `2026-10-29T09:00:${String(n).padStart(2, "0")}.000Z`;
const id = (n: number) => `00000000-0000-4000-8000-${String(n).padStart(12, "0")}`;
const U1 = id(1);
const U2 = id(2);
const P1 = id(101);
const S1 = id(201);
const S2 = id(202);
const S3 = id(203);
const NEW = id(250);
const A1 = id(901);

const steps = (m: number): SessionContent["steps"] => [{ kind: "work", goal: { type: "distance", value: m }, target: { type: "effort", effort: "easy" } }];
const content = (date: string, over: Partial<SessionContent> = {}): SessionContent => ({ date, type: "easy", key: false, status: "planned", owner: "system", steps: steps(5000), ...over });
const session = (sid: string, date: string, over: Partial<SessionContent> = {}): StoredSession => ({ ...content(date, over), id: sid, planId: P1, revision: 1, updatedAt: T(0), deletedAt: null });
const plan: StoredPlan = {
  id: P1, goal: { type: "5k", label: "Park run" }, startDate: "2026-10-26", weekCount: 4, source: "rules", engine: { presetId: "5k", version: "0.2.0" }, adaptive: true,
  weeks: [{ index: 0, phase: "base" }, { index: 1, phase: "base", notes: "keep it easy" }, { index: 2, phase: "build" }, { index: 3, phase: "taper" }],
  revision: 1, contentRevision: 1, updatedAt: T(0), deletedAt: null,
};
const activity: StoredActivity = {
  id: A1, source: "apple_health", externalId: "HK-1", workoutType: "running", startedAt: "2026-10-28T07:00:00-04:00",
  localDate: "2026-10-28", durationSec: 1800, distanceM: 5000, disposition: "inbox", importedAt: T(0), revision: 1, updatedAt: T(0),
};

const proposal = (n: number, over: Partial<StoredProposal> = {}): StoredProposal => ({
  id: id(300 + n), planId: P1, baseContentRevision: 1, kind: "adjustment", creator: { type: "rules", version: "0.1.0" }, reason: "Because.", urgent: false,
  changes: [], status: "pending", createdAt: T(n), updatedAt: T(n), deletedAt: null, resolvedAt: null, revision: 1, key: `key:${n}`, ...over,
});

type Made = {
  store: ProposalStore;
  plans: PlanStore;
  checkIns: CheckInStore;
  matches: MatchStore;
  activities: ActivityStore;
  auth: AuthStore;
  reset: () => Promise<void>;
};

/** Behaviour every ProposalStore must have; run against the in-memory store and the D1 store. */
export function proposalStoreContract(name: string, make: () => Promise<Made>) {
  describe(`ProposalStore: ${name}`, () => {
    let m: Made;
    beforeEach(async () => {
      m = await make();
      await m.reset();
      await m.auth.findOrCreateUser("a@example.com", U1, T(0));
      await m.auth.findOrCreateUser("b@example.com", U2, T(0));
      await m.plans.createPlan(U1, plan, [session(S1, "2026-10-28"), session(S2, "2026-11-04"), session(S3, "2026-11-05", { owner: "user" })], "h");
    });

    const view = (p: StoredProposal): StoredProposal => ({ ...p });

    it("stores proposals and lists them newest first by status", async () => {
      expect(await m.store.create(U1, [proposal(1), proposal(2), proposal(3, { status: "dismissed" })])).toBe(true);
      expect((await m.store.list(U1, P1, "pending")).map((p) => p.id)).toEqual([id(302), id(301)]);
      expect((await m.store.list(U1, P1, "dismissed")).map((p) => p.id)).toEqual([id(303)]);
      expect(await m.store.list(U1, P1, "accepted")).toEqual([]);
      expect(await m.store.list(U2, P1, "pending")).toEqual([]);
      expect((await m.store.list(U1, P1, "pending"))[0]).toEqual(view(proposal(2)));
    });

    it("round-trips changes and plan changes", async () => {
      const changes: ProposalChangeRecord[] = [
        { op: "update", sessionId: S2, before: content("2026-11-04"), after: content("2026-11-04", { steps: steps(4000) }), userOwned: false },
        { op: "delete", sessionId: S3, before: content("2026-11-05", { owner: "user" }), userOwned: true },
        { op: "create", sessionId: NEW, after: content("2026-11-06"), userOwned: false },
      ];
      const planChanges = { goal: { type: "10k" as const }, weekCount: 6, weeks: [{ index: 2, phase: "build" as const }], engine: { presetId: "10k", version: "0.2.0", interview: { goal: { distance: "10k" } } } };
      await m.store.create(U1, [proposal(1, { kind: "interview_rerun", changes, planChanges })]);
      const [stored] = await m.store.list(U1, P1, "pending");
      expect(stored).toMatchObject({ kind: "interview_rerun", changes, planChanges });
    });

    it("writes nothing when the plan has moved on, is gone, or is not the user's", async () => {
      expect(await m.store.create(U1, [proposal(1, { baseContentRevision: 7 })])).toBe(false);
      expect(await m.store.create(U2, [proposal(1)])).toBe(false);
      expect(await m.store.create(U1, [proposal(1, { planId: id(999) })])).toBe(false);
      expect(await m.store.list(U1, P1, "pending")).toEqual([]);
      expect(await m.store.create(U1, [])).toBe(true);
    });

    it("marks a pending proposal stale once the plan moves, and moves its updatedAt", async () => {
      await m.store.create(U1, [proposal(1), proposal(2)]);
      await m.plans.writeSession(U1, S1, 1, content("2026-10-28", { status: "done" }), T(10));
      await m.store.markStale(U1, T(11));
      expect(await m.store.list(U1, P1, "pending")).toEqual([]);
      const stale = await m.store.list(U1, P1, "stale");
      expect(stale.map((p) => p.id).sort()).toEqual([id(301), id(302)]);
      expect(stale[0]).toMatchObject({ status: "stale", updatedAt: T(11), revision: 2 });
      expect(await m.store.usedKeys(U1, P1)).toEqual([]);
      // Nothing more to do the second time.
      await m.store.markStale(U1, T(12));
      expect((await m.store.list(U1, P1, "stale"))[0]!.updatedAt).toBe(T(11));
    });

    it("lists a proposal as stale even when nobody called markStale", async () => {
      await m.store.create(U1, [proposal(1)]);
      await m.plans.writeSession(U1, S1, 1, content("2026-10-28", { status: "done" }), T(10));
      expect(await m.store.list(U1, P1, "pending")).toEqual([]);
      expect(await m.store.list(U1, P1, "stale")).toHaveLength(1);
    });

    it("tells which adjustment keys still count", async () => {
      await m.store.create(U1, [proposal(1), proposal(2, { status: "dismissed" }), proposal(3, { status: "accepted" }), proposal(4, { kind: "interview_rerun" })]);
      const { key: _key, ...noKey } = proposal(5);
      await m.store.create(U1, [noKey]);
      expect((await m.store.usedKeys(U1, P1)).sort()).toEqual(["key:1", "key:2", "key:3", "key:4"]);
    });

    it("dismisses a pending proposal once", async () => {
      await m.store.create(U1, [proposal(1)]);
      const done = await m.store.dismiss(U1, id(301), T(20));
      expect(done).toMatchObject({ ok: true, proposal: { status: "dismissed", resolvedAt: T(20), updatedAt: T(20), revision: 2 } });
      expect(await m.store.dismiss(U1, id(301), T(21))).toEqual({ ok: false, reason: "not_pending", status: "dismissed" });
      expect(await m.store.dismiss(U2, id(301), T(21))).toEqual({ ok: false, reason: "not_found" });
      expect(await m.store.dismiss(U1, id(398), T(21))).toEqual({ ok: false, reason: "not_found" });
    });

    it("will not dismiss a stale proposal", async () => {
      await m.store.create(U1, [proposal(1)]);
      await m.plans.deleteSession(U1, S1, 1, T(10));
      expect(await m.store.dismiss(U1, id(301), T(20))).toEqual({ ok: false, reason: "not_pending", status: "stale" });
    });

    describe("accept", () => {
      const changes = (): ProposalChangeRecord[] => [
        { op: "update", sessionId: S2, before: content("2026-11-04"), after: content("2026-11-04", { steps: steps(4000), title: "Easy" }), userOwned: false },
        { op: "update", sessionId: S3, before: content("2026-11-05", { owner: "user" }), after: content("2026-11-05", { owner: "user", steps: steps(3000) }), userOwned: true },
        { op: "create", sessionId: NEW, after: content("2026-11-06", { type: "long", steps: steps(8000) }), userOwned: false },
        { op: "delete", sessionId: S1, before: content("2026-10-28"), userOwned: false },
      ];

      it("applies updates, creates and deletes, skips user-owned changes, and moves the plan once", async () => {
        await m.store.create(U1, [proposal(1, { changes: changes() })]);
        expect(await m.store.accept(U1, id(301), false, T(30))).toEqual({ ok: true, planId: P1 });
        const got = (await m.plans.getPlan(U1, P1))!;
        expect(got.plan).toMatchObject({ revision: 1, contentRevision: 2, updatedAt: T(30) });
        const byId = new Map(got.sessions.map((s) => [s.id, s]));
        expect(byId.has(S1)).toBe(false);
        expect(byId.get(S2)).toMatchObject({ title: "Easy", steps: steps(4000), revision: 2, updatedAt: T(30), owner: "system" });
        expect(byId.get(S3)).toMatchObject({ steps: steps(5000), revision: 1 });
        expect(byId.get(NEW)).toMatchObject({ date: "2026-11-06", type: "long", steps: steps(8000), revision: 1, owner: "system", status: "planned", planId: P1 });
        const [accepted] = await m.store.list(U1, P1, "accepted");
        expect(accepted).toMatchObject({ id: id(301), status: "accepted", resolvedAt: T(30), updatedAt: T(30), revision: 2 });
      });

      it("applies the user-owned changes when the user opts in, keeping the session theirs", async () => {
        await m.store.create(U1, [proposal(1, { changes: changes() })]);
        expect(await m.store.accept(U1, id(301), true, T(30))).toMatchObject({ ok: true });
        const got = (await m.plans.getSession(U1, S3))!;
        expect(got.session).toMatchObject({ steps: steps(3000), owner: "user", revision: 2 });
      });

      it("applies plan changes: goal, length, weeks and engine, and moves the plan revision", async () => {
        const planChanges = {
          goal: { type: "10k" as const, label: "Park run", date: "2026-11-29" },
          weekCount: 5,
          weeks: [{ index: 1, phase: "build" as const }, { index: 2 }, { index: 3, phase: "peak" as const, notes: "go" }, { index: 4, phase: "taper" as const }],
          engine: { presetId: "10k", version: "0.2.0", interview: { goal: { distance: "10k" } } },
        };
        await m.store.create(U1, [proposal(1, { kind: "interview_rerun", changes: [], planChanges })]);
        expect(await m.store.accept(U1, id(301), false, T(30))).toMatchObject({ ok: true });
        const { plan: after } = (await m.plans.getPlan(U1, P1))!;
        expect(after).toMatchObject({ revision: 2, contentRevision: 2, weekCount: 5, goal: planChanges.goal, engine: planChanges.engine });
        expect(after.weeks).toEqual([{ index: 0, phase: "base" }, { index: 1, phase: "build" }, { index: 2 }, { index: 3, phase: "peak", notes: "go" }, { index: 4, phase: "taper" }]);
      });

      it("drops the weeks past a shorter plan", async () => {
        await m.store.create(U1, [proposal(1, { kind: "interview_rerun", changes: [], planChanges: { weekCount: 2 } })]);
        await m.store.accept(U1, id(301), false, T(30));
        const { plan: after } = (await m.plans.getPlan(U1, P1))!;
        expect(after.weekCount).toBe(2);
        expect(after.weeks.map((w) => w.index)).toEqual([0, 1]);
      });

      it("unlinks the match of a session it deletes, returning the activity to the inbox", async () => {
        await m.activities.applyImport(U1, [activity], []);
        const state = await m.matches.load(U1, { sessionId: S1, activityId: A1 });
        await m.matches.apply(U1, state, planMatchChange(state, { kind: "put", sessionId: S1, activityId: A1, status: "suggested" }, T(5)), T(5));
        await m.store.create(U1, [proposal(1, { baseContentRevision: 1, changes: [{ op: "delete", sessionId: S1, before: content("2026-10-28"), userOwned: false }] })]);
        expect(await m.store.accept(U1, id(301), false, T(30))).toMatchObject({ ok: true });
        expect(await m.matches.forActivities(U1, [A1])).toEqual([]);
        const [a] = await m.activities.candidates(U1, "2026-10-28", "2026-10-28", [{ source: "apple_health", externalId: "HK-1" }]);
        expect(a).toMatchObject({ disposition: "inbox" });
      });

      it("refuses a proposal that is no longer pending, or whose plan moved, and writes nothing", async () => {
        await m.store.create(U1, [proposal(1, { changes: changes() }), proposal(2, { changes: changes() })]);
        await m.plans.writeSession(U1, S1, 1, content("2026-10-28", { status: "skipped" }), T(10));
        expect(await m.store.accept(U1, id(301), false, T(30))).toEqual({ ok: false, reason: "not_pending", status: "stale" });
        const got = (await m.plans.getPlan(U1, P1))!;
        expect(got.plan.contentRevision).toBe(2);
        expect(got.sessions.find((s) => s.id === S2)).toMatchObject({ revision: 1 });
        expect(got.sessions.find((s) => s.id === NEW)).toBeUndefined();

        await m.store.create(U1, [proposal(3, { baseContentRevision: 2, changes: [] })]);
        expect(await m.store.accept(U1, id(303), false, T(31))).toMatchObject({ ok: true });
        expect(await m.store.accept(U1, id(303), false, T(32))).toEqual({ ok: false, reason: "not_pending", status: "accepted" });
        expect((await m.plans.getPlan(U1, P1))!.plan.contentRevision).toBe(3);
      });

      it("makes the other pending proposals of the plan stale", async () => {
        await m.store.create(U1, [proposal(1, { changes: [] }), proposal(2, { changes: [] })]);
        await m.store.accept(U1, id(301), false, T(30));
        expect(await m.store.accept(U1, id(302), false, T(31))).toEqual({ ok: false, reason: "not_pending", status: "stale" });
      });

      it("does not find another user's proposal", async () => {
        await m.store.create(U1, [proposal(1, { changes: [] })]);
        expect(await m.store.accept(U2, id(301), false, T(30))).toEqual({ ok: false, reason: "not_found" });
        expect(await m.store.accept(U1, id(399), false, T(30))).toEqual({ ok: false, reason: "not_found" });
      });
    });

    it("tombstones a plan's proposals when the plan is deleted", async () => {
      await m.store.create(U1, [proposal(1)]);
      await m.plans.deletePlan(U1, P1, 1, T(40));
      expect(await m.store.list(U1, P1, "pending")).toEqual([]);
      expect(await m.store.list(U1, P1, "stale")).toEqual([]);
    });

    it("reads a plan's live check-ins", async () => {
      await m.checkIns.create(U1, { id: id(501), sessionId: S1, when: "after", feel: 2, effortFelt: 9, pain: true, revision: 1, updatedAt: T(1), deletedAt: null });
      await m.checkIns.create(U1, { id: id(502), sessionId: S2, when: "before", feel: 4, pain: false, revision: 1, updatedAt: T(2), deletedAt: null });
      await m.plans.deleteSession(U1, S2, 1, T(3));
      const found = await m.store.checkInsForPlan(U1, P1);
      expect(found.map((c) => c.id)).toEqual([id(501)]);
      expect(found[0]).toMatchObject({ sessionId: S1, when: "after", feel: 2, effortFelt: 9, pain: true });
      expect(await m.store.checkInsForPlan(U2, P1)).toEqual([]);
    });
  });
}
