import fc from "fast-check";
import { describe, expect, it } from "vitest";
import { ENGINE_VERSION, generatePlan, type PlanDraft } from "../src/domain/engine";
import type { InterviewAnswers, Weekday } from "../src/domain/interview";
import { sessionDistanceM } from "../src/domain/validators";

const TODAY = "2026-11-02"; // a Monday
const WEEKDAYS: Weekday[] = ["mon", "tue", "wed", "thu", "fri", "sat", "sun"];

const answers = (over: Partial<InterviewAnswers> = {}): InterviewAnswers => ({ goal: { distance: "5k" }, ...over });
const gen = (over: Partial<InterviewAnswers> = {}, today = TODAY) => generatePlan({ answers: answers(over), today });

const weekdayOf = (date: string): Weekday => WEEKDAYS[(new Date(`${date}T00:00:00Z`).getUTCDay() + 6) % 7]!;
const dayNum = (date: string) => Date.parse(`${date}T00:00:00Z`) / 86_400_000;
const weekIndex = (draft: PlanDraft, date: string) => Math.floor((dayNum(date) - dayNum(draft.startDate)) / 7);
const volumes = (draft: PlanDraft) => {
  const v = new Array<number>(draft.weekCount).fill(0);
  for (const s of draft.sessions) v[weekIndex(draft, s.date)]! += sessionDistanceM(s);
  return v;
};
const codes = (items: { code: string }[]) => items.map((i) => i.code);

describe("generatePlan: shape", () => {
  it("returns a rules plan for the 5K preset with the engine version and the interview snapshot", () => {
    const draft = gen({ runsPerWeek: 3 });
    expect(draft).toMatchObject({ source: "rules", adaptive: true, goal: { type: "5k" }, startDate: TODAY });
    expect(draft.engine).toEqual({ presetId: "5k", version: ENGINE_VERSION, interview: answers({ runsPerWeek: 3 }) });
    expect(draft.weeks).toHaveLength(draft.weekCount);
    expect(draft.weeks.map((w) => w.index)).toEqual([...Array(draft.weekCount).keys()]);
  });

  it("is deterministic: the same inputs give the same draft", () => {
    const a = answers({ runsPerWeek: 4, weeklyDistanceM: 18000, recentResult: { distanceM: 5000, timeSec: 1650, date: "2026-10-20" }, pain: false });
    expect(generatePlan({ answers: a, today: TODAY })).toEqual(generatePlan({ answers: a, today: TODAY }));
  });

  it("does not change its input", () => {
    const a = answers({ unavailableDays: ["mon", "fri"], runsPerWeek: 3 });
    const copy = structuredClone(a);
    generatePlan({ answers: a, today: TODAY });
    expect(a).toEqual(copy);
  });

  it("only knows the 5K preset for now", () => {
    expect(() => generatePlan({ answers: { goal: { distance: "10k" } }, today: TODAY })).toThrow(/preset/i);
  });

  it("rejects an invalid today", () => {
    expect(() => generatePlan({ answers: answers(), today: "11/02/2026" })).toThrow(RangeError);
  });
});

describe("generatePlan: plan length (5K is 8 to 12 weeks)", () => {
  it.each([
    ["beginner", { runningHistory: "new_or_returning" as const }, 12],
    ["intermediate", { runningHistory: "1_to_3_years" as const }, 10],
    ["experienced", { runningHistory: "over_3_years" as const }, 8],
    ["no history given (conservative)", {}, 12],
  ])("uses the usual length for a %s runner with no goal date", (_n, over, weeks) => {
    expect(gen(over).weekCount).toBe(weeks);
  });

  it("fits a goal date inside the range so the last week holds the goal date", () => {
    const draft = gen({ goal: { distance: "5k", date: "2027-01-10" } }); // 10 weeks away
    expect(draft.weekCount).toBe(10);
    expect(draft.startDate).toBe(TODAY);
    expect(draft.goal.date).toBe("2027-01-10");
    expect(codes(draft.warnings)).not.toContain("later_goal_date");
  });

  it("starts the plan later when the goal date is more than 12 weeks away", () => {
    const draft = gen({ goal: { distance: "5k", date: "2027-04-04" } });
    expect(draft.weekCount).toBe(12);
    expect(dayNum(draft.startDate)).toBeGreaterThan(dayNum(TODAY));
    expect(dayNum("2027-04-04") - dayNum(draft.startDate)).toBeLessThan(12 * 7);
    expect(dayNum("2027-04-04") - dayNum(draft.startDate)).toBeGreaterThanOrEqual(11 * 7);
    expect(codes(draft.warnings)).toContain("goal_date_far");
  });

  it("never compresses the ramp for a goal date that is too soon: it keeps 8 weeks and suggests a later date", () => {
    const draft = gen({ goal: { distance: "5k", date: "2026-11-30" } });
    expect(draft.weekCount).toBe(8);
    const warning = draft.warnings.find((w) => w.code === "later_goal_date");
    expect(warning).toMatchObject({ severity: "caution", suggestedDate: "2026-12-27" });
  });
});

describe("generatePlan: weekly structure", () => {
  it.each([3, 4, 5])("has %i runs in every full week, on distinct days", (runs) => {
    const draft = gen({ runsPerWeek: runs });
    for (let w = 0; w < draft.weekCount; w++) {
      const dates = draft.sessions.filter((s) => weekIndex(draft, s.date) === w).map((s) => s.date);
      expect(dates).toHaveLength(runs);
      expect(new Set(dates).size).toBe(runs);
    }
  });

  it("defaults to three runs a week and says so", () => {
    const draft = gen();
    expect(draft.sessions.filter((s) => weekIndex(draft, s.date) === 0)).toHaveLength(3);
    expect(codes(draft.assumptions)).toContain("runs_per_week_default");
  });

  it("puts the long run on the preferred day and keeps unavailable days free", () => {
    const draft = gen({ runsPerWeek: 4, longRunDay: "sat", unavailableDays: ["mon", "wed"] });
    for (const s of draft.sessions) expect(["mon", "wed"]).not.toContain(weekdayOf(s.date));
    const longs = draft.sessions.filter((s) => s.type === "long");
    expect(longs).toHaveLength(draft.weekCount);
    for (const s of longs) expect(weekdayOf(s.date)).toBe("sat");
  });

  it("falls back to another day, and says so, when the preferred long run day is unavailable", () => {
    const draft = gen({ runsPerWeek: 3, longRunDay: "sun", unavailableDays: ["sun"] });
    const long = draft.sessions.find((s) => s.type === "long")!;
    expect(weekdayOf(long.date)).not.toBe("sun");
    expect(codes(draft.assumptions)).toContain("long_run_day_changed");
  });

  it("reduces the runs, and says so, when too few days are available", () => {
    const draft = gen({ runsPerWeek: 5, unavailableDays: ["mon", "tue", "wed", "thu"] });
    expect(draft.sessions.filter((s) => weekIndex(draft, s.date) === 0)).toHaveLength(3);
    expect(codes(draft.assumptions)).toContain("runs_reduced");
  });

  it("leaves an easy or rest day between hard sessions when the week allows it", () => {
    for (const runs of [3, 4, 5]) {
      const draft = gen({ runsPerWeek: runs });
      expect(codes(draft.warnings), `runs=${runs}`).not.toContain("hard_days_back_to_back");
      expect(codes(draft.warnings)).not.toContain("no_rest_day");
    }
  });

  it("marks long and quality sessions as key and owns every session as the system", () => {
    const draft = gen({ runsPerWeek: 4 });
    for (const s of draft.sessions) {
      expect(s.owner).toBe("system");
      expect(s.status).toBe("planned");
      expect(Boolean(s.key)).toBe(s.type === "long" || s.type === "tempo" || s.type === "intervals");
    }
  });
});

describe("generatePlan: load (conservative start, bounded growth, down weeks, taper)", () => {
  it.each([
    ["beginner with 12 km a week", { weeklyDistanceM: 12000, runningHistory: "new_or_returning" as const }],
    ["intermediate with 25 km", { weeklyDistanceM: 25000, runningHistory: "1_to_3_years" as const }],
    ["experienced with 40 km", { weeklyDistanceM: 40000, runningHistory: "over_3_years" as const, runsPerWeek: 5 }],
  ])("%s: starts below the baseline and ramps within the caps", (_n, over) => {
    const draft = gen(over);
    const v = volumes(draft);
    expect(v[0]!).toBeLessThan(over.weeklyDistanceM);
    expect(codes(draft.warnings)).not.toContain("first_week_above_baseline");
    expect(codes(draft.warnings)).not.toContain("weekly_growth_too_high");
    expect(codes(draft.warnings)).not.toContain("no_down_week");
    expect(codes(draft.warnings)).not.toContain("long_run_share_high");
  });

  it("has a down week every fourth week and a taper before the end", () => {
    const draft = gen({ weeklyDistanceM: 20000, runningHistory: "1_to_3_years" });
    const v = volumes(draft);
    expect(v[3]!).toBeLessThan(v[2]!);
    expect(v[draft.weekCount - 1]!).toBeLessThanOrEqual(0.85 * Math.max(...v));
    expect(v[draft.weekCount - 2]!).toBeLessThan(Math.max(...v));
  });

  it("assumes a baseline by tier when none is given, and says so", () => {
    const draft = gen({ runningHistory: "over_3_years" });
    expect(codes(draft.assumptions)).toContain("baseline_default");
    expect(volumes(draft)[0]!).toBeLessThan(30000);
  });

  it("takes the baseline the user gave and does not assume one", () => {
    expect(codes(gen({ weeklyDistanceM: 15000 }).assumptions)).not.toContain("baseline_default");
  });

  it("warns when a tiny baseline forces a first week above it", () => {
    expect(codes(gen({ weeklyDistanceM: 2000 }).warnings)).toContain("first_week_above_baseline");
  });
});

describe("generatePlan: the cautious variant for pain", () => {
  it("ramps more slowly, has no intervals, and tells the user to see a professional", () => {
    const normal = gen({ weeklyDistanceM: 20000, runningHistory: "1_to_3_years" });
    const cautious = gen({ weeklyDistanceM: 20000, runningHistory: "1_to_3_years", pain: true });
    expect(cautious.sessions.some((s) => s.type === "intervals")).toBe(false);
    expect(Math.max(...volumes(cautious))).toBeLessThan(Math.max(...volumes(normal)));
    const warning = cautious.warnings.find((w) => w.code === "pain_flag");
    expect(warning).toMatchObject({ severity: "caution" });
    expect(warning!.message).toMatch(/qualified professional/i);
    expect(warning!.message).not.toMatch(/diagnos|treat/i);
    expect(codes(normal.warnings)).not.toContain("pain_flag");
  });
});

describe("generatePlan: targets and paces", () => {
  const firstWith = (draft: PlanDraft, type: string) => draft.sessions.find((s) => s.type === type)!;
  const targetsOf = (s: PlanDraft["sessions"][number]) =>
    s.steps.flatMap((step) => (step.kind === "repeat" ? step.steps : [step])).map((step) => step.target.type);

  it("uses effort targets and prompts calibration when there is no recent result", () => {
    const draft = gen({ runsPerWeek: 4 });
    for (const s of draft.sessions) for (const t of targetsOf(s)) expect(t).toBe("effort");
    expect(codes(draft.assumptions)).toContain("paces_effort_only");
  });

  it("uses pace ranges from a recent race, slow side for easy running, and says what they are based on", () => {
    const draft = gen({ runsPerWeek: 4, recentResult: { distanceM: 5000, timeSec: 1650, date: "2026-10-20" } });
    const easy = firstWith(draft, "easy").steps[0]!;
    expect(easy).toMatchObject({ target: { type: "pace", range: { minSecPerKm: 396, maxSecPerKm: 446 } } });
    const long = firstWith(draft, "long").steps[0]!;
    expect(long).toMatchObject({ target: { type: "pace", range: { minSecPerKm: 380, maxSecPerKm: 429 } } });
    const basedOn = draft.assumptions.find((a) => a.code === "paces_derived");
    expect(basedOn?.message).toContain("5K in 27:30 on 2026-10-20");
  });

  it("shows heart rate only when the user gave max heart rate or zones", () => {
    const without = gen({ targetDisplay: "heart_rate" });
    expect(targetsOf(firstWith(without, "easy"))).toEqual(["effort"]);
    const withMax = gen({ targetDisplay: "heart_rate", heartRate: { maxBpm: 190 } });
    expect(firstWith(withMax, "easy").steps[0]).toMatchObject({ target: { type: "heart_rate", range: { minBpm: 114, maxBpm: 143 } } });
  });

  it("builds intervals as warm-up, a repeat group, and cool-down", () => {
    const draft = gen({ runsPerWeek: 3, runningHistory: "1_to_3_years", weeklyDistanceM: 25000 });
    const intervals = draft.sessions.find((s) => s.type === "intervals")!;
    expect(intervals.steps[0]).toMatchObject({ kind: "warmup" });
    expect(intervals.steps.some((s) => s.kind === "repeat")).toBe(true);
    expect(intervals.steps.at(-1)).toMatchObject({ kind: "cooldown" });
  });
});

describe("generatePlan: goal date, guards and limits", () => {
  it("ends the plan on the goal date when it is not a whole number of weeks away", () => {
    const draft = gen({ goal: { distance: "5k", date: "2026-12-28" } }); // 57 days: 8 whole weeks, one day over
    expect(draft.weekCount).toBe(8);
    expect(draft.startDate).toBe("2026-11-03");
    expect(codes(draft.assumptions)).toContain("start_date_aligned");
    const last = draft.sessions.map((s) => s.date).sort().at(-1)!;
    expect(last <= "2026-12-28").toBe(true);
    expect(dayNum(draft.startDate) + draft.weekCount * 7 - 1).toBe(dayNum("2026-12-28"));
  });

  it("drops a goal date that has passed, and suggests a later one", () => {
    const draft = gen({ goal: { distance: "5k", date: "2026-10-01" } });
    expect(draft.goal.date).toBeUndefined();
    expect(draft.warnings.find((w) => w.code === "later_goal_date")?.suggestedDate).toBeDefined();
    expect(draft.startDate).toBe(TODAY);
  });

  it("treats a goal date of today as too soon, not as an error", () => {
    const draft = gen({ goal: { distance: "5k", date: TODAY } });
    expect(draft.weekCount).toBe(8);
    expect(codes(draft.warnings)).toContain("later_goal_date");
  });

  it.each([
    ["a pace faster than the spec allows (120 s per km)", { distanceM: 1000, timeSec: 120 }],
    ["a pace slower than the spec allows (1300 s per km)", { distanceM: 1000, timeSec: 1300 }],
    ["a result dated after today", { distanceM: 5000, timeSec: 1650, date: "2027-01-01" }],
  ])("ignores %s instead of failing, and falls back to effort targets", (_n, recentResult) => {
    const draft = gen({ recentResult });
    expect(codes(draft.assumptions)).toContain("result_ignored");
    expect(codes(draft.assumptions)).toContain("paces_effort_only");
    for (const s of draft.sessions) for (const step of s.steps) expect((step.kind === "repeat" ? step.steps[0]! : step).target.type).toBe("effort");
  });

  it("refuses a week with fewer than three days to run on, rather than producing nonsense", () => {
    expect(() => gen({ unavailableDays: [...WEEKDAYS] })).toThrow(RangeError);
    expect(() => gen({ unavailableDays: ["mon", "tue", "wed", "thu", "fri"] })).toThrow(RangeError);
    expect(() => gen({ unavailableDays: ["mon", "mon", "mon", "mon", "mon"] })).not.toThrow(); // repeats are one day
  });

  it("keeps a huge baseline inside what a 5K plan builds to, with no run longer than its limit", () => {
    for (const runs of [3, 4, 5]) {
      const draft = gen({ weeklyDistanceM: 200_000, runningHistory: "over_3_years", runsPerWeek: runs });
      expect(codes(draft.assumptions)).toContain("weekly_distance_capped");
      for (const s of draft.sessions) {
        const limit = s.type === "long" ? 14_000 : s.type === "easy" ? 10_000 : 12_000;
        expect(sessionDistanceM(s as never), `${runs} runs, ${s.type} on ${s.date}`).toBeLessThanOrEqual(limit);
      }
      expect(Math.max(...volumes(draft))).toBeLessThanOrEqual(48_000);
    }
  });

  it("gives every hard session an easy or rest day on each side when the week allows it", () => {
    const cases: Partial<InterviewAnswers>[] = [
      { runsPerWeek: 5, unavailableDays: ["mon"], longRunDay: "wed" },
      { runsPerWeek: 5, unavailableDays: ["tue", "sat"], longRunDay: "sun" },
      { runsPerWeek: 4, unavailableDays: ["mon", "tue"], longRunDay: "sat" },
    ];
    for (const c of cases) expect(codes(gen(c).warnings), JSON.stringify(c)).not.toContain("hard_days_back_to_back");
  });

  it("drops the second hard session to an easy run when no day has room for it", () => {
    const draft = gen({ runsPerWeek: 5, unavailableDays: ["tue", "wed"], longRunDay: "sun", runningHistory: "1_to_3_years", weeklyDistanceM: 25000 });
    // Free days are Mon, Thu, Fri, Sat, Sun: after the long run (Sun) and a Thursday session, no day has room.
    const hardPerWeek = draft.sessions.filter((s) => weekIndex(draft, s.date) === 5 && s.key).length;
    expect(hardPerWeek).toBeLessThanOrEqual(2);
    expect(codes(draft.warnings)).not.toContain("hard_days_back_to_back");
  });
});

describe("generatePlan: what it leaves out for now", () => {
  it("says strength sessions are not in this version yet when the user asked for them", () => {
    const draft = gen({ strength: { enabled: true, equipment: "dumbbells" } });
    expect(draft.sessions.some((s) => (s.type as string) === "strength")).toBe(false);
    expect(codes(draft.assumptions)).toContain("strength_not_available");
  });
});

// ---- Properties over random interview answers ----

const weekdayArb = fc.constantFrom(...WEEKDAYS);
const addDays = (date: string, days: number) => new Date(Date.parse(`${date}T00:00:00Z`) + days * 86_400_000).toISOString().slice(0, 10);

/** Everything the spec allows, including results that are not real runs and dates in the past or future. */
const answersArb = fc
  .record(
    {
      weeklyDistanceM: fc.integer({ min: 0, max: 200_000 }),
      longestRunM: fc.integer({ min: 0, max: 50_000 }),
      runningHistory: fc.constantFrom("new_or_returning" as const, "under_1_year" as const, "1_to_3_years" as const, "over_3_years" as const),
      runsPerWeek: fc.integer({ min: 3, max: 5 }),
      unavailableDays: fc.uniqueArray(weekdayArb, { maxLength: 4 }),
      longRunDay: weekdayArb,
      pain: fc.boolean(),
      targetDisplay: fc.constantFrom("pace" as const, "heart_rate" as const, "effort" as const),
      heartRate: fc.record({ maxBpm: fc.integer({ min: 100, max: 230 }) }),
      recentResult: fc.record({ distanceM: fc.integer({ min: 1000, max: 42_195 }), timeSec: fc.integer({ min: 120, max: 28_800 }), date: fc.option(fc.integer({ min: -90, max: 30 }).map((d) => addDays(TODAY, d)), { nil: undefined }) }, { requiredKeys: ["distanceM", "timeSec"] }),
    },
    { requiredKeys: [] },
  )
  .map((a): InterviewAnswers => ({ goal: { distance: "5k" }, ...a }));
const todayArb = fc.integer({ min: 0, max: 400 }).map((d) => addDays("2026-01-01", d));
/** A goal date from 30 days ago to 400 days ahead, or none. */
const goalOffsetArb = fc.option(fc.integer({ min: -30, max: 400 }), { nil: undefined });

describe("generatePlan: properties over random interview answers", () => {
  const run = (a: InterviewAnswers, today: string, goalOffset?: number) =>
    generatePlan({ answers: goalOffset === undefined ? a : { ...a, goal: { distance: "5k", date: addDays(today, goalOffset) } }, today });

  it("always yields a valid plan: 8 to 12 weeks, one session a day, inside the plan, unavailable days free, no run past its limit", () => {
    fc.assert(
      fc.property(answersArb, todayArb, goalOffsetArb, (a, today, goalOffset) => {
        const draft = run(a, today, goalOffset);
        expect(draft.weekCount).toBeGreaterThanOrEqual(8);
        expect(draft.weekCount).toBeLessThanOrEqual(12);
        expect(draft.assumptions.length).toBeLessThanOrEqual(50);
        expect(draft.warnings.length).toBeLessThanOrEqual(100);
        const days = new Set<string>();
        for (const s of draft.sessions) {
          const w = weekIndex(draft, s.date);
          expect(w).toBeGreaterThanOrEqual(0);
          expect(w).toBeLessThan(draft.weekCount);
          expect(days.has(s.date)).toBe(false);
          days.add(s.date);
          expect(a.unavailableDays ?? []).not.toContain(weekdayOf(s.date));
          expect(sessionDistanceM(s as never)).toBeLessThanOrEqual(s.type === "long" ? 14_000 : s.type === "easy" ? 10_000 : 12_000);
        }
        for (const text of [...draft.assumptions, ...draft.warnings]) expect(text.message.length).toBeLessThanOrEqual(500);
      }),
      { numRuns: 300 },
    );
  });

  it("starts below the stated baseline whenever the baseline allows a sensible first week", () => {
    fc.assert(
      fc.property(answersArb, todayArb, (a, today) => {
        const draft = run(a, today);
        const runs = draft.sessions.filter((s) => weekIndex(draft, s.date) === 0).length;
        const floor = Math.max(5000, runs * 1800);
        fc.pre(a.weeklyDistanceM !== undefined && a.weeklyDistanceM * (a.pain ? 0.7 : 0.85) >= floor);
        expect(volumes(draft)[0]!).toBeLessThanOrEqual(a.weeklyDistanceM!);
        expect(codes(draft.warnings)).not.toContain("first_week_above_baseline");
      }),
      { numRuns: 300 },
    );
  });

  it("grows no faster than the engine's own steps, has down weeks, tapers, and never exceeds the tier cap", () => {
    fc.assert(
      fc.property(answersArb, todayArb, (a, today) => {
        const draft = run(a, today);
        const v = volumes(draft);
        const history = a.runningHistory;
        const tierCap = history === "over_3_years" ? 48_000 : history === "1_to_3_years" ? 36_000 : 24_000;
        const downEvery = a.pain ? 3 : 4;
        for (let w = 1; w < v.length - 2; w++) {
          // A step is at most one growth step (8%) or the return from a down week (1 / 0.88), plus rounding.
          expect(v[w]!, `week ${w + 1}: ${v[w - 1]} to ${v[w]}`).toBeLessThanOrEqual(v[w - 1]! * 1.14 + 300);
          if ((w + 1) % downEvery === 0) expect(v[w]!, `down week ${w + 1}`).toBeLessThanOrEqual(v[w - 1]!);
        }
        const peak = Math.max(...v.slice(0, -2));
        expect(v.at(-2)!).toBeLessThanOrEqual(0.8 * peak + 600);
        expect(v.at(-1)!).toBeLessThanOrEqual(0.6 * peak + 600);
        for (const week of v.slice(0, -2)) expect(week).toBeLessThanOrEqual(Math.max(tierCap, v[0]!) + 300);
        expect(codes(draft.warnings)).not.toContain("weekly_growth_too_high");
        expect(codes(draft.warnings)).not.toContain("no_down_week");
        expect(codes(draft.warnings)).not.toContain("no_taper");
      }),
      { numRuns: 300 },
    );
  });

  it("keeps the long run at or below half of the week's running", () => {
    fc.assert(
      fc.property(answersArb, todayArb, (a, today) => {
        const draft = run(a, today);
        const v = volumes(draft);
        for (const s of draft.sessions.filter((x) => x.type === "long")) {
          expect(sessionDistanceM(s as never)).toBeLessThanOrEqual(v[weekIndex(draft, s.date)]! * 0.5);
        }
      }),
      { numRuns: 200 },
    );
  });

  it("ends the plan on the goal date, with nothing scheduled after it, when the date is far enough away", () => {
    fc.assert(
      fc.property(answersArb, todayArb, fc.integer({ min: 55, max: 400 }), (a, today, offset) => {
        const goal = addDays(today, offset);
        const draft = generatePlan({ answers: { ...a, goal: { distance: "5k", date: goal } }, today });
        expect(draft.goal.date).toBe(goal);
        expect(dayNum(draft.startDate)).toBeGreaterThanOrEqual(dayNum(today));
        expect(dayNum(draft.startDate) + draft.weekCount * 7 - 1).toBe(dayNum(goal));
        for (const s of draft.sessions) expect(s.date <= goal).toBe(true);
      }),
      { numRuns: 200 },
    );
  });

  it("never leaves back-to-back hard days when at most two days are unavailable", () => {
    fc.assert(
      fc.property(answersArb.filter((a) => (a.unavailableDays?.length ?? 0) <= 2), todayArb, (a, today) => {
        expect(codes(run(a, today).warnings)).not.toContain("hard_days_back_to_back");
      }),
      { numRuns: 300 },
    );
  });

  it("is cautious with pain: no intervals, and a pain warning", () => {
    fc.assert(
      fc.property(answersArb, todayArb, (a, today) => {
        const draft = run({ ...a, pain: true }, today);
        expect(draft.sessions.some((s) => s.type === "intervals")).toBe(false);
        expect(codes(draft.warnings)).toContain("pain_flag");
      }),
      { numRuns: 100 },
    );
  });

  it("is deterministic for any input and does not change it", () => {
    fc.assert(
      fc.property(answersArb, todayArb, goalOffsetArb, (a, today, goalOffset) => {
        const copy = structuredClone(a);
        expect(run(a, today, goalOffset)).toEqual(run(a, today, goalOffset));
        expect(a).toEqual(copy);
      }),
      { numRuns: 100 },
    );
  });
});
