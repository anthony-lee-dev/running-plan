import fc from "fast-check";
import { describe, expect, it } from "vitest";
import {
  computeProgress,
  computeWeeklyReview,
  plannedDistanceM,
  plannedTimeSec,
  type ActivityInput,
  type CheckInInput,
  type InsightSession,
  type MatchInput,
  type PlanSpan,
  type ReviewSettings,
} from "../src/domain/insights";

const START = "2026-11-02"; // a Monday
const addDays = (date: string, days: number) => new Date(Date.parse(`${date}T00:00:00Z`) + days * 86_400_000).toISOString().slice(0, 10);

let n = 0;
const run = (offset: number, type: InsightSession["type"], metres: number, over: Partial<InsightSession> = {}): InsightSession => {
  n += 1;
  return { id: `s${n}`, date: addDays(START, offset), type, status: "planned", key: false, steps: [{ kind: "work", goal: { type: "distance", value: metres } }], ...over };
};
const tempo = (offset: number, over: Partial<InsightSession> = {}) =>
  run(offset, "tempo", 0, { title: "Tempo run", key: true, steps: [{ kind: "warmup", goal: { type: "distance", value: 1000 } }, { kind: "work", goal: { type: "distance", value: 4000 } }, { kind: "cooldown", goal: { type: "distance", value: 1000 } }], ...over });
const strength = (offset: number, over: Partial<InsightSession> = {}) =>
  run(offset, "strength", 0, { title: "Strength", steps: [1, 2, 3].map(() => ({ kind: "exercise" as const, sets: 2, reps: 10, restSec: 45 })), ...over });
const custom = (offset: number, over: Partial<InsightSession> = {}) =>
  run(offset, "custom", 0, { title: "Ride", steps: [], custom: { goal: { type: "time", value: 3600 } }, ...over });

const span: PlanSpan = { startDate: START, weekCount: 4, goalDate: "2027-01-10" };

/** The fixture of the hand-worked numbers below. Week 1: five sessions, week 2: two. */
function fixture() {
  const monEasy = run(0, "easy", 5000, { status: "done", title: "Easy run" });
  const tueStrength = strength(1, { status: "done" });
  const wedTempo = tempo(2, { status: "done" });
  const thuRide = custom(3, { status: "done" });
  const friEasy = run(4, "easy", 5000, { status: "skipped" });
  const sunLong = run(6, "long", 10_000, { key: true, title: "Long run" });
  const restDay = run(5, "rest", 0, { steps: [] });
  const w2Mon = run(7, "easy", 5000);
  const w2Tue = run(8, "easy", 5000);
  return { sessions: [monEasy, tueStrength, wedTempo, thuRide, friEasy, sunLong, restDay, w2Mon, w2Tue], monEasy, wedTempo, sunLong, tueStrength };
}
const activity = (id: string, distanceM: number | undefined, durationSec: number): ActivityInput => ({ id, distanceM, durationSec });

describe("planned distance and time", () => {
  it("sums distance goals and repeat groups, counts time goals at the fallback pace, and counts nothing for strength, custom or rest", () => {
    expect(plannedDistanceM(run(0, "easy", 5000))).toBe(5000);
    expect(plannedDistanceM(tempo(0))).toBe(6000);
    expect(plannedDistanceM(run(0, "intervals", 0, { steps: [{ kind: "repeat", count: 4, steps: [{ kind: "work", goal: { type: "distance", value: 400 } }, { kind: "recovery", goal: { type: "distance", value: 200 } }] }] }))).toBe(2400);
    expect(plannedDistanceM(run(0, "easy", 0, { steps: [{ kind: "work", goal: { type: "time", value: 2100 } }] }))).toBe(5000);
    expect(plannedDistanceM(strength(0))).toBe(0);
    expect(plannedDistanceM(custom(0))).toBe(0);
  });

  it("gives the time of a run at the fallback pace, a strength session by its sets, and a custom session by its goal", () => {
    expect(plannedTimeSec(run(0, "easy", 5000))).toBe(2100);
    expect(plannedTimeSec(run(0, "easy", 0, { steps: [{ kind: "work", goal: { type: "time", value: 1800 } }] }))).toBe(1800);
    expect(plannedTimeSec(strength(0))).toBe(450); // 3 exercises x 2 sets x (10 reps x 3 s + 45 s rest)
    expect(plannedTimeSec(custom(0))).toBe(3600);
    // A distance goal for cross-training says nothing about how long it takes (the running fallback pace would be wrong).
    expect(plannedTimeSec(custom(0, { custom: { goal: { type: "distance", value: 20_000 } } }))).toBe(0);
  });
});

describe("computeProgress", () => {
  const f = fixture();
  const matches: MatchInput[] = [{ sessionId: f.monEasy.id, activityId: "a1", status: "confirmed" }];
  const activities = [activity("a1", 5100, 1800)];
  const progress = (asOf: string, sessions = f.sessions, m = matches, a = activities, plan = span) => computeProgress({ plan, sessions, matches: m, activities: a, asOf });

  it("tallies adherence for the sessions due so far, leaving out rest days", () => {
    const p = progress("2026-11-10");
    expect(p.asOf).toBe("2026-11-10");
    // Due: week 1 (6 sessions), week 2 Monday (missed) and Tuesday (today, still to do).
    expect(p.adherence).toEqual({ due: 8, done: 4, skipped: 1, missed: 2 });
  });

  it("does not call a session missed until its day is over", () => {
    expect(progress("2026-11-09").adherence).toEqual({ due: 7, done: 4, skipped: 1, missed: 1 }); // w2 Monday is today
    expect(progress("2026-11-08").adherence).toEqual({ due: 6, done: 4, skipped: 1, missed: 0 }); // the long run is today
    expect(progress("2026-11-01").adherence).toEqual({ due: 0, done: 0, skipped: 0, missed: 0 });
  });

  it("counts a confirmed match as done even when the session was never marked done, but not a suggested one", () => {
    const sessions = [run(0, "easy", 5000)];
    const base = { plan: span, sessions, activities: [activity("a1", 5000, 1800)], asOf: "2026-11-05" };
    expect(computeProgress({ ...base, matches: [{ sessionId: sessions[0]!.id, activityId: "a1", status: "confirmed" }] }).adherence.done).toBe(1);
    expect(computeProgress({ ...base, matches: [{ sessionId: sessions[0]!.id, activityId: "a1", status: "suggested" }] }).adherence).toEqual({ due: 1, done: 0, skipped: 0, missed: 1 });
  });

  it("gives planned and actual running volume and training time a week, with strength and custom only in time", () => {
    const p = progress("2026-11-10");
    expect(p.weeks).toHaveLength(4);
    expect(p.weeks[0]).toEqual({
      index: 0,
      plannedDistanceM: 26_000, // 5 + 6 + 5 + 10 km
      actualDistanceM: 11_100, // the matched 5.1 km run plus the tempo marked done (as planned)
      plannedTimeSec: 14_970, // 2100 + 2520 + 2100 + 4200 running, 450 strength, 3600 ride
      actualTimeSec: 8370, // 1800 matched + 2520 + 450 + 3600
    });
    expect(p.weeks[1]).toMatchObject({ index: 1, plannedDistanceM: 10_000, actualDistanceM: 0, plannedTimeSec: 4200, actualTimeSec: 0 });
    expect(p.weeks[2]).toMatchObject({ plannedDistanceM: 0, actualDistanceM: 0 });
  });

  it("uses the activity's own distance and time for a matched session, whatever was planned", () => {
    const short = [{ sessionId: f.monEasy.id, activityId: "a1", status: "confirmed" as const }];
    const p = progress("2026-11-10", f.sessions, short, [activity("a1", undefined, 1500)]);
    expect(p.weeks[0]!.actualTimeSec).toBe(1500 + 2520 + 450 + 3600);
    expect(p.weeks[0]!.actualDistanceM).toBe(6000); // no distance on the activity: nothing counted for that run, the tempo as planned
  });

  it("tallies key sessions and strength sessions due so far", () => {
    const p = progress("2026-11-10");
    expect(p.keySessions).toEqual({ planned: 2, completed: 1 }); // the tempo was done, the long run missed
    expect(p.strengthSessions).toEqual({ planned: 1, completed: 1 });
    expect(progress("2026-11-01").keySessions).toEqual({ planned: 0, completed: 0 });
  });

  it("counts down to the goal date and says whether the plan is on track", () => {
    expect(progress("2026-11-10").goal).toEqual({ date: "2027-01-10", daysToGo: 61, onTrack: "behind" });
    const keen = fixture();
    for (const s of keen.sessions) if (s.status === "planned" && s.type !== "rest") s.status = "done";
    expect(progress("2026-11-10", keen.sessions).goal.onTrack).toBe("on_track");
  });

  it("says unknown with no goal date, with too little to judge, and counts down to zero on the day", () => {
    expect(progress("2026-11-10", f.sessions, matches, activities, { ...span, goalDate: undefined }).goal).toEqual({ onTrack: "unknown" });
    expect(progress("2026-11-03").goal.onTrack).toBe("unknown"); // two sessions so far
    expect(progress("2027-01-10").goal.daysToGo).toBe(0);
    expect(progress("2027-02-01").goal.daysToGo).toBeUndefined(); // the goal date has passed
  });

  it("rejects an asOf that is not a calendar date", () => {
    expect(() => progress("10/11/2026")).toThrow(RangeError);
  });

  it("leaves out sessions that are tombstoned or outside the plan weeks", () => {
    const stray = run(40, "easy", 9000, { status: "done" });
    const deleted = run(1, "easy", 9000, { status: "done", deletedAt: "2026-11-02T00:00:00Z" });
    const p = progress("2026-11-10", [...f.sessions, stray, deleted]);
    expect(p.adherence).toEqual({ due: 8, done: 4, skipped: 1, missed: 2 });
    expect(p.weeks[0]!.plannedDistanceM).toBe(26_000);
  });
});

describe("computeWeeklyReview", () => {
  const f = fixture();
  const matches: MatchInput[] = [{ sessionId: f.monEasy.id, activityId: "a1", status: "confirmed" }];
  const activities = [activity("a1", 5100, 1800)];
  const checkIns: CheckInInput[] = [
    { sessionId: f.monEasy.id, when: "after", feel: 4, effortFelt: 5, pain: false },
    { sessionId: f.wedTempo.id, when: "after", feel: 2, effortFelt: 8, pain: true },
    { sessionId: f.wedTempo.id, when: "before", feel: 3 },
  ];
  const review = (weekIndex: number, today: string, settings: ReviewSettings = { frequency: "weekly" }, extra: Partial<Parameters<typeof computeWeeklyReview>[0]> = {}) =>
    computeWeeklyReview({ plan: span, sessions: f.sessions, matches, activities, checkIns, weekIndex, today, review: settings, ...extra });

  it("summarises the week: sessions, distance, time, key sessions and check-ins", () => {
    const r = review(0, "2026-11-10");
    expect(r).toMatchObject({ weekIndex: 0, startDate: "2026-11-02", endDate: "2026-11-08" });
    expect(r.summary.sessions).toEqual({ planned: 6, done: 4, skipped: 1, missed: 1 });
    expect(r.summary.distance).toEqual({ plannedM: 26_000, actualM: 11_100 });
    expect(r.summary.time).toEqual({ plannedSec: 14_970, actualSec: 8370 });
    expect(r.summary.keySessions).toEqual([
      { sessionId: f.wedTempo.id, title: "Tempo run", outcome: "hit" },
      { sessionId: f.sunLong.id, title: "Long run", outcome: "missed" },
    ]);
    expect(r.summary.checkIns).toEqual({ count: 3, averageFeel: 3, averageEffortFelt: 6.5, painFlags: 1 });
  });

  it("marks a key session still ahead as upcoming and a skipped one as skipped", () => {
    const r = review(0, "2026-11-04");
    expect(r.summary.keySessions.find((k) => k.sessionId === f.sunLong.id)!.outcome).toBe("upcoming");
    const skipped = fixture();
    skipped.sunLong.status = "skipped";
    expect(review(0, "2026-11-10", { frequency: "weekly" }, { sessions: skipped.sessions }).summary.keySessions.at(-1)!.outcome).toBe("skipped");
  });

  it("leaves the averages out when there are no check-ins, and counts only this week's", () => {
    const none = review(0, "2026-11-10", { frequency: "weekly" }, { checkIns: [] });
    expect(none.summary.checkIns).toEqual({ count: 0, painFlags: 0 });
    const otherWeek = review(1, "2026-11-10");
    expect(otherWeek.summary.checkIns.count).toBe(0);
  });

  it("gives the dates of any plan week and rejects a week outside the plan", () => {
    expect(review(3, "2026-11-10")).toMatchObject({ startDate: "2026-11-23", endDate: "2026-11-29" });
    expect(() => review(4, "2026-11-10")).toThrow(RangeError);
    expect(() => review(-1, "2026-11-10")).toThrow(RangeError);
  });

  describe("whether it is due now", () => {
    it("weekly: from the last day of the plan week, for a week", () => {
      expect(review(0, "2026-11-07").due).toBe(false);
      expect(review(0, "2026-11-08").due).toBe(true);
      expect(review(0, "2026-11-14").due).toBe(true);
      expect(review(0, "2026-11-15").due).toBe(false);
      expect(review(1, "2026-11-10").due).toBe(false);
    });
    it("a chosen review day looks back: the first such weekday on or after the week's last day", () => {
      const wed: ReviewSettings = { frequency: "weekly", day: "wed" };
      expect(review(0, "2026-11-10", wed).due).toBe(false); // the week ended Sunday the 8th; Wednesday is the 11th
      expect(review(0, "2026-11-11", wed).due).toBe(true);
      expect(review(0, "2026-11-17", wed).due).toBe(true);
      expect(review(0, "2026-11-18", wed).due).toBe(false);
      const mon: ReviewSettings = { frequency: "weekly", day: "mon" };
      expect(review(0, "2026-11-08", mon).due).toBe(false); // not while the week is still being lived
      expect(review(0, "2026-11-09", mon).due).toBe(true);
      const sun: ReviewSettings = { frequency: "weekly", day: "sun" };
      expect(review(0, "2026-11-08", sun).due).toBe(true); // the last day itself
    });
    it("works from a plan that does not start on a Monday", () => {
      const wednesdayStart: PlanSpan = { startDate: "2026-11-04", weekCount: 4 }; // week 1 is Wed 4 to Tue 10 Nov
      const r = (today: string, review: ReviewSettings) => computeWeeklyReview({ plan: wednesdayStart, sessions: [], matches: [], activities: [], checkIns: [], weekIndex: 0, today, review });
      expect(r("2026-11-10", { frequency: "weekly" })).toMatchObject({ startDate: "2026-11-04", endDate: "2026-11-10", due: true });
      expect(r("2026-11-09", { frequency: "weekly" }).due).toBe(false);
      expect(r("2026-11-13", { frequency: "weekly", day: "fri" }).due).toBe(true); // Friday the 13th, after the Tuesday end
      expect(r("2026-11-12", { frequency: "weekly", day: "fri" }).due).toBe(false);
      expect(r("2026-11-10", { frequency: "weekly", day: "sun" }).due).toBe(false); // Sunday the 15th
      expect(r("2026-11-15", { frequency: "weekly", day: "sun" }).due).toBe(true);
    });
    it("weekly plus urgent surfaces the weekly review the same way", () => {
      const s: ReviewSettings = { frequency: "weekly_plus_urgent" };
      expect(review(0, "2026-11-07", s).due).toBe(false);
      expect(review(0, "2026-11-08", s).due).toBe(true);
      expect(review(0, "2026-11-14", s).due).toBe(true);
      expect(review(0, "2026-11-15", s).due).toBe(false);
    });
    it("after an import: once the week has something done, until a week after it ends, and on the review day too", () => {
      const s: ReviewSettings = { frequency: "after_import" };
      expect(review(0, "2026-11-03", s).due).toBe(true); // the Monday run is done
      expect(review(0, "2026-11-10", s).due).toBe(true);
      expect(review(0, "2026-11-14", s).due).toBe(true);
      expect(review(0, "2026-11-15", s).due).toBe(false);
      expect(review(0, "2026-11-01", s).due).toBe(false); // before the week begins
      expect(review(2, "2026-11-17", s).due).toBe(false); // nothing done that week...
      expect(review(2, "2026-11-22", s).due).toBe(true); // ...but the summary still appears on its review day
    });
    it("off: never", () => {
      expect(review(0, "2026-11-10", { frequency: "off" }).due).toBe(false);
      expect(review(0, "2026-11-08", { frequency: "off" }).due).toBe(false);
    });
    it("handles month ends and a leap day in the week", () => {
      const leap: PlanSpan = { startDate: "2028-02-26", weekCount: 2 }; // a Saturday; the week runs over 29 February
      const r = (weekIndex: number, today: string) => computeWeeklyReview({ plan: leap, sessions: [], matches: [], activities: [], checkIns: [], weekIndex, today, review: { frequency: "weekly" } });
      expect(r(0, "2028-03-03")).toMatchObject({ startDate: "2028-02-26", endDate: "2028-03-03", due: true });
      expect(r(1, "2028-03-09")).toMatchObject({ startDate: "2028-03-04", endDate: "2028-03-10", due: false });
      expect(r(1, "2028-03-10").due).toBe(true);
    });
  });

  describe("what counts", () => {
    it("leaves out tombstoned sessions, rest days and sessions outside the plan's weeks", () => {
      const extra = [run(2, "easy", 9000, { status: "done", deletedAt: "2026-11-01T00:00:00Z" }), run(99, "easy", 9000), run(1, "rest", 0, { key: true, steps: [] })];
      const r = review(0, "2026-11-10", { frequency: "weekly" }, { sessions: [...f.sessions, ...extra] });
      expect(r.summary.sessions).toEqual({ planned: 6, done: 4, skipped: 1, missed: 1 });
      expect(r.summary.distance.plannedM).toBe(26_000);
      expect(r.summary.keySessions).toHaveLength(2);
    });

    it("counts a skipped session with a confirmed match as done", () => {
      const target = f.sessions.find((s) => s.status === "skipped")!;
      const r = review(0, "2026-11-10", { frequency: "weekly" }, { matches: [...matches, { sessionId: target.id, activityId: "a2", status: "confirmed" }], activities: [...activities, activity("a2", 4800, 1700)] });
      expect(r.summary.sessions).toEqual({ planned: 6, done: 5, skipped: 0, missed: 1 });
    });

    it("falls back to what was planned when a confirmed match's activity is not there", () => {
      const r = review(0, "2026-11-10", { frequency: "weekly" }, { activities: [] });
      expect(r.summary.distance.actualM).toBe(5000 + 6000); // both done runs as planned
      expect(r.summary.time.actualSec).toBe(2100 + 2520 + 450 + 3600);
    });

    it("counts a session done early, ahead of today, in the week's actual volume", () => {
      const sessions = f.sessions.map((s) => (s.id === f.sunLong.id ? { ...s, status: "done" as const } : s));
      const r = review(0, "2026-11-04", { frequency: "weekly" }, { sessions });
      expect(r.summary.sessions.done).toBe(5);
      expect(r.summary.distance.actualM).toBe(11_100 + 10_000);
    });
  });
});

describe("insights: properties", () => {
  const sessionArb = fc
    .record({
      offset: fc.integer({ min: -3, max: 35 }),
      type: fc.constantFrom("easy" as const, "long" as const, "intervals" as const, "tempo" as const, "strength" as const, "rest" as const, "custom" as const),
      key: fc.boolean(),
      status: fc.constantFrom("planned" as const, "done" as const, "skipped" as const),
      metres: fc.integer({ min: 0, max: 30_000 }),
      matched: fc.boolean(),
      deleted: fc.boolean(),
    })
    .map(({ offset, type, key, status, metres, matched, deleted }) => ({ offset, type, key, status, metres, matched, deleted }));
  const inputArb = fc.record({ list: fc.array(sessionArb, { maxLength: 25 }), asOfOffset: fc.integer({ min: -5, max: 40 }) });

  const build = (i: { list: { offset: number; type: InsightSession["type"]; key: boolean; status: InsightSession["status"]; metres: number; matched: boolean; deleted: boolean }[]; asOfOffset: number }) => {
    const sessions: InsightSession[] = i.list.map((s, idx) => ({
      id: `q${idx}`,
      date: addDays(START, s.offset),
      type: s.type,
      status: s.status,
      key: s.key,
      steps: s.type === "strength" || s.type === "rest" || s.type === "custom" ? [] : [{ kind: "work" as const, goal: { type: "distance" as const, value: Math.max(100, s.metres) } }],
      ...(s.deleted ? { deletedAt: "2026-11-01T00:00:00Z" } : {}),
    }));
    const matches: MatchInput[] = i.list.flatMap((s, idx) => (s.matched ? [{ sessionId: `q${idx}`, activityId: `a${idx}`, status: "confirmed" as const }] : []));
    const activities = i.list.flatMap((s, idx) => (s.matched ? [activity(`a${idx}`, s.metres, 600 + s.metres / 4)] : []));
    return { sessions, matches, activities, asOf: addDays(START, i.asOfOffset) };
  };

  it("adherence adds up, nothing is negative, and actual volume comes only from done sessions", () => {
    fc.assert(
      fc.property(inputArb, (i) => {
        const b = build(i);
        const copy = structuredClone(b);
        const p = computeProgress({ plan: span, ...b });
        expect(computeProgress({ plan: span, ...b })).toEqual(p);
        expect(b).toEqual(copy);
        const a = p.adherence;
        for (const v of Object.values(a)) expect(v).toBeGreaterThanOrEqual(0);
        expect(a.done + a.skipped + a.missed).toBeLessThanOrEqual(a.due);
        // What is left over is exactly the planned, unmatched sessions dated today: due, not yet missed.
        const stillToday = b.sessions.filter((x) => !x.deletedAt && x.type !== "rest" && x.date === b.asOf && x.status === "planned" && !b.matches.some((m) => m.sessionId === x.id) && Math.floor((Date.parse(`${x.date}T00:00:00Z`) - Date.parse(`${span.startDate}T00:00:00Z`)) / 604_800_000) >= 0 && Math.floor((Date.parse(`${x.date}T00:00:00Z`) - Date.parse(`${span.startDate}T00:00:00Z`)) / 604_800_000) < span.weekCount).length;
        expect(a.due - (a.done + a.skipped + a.missed)).toBe(stillToday);
        expect(p.weeks).toHaveLength(span.weekCount);
        expect(p.keySessions.completed).toBeLessThanOrEqual(p.keySessions.planned);
        expect(p.strengthSessions.completed).toBeLessThanOrEqual(p.strengthSessions.planned);
        for (const w of p.weeks) {
          expect(w.plannedDistanceM).toBeGreaterThanOrEqual(0);
          expect(w.actualDistanceM).toBeGreaterThanOrEqual(0);
          // Actual volume comes only from done sessions.
          const anyDone = b.sessions.some((x) => !x.deletedAt && x.type !== "rest" && Math.floor((Date.parse(`${x.date}T00:00:00Z`) - Date.parse(`${span.startDate}T00:00:00Z`)) / 604_800_000) === w.index && (x.status === "done" || b.matches.some((m) => m.sessionId === x.id)));
          if (!anyDone) {
            expect(w.actualDistanceM).toBe(0);
            expect(w.actualTimeSec).toBe(0);
          }
        }
        expect(["on_track", "behind", "unknown"]).toContain(p.goal.onTrack);
      }),
      { numRuns: 300 },
    );
  });

  it("a week's review agrees with the plan-wide progress for that week", () => {
    fc.assert(
      fc.property(inputArb, fc.integer({ min: 0, max: 3 }), (i, week) => {
        const b = build(i);
        const p = computeProgress({ plan: span, ...b });
        const r = computeWeeklyReview({ plan: span, ...b, checkIns: [], weekIndex: week, today: b.asOf, review: { frequency: "weekly" } });
        expect(r.summary.distance).toEqual({ plannedM: p.weeks[week]!.plannedDistanceM, actualM: p.weeks[week]!.actualDistanceM });
        expect(r.summary.time).toEqual({ plannedSec: p.weeks[week]!.plannedTimeSec, actualSec: p.weeks[week]!.actualTimeSec });
        const s = r.summary.sessions;
        expect(s.done + s.skipped + s.missed).toBeLessThanOrEqual(s.planned);
      }),
      { numRuns: 300 },
    );
  });
});
