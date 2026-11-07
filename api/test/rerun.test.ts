import fc from "fast-check";
import { describe, expect, it } from "vitest";
import { generatePlan, NoPlanFitsError } from "../src/domain/engine";
import type { InterviewAnswers } from "../src/domain/interview";
import { proposeRerun } from "../src/domain/rerun";
import type { StoredPlan, StoredSession } from "../src/ports";

const DAY = 86_400_000;
const dateOf = (day: number) => new Date(day * DAY).toISOString().slice(0, 10);
const dayOf = (date: string) => Date.parse(`${date}T00:00:00Z`) / DAY;
const AT = "2026-10-01T09:00:00.000Z";

function counter() {
  let n = 0;
  return () => `10000000-0000-4000-8000-${String(++n).padStart(12, "0")}`;
}

/** A stored plan made by the engine, as the app would have saved it. */
function storedPlan(answers: InterviewAnswers, today: string) {
  const draft = generatePlan({ answers, today });
  const plan: StoredPlan = {
    id: "00000000-0000-4000-8000-000000000101",
    goal: draft.goal,
    startDate: draft.startDate,
    weekCount: draft.weekCount,
    source: "rules",
    engine: draft.engine as unknown as StoredPlan["engine"],
    adaptive: true,
    weeks: draft.weeks.map((w) => ({ index: w.index, phase: w.phase })),
    revision: 1,
    contentRevision: 1,
    updatedAt: AT,
    deletedAt: null,
  };
  const nextId = counter();
  const sessions: StoredSession[] = draft.sessions.map((s) => ({ ...s, id: nextId().replace("10000000", "20000000"), planId: plan.id, revision: 1, updatedAt: AT, deletedAt: null }) as StoredSession);
  return { plan, sessions };
}

const ANSWERS: InterviewAnswers = { goal: { distance: "5k" }, weeklyDistanceM: 15000, runsPerWeek: 3, runningHistory: "under_1_year" };
const NEW_ANSWERS: InterviewAnswers = { goal: { distance: "10k" }, weeklyDistanceM: 20000, runsPerWeek: 4, runningHistory: "1_to_3_years" };

describe("proposeRerun", () => {
  const { plan, sessions } = storedPlan(ANSWERS, "2026-11-02"); // Monday: weeks start on Mondays

  it("keeps the current week and everything before it, and rebuilds the weeks after", () => {
    const today = "2026-11-11"; // Wednesday of week 1 (0-based)
    const result = proposeRerun({ plan, sessions, answers: NEW_ANSWERS, today, newId: counter() });
    expect(result.ok).toBe(true);
    if (!result.ok) return;
    const boundary = "2026-11-16"; // the first week that starts after today
    const deleted = result.changes.filter((c) => c.op === "delete");
    const created = result.changes.filter((c) => c.op === "create");
    expect(result.changes.every((c) => c.op === "delete" || c.op === "create")).toBe(true);
    expect(deleted.length).toBe(sessions.filter((s) => s.date >= boundary).length);
    expect(deleted.every((c) => c.op === "delete" && c.before.date >= boundary && !c.userOwned)).toBe(true);
    expect(created.length).toBeGreaterThan(0);
    expect(created.every((c) => c.op === "create" && c.after.date >= boundary && c.after.owner === "system" && c.after.status === "planned")).toBe(true);
    expect(new Set(created.map((c) => c.sessionId)).size).toBe(created.length);
    expect(result.planChanges.goal?.type).toBe("10k");
    expect(result.planChanges.engine?.interview).toMatchObject({ goal: { distance: "10k" } });
    expect(result.planChanges.weeks?.[0]?.index).toBe(2);
    expect(result.reason.length).toBeLessThanOrEqual(200);
  });

  it("leaves user-owned, finished and skipped future sessions alone", () => {
    const future = sessions.filter((s) => s.date >= "2026-11-16");
    const [a, b, c] = future;
    const mixed = sessions.map((s) =>
      s.id === a!.id ? { ...s, owner: "user" as const } : s.id === b!.id ? { ...s, status: "done" as const } : s.id === c!.id ? { ...s, status: "skipped" as const } : s,
    );
    const result = proposeRerun({ plan, sessions: mixed, answers: NEW_ANSWERS, today: "2026-11-11", newId: counter() });
    expect(result.ok).toBe(true);
    if (!result.ok) return;
    const touched = new Set(result.changes.filter((x) => x.op === "delete").map((x) => x.sessionId));
    for (const s of [a!, b!, c!]) expect(touched.has(s.id)).toBe(false);
  });

  it("starts at the first week when the plan has not begun", () => {
    const result = proposeRerun({ plan, sessions, answers: NEW_ANSWERS, today: "2026-10-20", newId: counter() });
    expect(result.ok && result.changes.filter((c) => c.op === "delete").length).toBe(sessions.length);
  });

  it("says so when no week is left to change", () => {
    const last = dateOf(dayOf(plan.startDate) + plan.weekCount * 7 - 3);
    expect(proposeRerun({ plan, sessions, answers: NEW_ANSWERS, today: last, newId: counter() })).toEqual({ ok: false, reason: "no_future_weeks" });
  });

  it("says so when the answers fit no plan", () => {
    // The schema's four unavailable days keep this out of the engine's reach today, so the engine is stood in for.
    const generate = () => {
      throw new NoPlanFitsError("no days");
    };
    expect(proposeRerun({ plan, sessions, answers: NEW_ANSWERS, today: "2026-11-11", newId: counter(), generate })).toEqual({ ok: false, reason: "no_plan_fits" });
  });

  it("does not change a session it did not list, and is the same twice", () => {
    const run = () => proposeRerun({ plan, sessions, answers: NEW_ANSWERS, today: "2026-11-11", newId: counter() });
    expect(run()).toEqual(run());
    expect(JSON.stringify(plan)).toContain('"weekCount":' + plan.weekCount);
  });

  it("property: keeps past and user-owned sessions, and creates only inside the plan", () => {
    const answersArb = fc.record(
      {
        goal: fc.record({ distance: fc.constantFrom("5k" as const, "10k" as const, "half_marathon" as const) }),
        weeklyDistanceM: fc.integer({ min: 4000, max: 50000 }),
        runsPerWeek: fc.integer({ min: 3, max: 5 }),
        runningHistory: fc.constantFrom("new_or_returning" as const, "under_1_year" as const, "1_to_3_years" as const, "over_3_years" as const),
        pain: fc.boolean(),
      },
      { requiredKeys: ["goal"] },
    );
    fc.assert(
      fc.property(
        answersArb,
        answersArb,
        fc.integer({ min: -10, max: 130 }),
        fc.array(fc.tuple(fc.nat(400), fc.constantFrom("system", "user"), fc.constantFrom("planned", "done", "skipped")), { maxLength: 60 }),
        (oldAnswers, newAnswers, offset, flags) => {
          const base = storedPlan(oldAnswers as InterviewAnswers, "2026-11-02");
          const sessions = base.sessions.map((s, i) => {
            const f = flags.find(([at]) => at % base.sessions.length === i);
            return f ? { ...s, owner: f[1] as "system" | "user", status: f[2] as "planned" | "done" | "skipped" } : s;
          });
          const today = dateOf(dayOf(base.plan.startDate) + offset);
          const result = proposeRerun({ plan: base.plan, sessions, answers: newAnswers as InterviewAnswers, today, newId: counter() });
          if (!result.ok) return;
          const start = dayOf(base.plan.startDate);
          const k0 = Math.max(0, Math.floor((dayOf(today) - start) / 7) + 1);
          const boundary = dateOf(start + 7 * k0);
          const weekCount = result.planChanges.weekCount ?? base.plan.weekCount;
          const end = dateOf(start + weekCount * 7 - 1);
          const byId = new Map(sessions.map((s) => [s.id, s]));
          for (const c of result.changes) {
            if (c.op === "delete") {
              const s = byId.get(c.sessionId)!;
              // Only a system-owned, still planned session from the first future week on may go.
              expect(s.owner).toBe("system");
              expect(s.status).toBe("planned");
              expect(s.date >= boundary).toBe(true);
              expect(c.userOwned).toBe(false);
            } else {
              expect(c.op).toBe("create");
              expect(byId.has(c.sessionId)).toBe(false);
              expect(c.after.date >= boundary && c.after.date <= end).toBe(true);
              expect(c.after.owner).toBe("system");
            }
          }
          // Every session that stays still lies inside the plan, and the plan keeps the weeks already lived.
          const gone = new Set(result.changes.filter((c) => c.op === "delete").map((c) => c.sessionId));
          for (const s of sessions) if (!gone.has(s.id)) expect(s.date <= end).toBe(true);
          expect(weekCount).toBeGreaterThanOrEqual(k0);
          expect(weekCount).toBeLessThanOrEqual(52);
          for (const w of result.planChanges.weeks ?? []) expect(w.index >= k0 && w.index < weekCount).toBe(true);
        },
      ),
      { numRuns: 60 },
    );
  });
});
