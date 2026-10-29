import { beforeEach, describe, expect, it } from "vitest";
import type { AuthStore, PlanStore, StoredPlan, StoredSession } from "../../src/ports";

const NOW = "2026-10-29T09:00:00.000Z";
const LATER = "2026-10-29T10:00:00.000Z";
const U1 = "00000000-0000-4000-8000-000000000001";
const U2 = "00000000-0000-4000-8000-000000000002";
const id = (n: number) => `00000000-0000-4000-8000-${String(n).padStart(12, "0")}`;

export function plan(n: number, over: Partial<StoredPlan> = {}): StoredPlan {
  return {
    id: id(100 + n),
    goal: { type: "5k", date: "2027-01-10" },
    startDate: "2026-11-02",
    weekCount: 10,
    source: "rules",
    engine: { presetId: "5k", version: "1.0.0", interview: { goal: { distance: "5k" } } },
    adaptive: true,
    weeks: [{ index: 0, phase: "base", notes: "easy start" }, { index: 1, phase: "base" }],
    revision: 1,
    contentRevision: 1,
    updatedAt: NOW,
    deletedAt: null,
    ...over,
  };
}

export function session(n: number, planId: string, over: Partial<StoredSession> = {}): StoredSession {
  return {
    id: id(200 + n),
    planId,
    date: "2026-11-03",
    type: "easy",
    key: false,
    status: "planned",
    owner: "system",
    steps: [{ kind: "work", goal: { type: "distance", value: 5000 }, target: { type: "effort", effort: "easy" } }],
    notes: "keep it easy",
    revision: 1,
    updatedAt: NOW,
    deletedAt: null,
    ...over,
  };
}

const content = (s: StoredSession) => {
  const { id: _i, planId: _p, revision: _r, updatedAt: _u, deletedAt: _d, ...rest } = s;
  return rest;
};

/** Behaviour every PlanStore must have; run against the in-memory store and the D1 store. */
export function planStoreContract(name: string, make: () => Promise<{ store: PlanStore; auth: AuthStore; reset: () => Promise<void> }>) {
  describe(`PlanStore: ${name}`, () => {
    let store: PlanStore;
    let auth: AuthStore;
    beforeEach(async () => {
      const made = await make();
      await made.reset();
      store = made.store;
      auth = made.auth;
      await auth.findOrCreateUser("a@example.com", U1, NOW);
      await auth.findOrCreateUser("b@example.com", U2, NOW);
    });

    describe("create and get", () => {
      it("stores a plan with its weeks and sessions and reads them back", async () => {
        const p = plan(1);
        const s = [session(1, p.id), session(2, p.id, { date: "2026-11-05", type: "custom", steps: [], custom: { activityLabel: "cycling", effort: "hard" }, owner: "user", title: "Ride", key: true })];
        expect(await store.createPlan(U1, p, s, "hash-1")).toEqual({ status: "created" });
        const got = await store.getPlan(U1, p.id);
        expect(got?.createHash).toBe("hash-1");
        expect(got?.plan).toEqual(p);
        expect(got?.sessions.map((x) => x.id).sort()).toEqual(s.map((x) => x.id).sort());
        for (const expected of s) expect(got?.sessions.find((x) => x.id === expected.id)).toEqual(expected);
      });

      it("stores a blank plan with no engine, no weeks and no sessions", async () => {
        const p = plan(2, { source: "blank", engine: undefined, adaptive: false, weeks: [] });
        await store.createPlan(U1, p, [], "h");
        expect((await store.getPlan(U1, p.id))?.plan).toEqual(p);
      });

      it("answers 'exists' for the same id, with the stored hash, and changes nothing", async () => {
        const p = plan(1);
        await store.createPlan(U1, p, [session(1, p.id)], "hash-1");
        expect(await store.createPlan(U1, plan(1, { weekCount: 12 }), [], "hash-2")).toEqual({ status: "exists", mine: true, createHash: "hash-1" });
        const got = await store.getPlan(U1, p.id);
        expect(got?.plan.weekCount).toBe(10);
        expect(got?.sessions).toHaveLength(1);
      });

      it("does not reveal another user's plan, even by id", async () => {
        const p = plan(1);
        await store.createPlan(U1, p, [], "hash-1");
        expect(await store.getPlan(U2, p.id)).toBeUndefined();
        expect(await store.createPlan(U2, p, [], "hash-1")).toMatchObject({ status: "exists", mine: false });
        expect((await store.getPlan(U1, p.id))?.plan).toEqual(p);
      });

      it("is all or nothing: a session id that is taken (by anyone) leaves no plan behind", async () => {
        const a = plan(1);
        await store.createPlan(U1, a, [session(1, a.id)], "h");
        const b = plan(2);
        expect(await store.createPlan(U1, b, [session(1, b.id)], "h2")).toEqual({ status: "conflict" });
        expect(await store.createPlan(U2, plan(3), [session(1, id(103))], "h3")).toEqual({ status: "conflict" });
        expect(await store.getPlan(U1, b.id)).toBeUndefined();
        expect(await store.getPlan(U2, id(103))).toBeUndefined();
      });

      it("stores a plan at the limits: 52 weeks and 400 sessions", async () => {
        const p = plan(4, { weekCount: 52, weeks: Array.from({ length: 52 }, (_, i) => ({ index: i, phase: "base" as const })) });
        const sessions = Array.from({ length: 400 }, (_, i) => session(1000 + i, p.id, { date: "2026-11-03" }));
        expect(await store.createPlan(U1, p, sessions, "h")).toEqual({ status: "created" });
        const got = await store.getPlan(U1, p.id);
        expect(got?.sessions).toHaveLength(400);
        expect(got?.plan.weeks).toHaveLength(52);
      });
    });

    describe("list", () => {
      it("lists live plans newest first by start date, then id, for this user only", async () => {
        const a = plan(1, { startDate: "2026-09-01" });
        const b = plan(2, { startDate: "2026-11-02" });
        const c = plan(3, { startDate: "2026-11-02" });
        const other = plan(4, { startDate: "2027-01-01" });
        for (const p of [a, b, c]) await store.createPlan(U1, p, [], "h");
        await store.createPlan(U2, other, [], "h");
        const listed = await store.listPlans(U1, 50);
        expect(listed.map((p) => p.id)).toEqual([c.id, b.id, a.id]);
        expect(listed[0]).toMatchObject({ goal: a.goal, adaptive: true, revision: 1, source: "rules" });
      });

      it("pages with the last plan of the previous page", async () => {
        const plans = [1, 2, 3, 4, 5].map((n) => plan(n, { startDate: `2026-0${n}-01` }));
        for (const p of plans) await store.createPlan(U1, p, [], "h");
        const first = await store.listPlans(U1, 2);
        const second = await store.listPlans(U1, 2, { startDate: first[1]!.startDate, id: first[1]!.id });
        const third = await store.listPlans(U1, 2, { startDate: second[1]!.startDate, id: second[1]!.id });
        expect([...first, ...second, ...third].map((p) => p.id)).toEqual([...plans].reverse().map((p) => p.id));
        expect(third).toHaveLength(1);
      });

      it("leaves out deleted plans", async () => {
        const p = plan(1);
        await store.createPlan(U1, p, [], "h");
        await store.deletePlan(U1, p.id, 1, LATER);
        expect(await store.listPlans(U1, 50)).toEqual([]);
      });
    });

    describe("writePlan", () => {
      it("replaces goal, adaptive and weeks, and moves both revisions", async () => {
        const p = plan(1);
        await store.createPlan(U1, p, [], "h");
        const result = await store.writePlan(U1, p.id, 1, { goal: { type: "10k", label: "Fall 10K" }, adaptive: false, weeks: [{ index: 2, phase: "build", notes: "hills" }] }, LATER);
        expect(result).toMatchObject({ ok: true, plan: { revision: 2, contentRevision: 2, updatedAt: LATER, adaptive: false, goal: { type: "10k", label: "Fall 10K" }, weeks: [{ index: 2, phase: "build", notes: "hills" }] } });
        expect((await store.getPlan(U1, p.id))?.plan).toMatchObject({ revision: 2, weeks: [{ index: 2, phase: "build", notes: "hills" }] });
      });

      it("rejects a stale base with the current revision", async () => {
        const p = plan(1);
        await store.createPlan(U1, p, [], "h");
        await store.writePlan(U1, p.id, 1, { goal: p.goal, adaptive: false, weeks: [] }, LATER);
        expect(await store.writePlan(U1, p.id, 1, { goal: p.goal, adaptive: true, weeks: [] }, LATER)).toEqual({ ok: false, reason: "conflict", currentRevision: 2 });
        expect((await store.getPlan(U1, p.id))?.plan.adaptive).toBe(false);
      });

      it("does not find another user's, a missing or a deleted plan", async () => {
        const p = plan(1);
        await store.createPlan(U1, p, [], "h");
        expect(await store.writePlan(U2, p.id, 1, p, LATER)).toEqual({ ok: false, reason: "not_found" });
        expect(await store.writePlan(U1, id(999), 1, p, LATER)).toEqual({ ok: false, reason: "not_found" });
        await store.deletePlan(U1, p.id, 1, LATER);
        expect(await store.writePlan(U1, p.id, 2, p, LATER)).toEqual({ ok: false, reason: "not_found" });
      });

      it("lets only one of two racing writes win", async () => {
        const p = plan(1);
        await store.createPlan(U1, p, [], "h");
        const results = await Promise.all([
          store.writePlan(U1, p.id, 1, { goal: p.goal, adaptive: false, weeks: [{ index: 0, notes: "a" }] }, LATER),
          store.writePlan(U1, p.id, 1, { goal: p.goal, adaptive: true, weeks: [{ index: 0, notes: "b" }] }, LATER),
        ]);
        expect(results.filter((r) => r.ok)).toHaveLength(1);
        const got = await store.getPlan(U1, p.id);
        expect(got?.plan.revision).toBe(2);
        expect(got?.plan.weeks).toHaveLength(1);
      });
    });

    describe("deletePlan", () => {
      it("tombstones the plan and hides its sessions", async () => {
        const p = plan(1);
        const s = session(1, p.id);
        await store.createPlan(U1, p, [s], "h");
        expect(await store.deletePlan(U1, p.id, 1, LATER)).toEqual({ ok: true });
        expect(await store.getPlan(U1, p.id)).toBeUndefined();
        expect(await store.getSession(U1, s.id)).toBeUndefined();
        expect(await store.deletePlan(U1, p.id, 1, LATER)).toEqual({ ok: false, reason: "not_found" });
      });

      it("needs the current revision, and another user cannot delete it", async () => {
        const p = plan(1);
        await store.createPlan(U1, p, [], "h");
        expect(await store.deletePlan(U1, p.id, 5, LATER)).toEqual({ ok: false, reason: "conflict", currentRevision: 1 });
        expect(await store.deletePlan(U2, p.id, 1, LATER)).toEqual({ ok: false, reason: "not_found" });
        expect(await store.getPlan(U1, p.id)).toBeDefined();
      });
    });

    describe("sessions", () => {
      it("adds a session and moves the plan's contentRevision, not its revision", async () => {
        const p = plan(1);
        await store.createPlan(U1, p, [], "h");
        const s = session(1, p.id, { owner: "user" });
        expect(await store.createSession(U1, s, "sh")).toEqual({ status: "created", contentRevision: 2 });
        const got = await store.getPlan(U1, p.id);
        expect(got?.plan).toMatchObject({ revision: 1, contentRevision: 2 });
        expect(got?.sessions).toEqual([s]);
      });

      it("answers 'exists' for a repeated id with the stored session and hash", async () => {
        const p = plan(1);
        await store.createPlan(U1, p, [], "h");
        const s = session(1, p.id);
        await store.createSession(U1, s, "sh");
        expect(await store.createSession(U1, { ...s, notes: "other" }, "sh2")).toMatchObject({ status: "exists", mine: true, createHash: "sh", session: s });
        expect((await store.getPlan(U1, p.id))?.plan.contentRevision).toBe(2);
      });

      it("refuses a session for a missing, other user's or deleted plan, or one whose id another user holds", async () => {
        const p = plan(1);
        await store.createPlan(U1, p, [], "h");
        expect(await store.createSession(U2, session(1, p.id), "sh")).toEqual({ status: "no_plan" });
        expect(await store.createSession(U1, session(1, id(999)), "sh")).toEqual({ status: "no_plan" });
        const q = plan(2);
        await store.createPlan(U2, q, [session(5, q.id)], "h");
        expect(await store.createSession(U1, session(5, p.id), "sh")).toMatchObject({ status: "exists", mine: false });
        await store.deletePlan(U1, p.id, 1, LATER);
        expect(await store.createSession(U1, session(1, p.id), "sh")).toEqual({ status: "no_plan" });
      });

      it("gets a live session with its plan, for its owner only", async () => {
        const p = plan(1);
        const s = session(1, p.id);
        await store.createPlan(U1, p, [s], "h");
        const got = await store.getSession(U1, s.id);
        expect(got?.session).toEqual(s);
        expect(got?.plan).toMatchObject({ id: p.id, startDate: p.startDate, weekCount: p.weekCount });
        expect(await store.getSession(U2, s.id)).toBeUndefined();
        expect(await store.getSession(U1, id(999))).toBeUndefined();
      });

      it("writes new content when the base revision is current, moving the session and the plan", async () => {
        const p = plan(1);
        const s = session(1, p.id);
        await store.createPlan(U1, p, [s], "h");
        const next = { ...content(s), date: "2026-11-04", owner: "user" as const, status: "done" as const, notes: undefined, title: "Moved" };
        const result = await store.writeSession(U1, s.id, 1, next, LATER);
        expect(result).toMatchObject({ ok: true, contentRevision: 2, session: { id: s.id, revision: 2, updatedAt: LATER, date: "2026-11-04", owner: "user", status: "done", title: "Moved" } });
        if (result.ok) expect(result.session.notes).toBeUndefined();
        expect((await store.getSession(U1, s.id))?.session.revision).toBe(2);
      });

      it("rejects a stale base without changing anything", async () => {
        const p = plan(1);
        const s = session(1, p.id);
        await store.createPlan(U1, p, [s], "h");
        await store.writeSession(U1, s.id, 1, { ...content(s), title: "first" }, LATER);
        expect(await store.writeSession(U1, s.id, 1, { ...content(s), title: "second" }, LATER)).toEqual({ ok: false, reason: "conflict", currentRevision: 2 });
        expect((await store.getSession(U1, s.id))?.session.title).toBe("first");
        expect((await store.getPlan(U1, p.id))?.plan.contentRevision).toBe(2);
      });

      it("moves the plan's contentRevision once when two writes race, and only one wins", async () => {
        const p = plan(1);
        const s = session(1, p.id);
        await store.createPlan(U1, p, [s], "h");
        const results = await Promise.all([store.writeSession(U1, s.id, 1, { ...content(s), title: "a" }, LATER), store.writeSession(U1, s.id, 1, { ...content(s), title: "b" }, LATER)]);
        expect(results.filter((r) => r.ok)).toHaveLength(1);
        expect((await store.getPlan(U1, p.id))?.plan.contentRevision).toBe(2);
      });

      it("does not write to another user's or a missing session", async () => {
        const p = plan(1);
        const s = session(1, p.id);
        await store.createPlan(U1, p, [s], "h");
        expect(await store.writeSession(U2, s.id, 1, content(s), LATER)).toEqual({ ok: false, reason: "not_found" });
        expect(await store.writeSession(U1, id(999), 1, content(s), LATER)).toEqual({ ok: false, reason: "not_found" });
      });

      it("tombstones a session, returns it, and moves the plan", async () => {
        const p = plan(1);
        const s = session(1, p.id);
        await store.createPlan(U1, p, [s], "h");
        const result = await store.deleteSession(U1, s.id, 1, LATER);
        expect(result).toMatchObject({ ok: true, contentRevision: 2, session: { id: s.id, revision: 2, deletedAt: LATER } });
        expect(await store.getSession(U1, s.id)).toBeUndefined();
        expect((await store.getPlan(U1, p.id))?.sessions).toEqual([]);
        expect(await store.deleteSession(U1, s.id, 2, LATER)).toEqual({ ok: false, reason: "not_found" });
      });

      it("needs the current revision to delete a session", async () => {
        const p = plan(1);
        const s = session(1, p.id);
        await store.createPlan(U1, p, [s], "h");
        expect(await store.deleteSession(U1, s.id, 3, LATER)).toEqual({ ok: false, reason: "conflict", currentRevision: 1 });
        expect(await store.deleteSession(U2, s.id, 1, LATER)).toEqual({ ok: false, reason: "not_found" });
      });
    });

    it("removes plans, weeks and sessions with the account", async () => {
      const p = plan(1);
      const s = session(1, p.id);
      await store.createPlan(U1, p, [s], "h");
      await auth.deleteUser(U1);
      expect(await store.getPlan(U1, p.id)).toBeUndefined();
      expect(await store.getSession(U1, s.id)).toBeUndefined();
      expect(await store.listPlans(U1, 50)).toEqual([]);
    });
  });
}
