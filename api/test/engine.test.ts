import fc from "fast-check";
import { describe, expect, it } from "vitest";
import { ENGINE_VERSION, generatePlan, type PlanDraft } from "../src/domain/engine";
import type { InterviewAnswers, Weekday } from "../src/domain/interview";
import { sessionDistanceM } from "../src/domain/validators";
import { exerciseById } from "../src/domain/strength";
import { PRESETS } from "../src/domain/presets";

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

  it("picks the preset from the goal distance, or from an explicit preset id, and refuses an unknown one", () => {
    expect(generatePlan({ answers: { goal: { distance: "10k" } }, today: TODAY }).engine.presetId).toBe("10k");
    expect(generatePlan({ answers: { goal: { distance: "half_marathon" } }, today: TODAY }).goal.type).toBe("half_marathon");
    expect(generatePlan({ answers: { goal: { distance: "5k" } }, today: TODAY, presetId: "10k" }).engine.presetId).toBe("10k");
    expect(() => generatePlan({ answers: answers(), today: TODAY, presetId: "marathon" })).toThrow(/preset/i);
  });

  it("rejects an invalid today", () => {
    expect(() => generatePlan({ answers: answers(), today: "11/02/2026" })).toThrow(RangeError);
  });
});

describe("generatePlan: a start date in the past (issue #97)", () => {
  const past = "2026-10-20"; // a Tuesday, two weeks before TODAY

  it("starts the plan on the date it is given, with sessions dated from there", () => {
    const draft = gen({ runsPerWeek: 3 }, past);
    expect(draft.startDate).toBe(past);
    expect(draft.sessions.every((s) => s.date >= past)).toBe(true);
    expect(draft.sessions.some((s) => s.date < TODAY)).toBe(true);
    expect(draft.sessions.map((s) => s.date).sort()[0]! >= past).toBe(true);
  });

  it("the first week begins on the start date's weekday and keeps its week count", () => {
    const back = gen({ runsPerWeek: 3 }, past);
    const now = gen({ runsPerWeek: 3 }, TODAY);
    expect(back.weekCount).toBe(now.weekCount);
    expect(weekdayOf(back.startDate)).toBe("tue");
    expect(back.sessions.every((s) => weekIndex(back, s.date) >= 0 && weekIndex(back, s.date) < back.weekCount)).toBe(true);
  });

  it("keeps the goal date alignment: the plan still ends on the goal date", () => {
    const draft = gen({ goal: { distance: "5k", date: "2026-12-20" }, runsPerWeek: 3 }, past);
    expect(draft.goal.date).toBe("2026-12-20");
    expect(dayNum(draft.startDate) + draft.weekCount * 7 - 1).toBe(dayNum("2026-12-20"));
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

  it("adds base weeks, and says so, when the goal date is 13 to 16 weeks away", () => {
    const draft = gen({ goal: { distance: "5k", date: "2027-02-14" }, weeklyDistanceM: 20000, runningHistory: "1_to_3_years" }); // 15 weeks
    expect(draft.weekCount).toBe(15);
    expect(draft.startDate).toBe(TODAY);
    expect(draft.weeks.slice(0, 3).map((w) => w.phase)).toEqual(["base", "base", "base"]);
    const v = volumes(draft);
    expect(v[1]).toBe(v[0]); // the extra weeks hold the conservative start, no growth yet
    expect(v[2]).toBe(v[0]);
    expect(v[3]!).toBeLessThanOrEqual(v[2]! * 1.14 + 300);
    expect(codes(draft.warnings)).toContain("base_phase_added");
    expect(codes(draft.warnings)).not.toContain("goal_date_far");
    expect(codes(draft.warnings)).not.toContain("weekly_growth_too_high");
    expect(codes(draft.warnings)).not.toContain("no_taper");
  });

  it("starts a few days later, and says so, when the goal date leaves a partial week", () => {
    const draft = gen({ goal: { distance: "5k", date: "2027-02-17" } }); // 108 days: 15 whole weeks and 3 days over
    expect(draft.weekCount).toBe(15);
    expect(draft.startDate).toBe("2026-11-05");
    expect(dayNum(draft.startDate) + 15 * 7 - 1).toBe(dayNum("2027-02-17"));
    expect(codes(draft.assumptions)).toContain("start_date_aligned");
    expect(codes(draft.warnings)).toContain("base_phase_added");
  });

  it("adds no base weeks for a goal date exactly 12 weeks away", () => {
    const draft = gen({ goal: { distance: "5k", date: "2027-01-24" } });
    expect(draft.weekCount).toBe(12);
    expect(codes(draft.warnings)).not.toContain("base_phase_added");
  });

  it("starts the plan later, with the full 16 weeks, when the goal date is further away", () => {
    const draft = gen({ goal: { distance: "5k", date: "2027-04-04" } });
    expect(draft.weekCount).toBe(16);
    expect(dayNum(draft.startDate)).toBeGreaterThan(dayNum(TODAY));
    expect(dayNum(draft.startDate) + 16 * 7 - 1).toBe(dayNum("2027-04-04"));
    expect(codes(draft.warnings)).toContain("goal_date_far");
    expect(draft.warnings.find((w) => w.code === "goal_date_far")?.message).toContain(draft.startDate);
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

describe("generatePlan: a baseline far below the goal (design 6.5)", () => {
  it("suggests a later date, and a gentler start, when the runner is barely running yet", () => {
    for (const weeklyDistanceM of [0, 2000, 3999]) {
      const draft = gen({ weeklyDistanceM });
      const w = draft.warnings.find((x) => x.code === "baseline_far_below_goal");
      expect(w, `baseline ${weeklyDistanceM}`).toMatchObject({ severity: "caution" });
      expect(w!.message).toMatch(/run-walk|walk/i);
      expect(w!.suggestedDate).toBeDefined();
      expect(dayNum(w!.suggestedDate!)).toBeGreaterThan(dayNum(draft.startDate) + draft.weekCount * 7 - 1);
    }
  });

  it("says nothing for a runner who already runs a few kilometres a week, or did not say", () => {
    expect(codes(gen({ weeklyDistanceM: 4000 }).warnings)).not.toContain("baseline_far_below_goal");
    expect(codes(gen({ weeklyDistanceM: 15000 }).warnings)).not.toContain("baseline_far_below_goal");
    expect(codes(gen().warnings)).not.toContain("baseline_far_below_goal");
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
    s.steps.flatMap((step) => (step.kind === "repeat" ? step.steps : step.kind === "exercise" ? [] : [step])).map((step) => step.target.type);

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
    for (const s of draft.sessions.filter((x) => x.type !== "strength")) for (const step of s.steps) expect((step.kind === "repeat" ? step.steps[0]! : (step as Exclude<typeof step, { kind: "exercise" }>)).target.type).toBe("effort");
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

describe("generatePlan: the 10K and half marathon presets (design 6.2)", () => {
  const ten = (over: Partial<InterviewAnswers> = {}) => gen({ goal: { distance: "10k" }, ...over });
  const half = (over: Partial<InterviewAnswers> = {}) => gen({ goal: { distance: "half_marathon" }, ...over });

  it.each([
    ["10K", "10k", { beginner: 12, intermediate: 10, experienced: 8 }],
    ["half marathon", "half_marathon", { beginner: 16, intermediate: 14, experienced: 12 }],
  ] as const)("%s: the usual length by tier", (_name, distance, lengths) => {
    expect(gen({ goal: { distance }, runningHistory: "new_or_returning" }).weekCount).toBe(lengths.beginner);
    expect(gen({ goal: { distance }, runningHistory: "1_to_3_years" }).weekCount).toBe(lengths.intermediate);
    expect(gen({ goal: { distance }, runningHistory: "over_3_years" }).weekCount).toBe(lengths.experienced);
  });

  it("fits a goal date inside each preset's range, and keeps the minimum for one that is too soon", () => {
    expect(ten({ goal: { distance: "10k", date: "2027-02-07" } }).weekCount).toBe(14); // 14 weeks away
    expect(half({ goal: { distance: "half_marathon", date: "2027-02-21" } }).weekCount).toBe(16);
    const soon = half({ goal: { distance: "half_marathon", date: "2026-12-06" } });
    expect(soon.weekCount).toBe(10);
    expect(soon.warnings.find((w) => w.code === "later_goal_date")?.message).toContain("half marathon");
  });

  it("adds base weeks for a far goal date beyond each preset's own maximum", () => {
    const draft = half({ goal: { distance: "half_marathon", date: "2027-03-14" } }); // 19 weeks
    expect(draft.weekCount).toBe(19);
    expect(codes(draft.warnings)).toContain("base_phase_added");
    expect(codes(draft.warnings)).not.toContain("goal_date_far");
  });

  it("lets a high-mileage runner build a larger peak week for a longer race, within each preset's own limits", () => {
    // A baseline high enough that each preset's own cap is what limits the week.
    const base = { runningHistory: "1_to_3_years" as const, weeklyDistanceM: 60_000, runsPerWeek: 5 as const };
    const peak = (d: PlanDraft) => Math.max(...volumes(d));
    const five = gen(base);
    const tenK = ten(base);
    const halfM = half(base);
    expect(peak(five)).toBeLessThanOrEqual(36_000);
    expect(peak(tenK)).toBeGreaterThan(peak(five));
    expect(peak(tenK)).toBeLessThanOrEqual(45_000);
    expect(peak(halfM)).toBeGreaterThan(peak(tenK));
    expect(peak(halfM)).toBeLessThanOrEqual(55_000);
    for (const [draft, long] of [[five, 14_000], [tenK, 18_000], [halfM, 24_000]] as const) {
      for (const s of draft.sessions.filter((x) => x.type === "long")) expect(sessionDistanceM(s as never)).toBeLessThanOrEqual(long);
    }
  });

  it("uses longer interval reps for the 10K, and tempo as the main quality session for the half", () => {
    const tenK = ten({ runningHistory: "1_to_3_years", weeklyDistanceM: 25_000 });
    const reps = tenK.sessions.flatMap((s) => s.steps).flatMap((step) => (step.kind === "repeat" ? [step.steps[0]!.goal.value] : []));
    expect(Math.min(...reps)).toBeGreaterThanOrEqual(800);
    const halfM = half({ runningHistory: "1_to_3_years", weeklyDistanceM: 30_000, runsPerWeek: 4 });
    expect(halfM.sessions.some((s) => s.type === "intervals")).toBe(false);
    expect(halfM.sessions.filter((s) => s.type === "tempo").length).toBeGreaterThanOrEqual(halfM.weekCount - 2);
  });

  it("offers intervals in the half marathon only as the second quality session of a five-run week, never when cautious", () => {
    const five = half({ runningHistory: "over_3_years", weeklyDistanceM: 40_000, runsPerWeek: 5 });
    expect(five.sessions.some((s) => s.type === "intervals")).toBe(true);
    expect(half({ runningHistory: "over_3_years", weeklyDistanceM: 40_000, runsPerWeek: 5, pain: true }).sessions.some((s) => s.type === "intervals")).toBe(false);
  });

  it("finishes the half marathon long run at a steadier effort in the build and peak, but not in the base or taper", () => {
    const draft = half({ runningHistory: "1_to_3_years", weeklyDistanceM: 30_000 });
    const longs = draft.sessions.filter((s) => s.type === "long");
    longs.forEach((s, w) => {
      const phase = draft.weeks[w]!.phase;
      const progressive = s.steps.length === 2;
      expect(progressive, `week ${w + 1} (${phase})`).toBe(phase === "build" || phase === "peak");
      if (progressive) expect(s.title).toBe("Progressive long run");
    });
    expect(codes(draft.warnings)).not.toContain("weekly_growth_too_high");
  });

  it("warns about a baseline that is far below the goal at each preset's own threshold", () => {
    expect(codes(ten({ weeklyDistanceM: 7000 }).warnings)).toContain("baseline_far_below_goal");
    expect(codes(ten({ weeklyDistanceM: 8000 }).warnings)).not.toContain("baseline_far_below_goal");
    expect(codes(half({ weeklyDistanceM: 11_000 }).warnings)).toContain("baseline_far_below_goal");
    expect(codes(half({ weeklyDistanceM: 12_000 }).warnings)).not.toContain("baseline_far_below_goal");
  });

  it("assumes a baseline by tier for the preset, and says which", () => {
    const draft = half({ runningHistory: "over_3_years" });
    expect(draft.assumptions.find((a) => a.code === "baseline_default")?.message).toContain("45 km");
  });
});

describe("generatePlan: strength sessions (design 6.4)", () => {
  const withStrength = (over: Partial<InterviewAnswers> = {}) => gen({ strength: { enabled: true, equipment: "dumbbells" }, ...over });
  const strengthOf = (d: PlanDraft, week: number) => d.sessions.filter((s) => s.type === "strength" && weekIndex(d, s.date) === week);

  it("adds none unless the user asked for them", () => {
    expect(gen().sessions.some((s) => s.type === "strength")).toBe(false);
    expect(gen({ strength: { enabled: false } }).sessions.some((s) => s.type === "strength")).toBe(false);
  });

  it("adds one or two short sessions a week: one for three runs, a beginner or pain, two otherwise", () => {
    expect(strengthOf(withStrength({ runsPerWeek: 3 }), 2)).toHaveLength(1);
    expect(strengthOf(withStrength({ runsPerWeek: 4, runningHistory: "1_to_3_years" }), 2)).toHaveLength(2);
    // Five runs with three hard days leave room for one: strength never goes on or before a hard day.
    const five = strengthOf(withStrength({ runsPerWeek: 5, runningHistory: "over_3_years" }), 2).length;
    expect(five).toBeGreaterThanOrEqual(1);
    expect(five).toBeLessThanOrEqual(2);
    expect(strengthOf(withStrength({ runsPerWeek: 4, runningHistory: "new_or_returning" }), 2)).toHaveLength(1);
    expect(strengthOf(withStrength({ runsPerWeek: 4, runningHistory: "over_3_years", pain: true }), 2)).toHaveLength(1);
  });

  it("keeps strength away from the hard runs and the day before them, and keeps a rest day", () => {
    for (const runs of [3, 4, 5] as const) {
      for (const history of ["new_or_returning", "1_to_3_years", "over_3_years"] as const) {
        const draft = withStrength({ runsPerWeek: runs, runningHistory: history });
        expect(codes(draft.warnings), `${runs} runs, ${history}`).not.toContain("strength_near_key_session");
        expect(codes(draft.warnings)).not.toContain("no_rest_day");
        expect(codes(draft.warnings)).not.toContain("hard_days_back_to_back");
      }
    }
  });

  it("never uses an unavailable day", () => {
    const draft = withStrength({ runsPerWeek: 4, runningHistory: "1_to_3_years", unavailableDays: ["tue", "thu"] });
    for (const s of draft.sessions) expect(["tue", "thu"]).not.toContain(weekdayOf(s.date));
  });

  it("uses only exercises from the curated library, matching the equipment, with a dose that fits the phase", () => {
    const bodyweight = gen({ strength: { enabled: true, equipment: "bodyweight" }, runningHistory: "1_to_3_years" });
    for (const s of bodyweight.sessions.filter((x) => x.type === "strength")) {
      expect(s.steps.length).toBeGreaterThanOrEqual(4);
      expect(s.steps.length).toBeLessThanOrEqual(6);
      for (const step of s.steps) {
        if (step.kind !== "exercise") throw new Error("a strength session has exercise steps only");
        const exercise = exerciseById(step.exerciseId)!;
        expect(exercise, step.exerciseId).toBeDefined();
        expect(exercise.equipment).toBe("bodyweight");
        expect(step.reps === undefined).toBe(step.durationSec !== undefined); // reps or a hold, never both or neither
        expect(step.loadNote).toBeUndefined();
      }
    }
    const dumbbells = withStrength({ runningHistory: "1_to_3_years" });
    const exercises = dumbbells.sessions.filter((x) => x.type === "strength").flatMap((s) => s.steps.flatMap((st) => (st.kind === "exercise" ? [st] : [])));
    expect(exercises.some((e) => exerciseById(e.exerciseId)!.equipment === "dumbbells" && e.loadNote !== undefined)).toBe(true);
    const sets = (week: number) => (strengthOf(dumbbells, week)[0]!.steps[0] as { sets: number }).sets;
    const phases = dumbbells.weeks.map((w) => w.phase);
    expect(sets(phases.indexOf("base"))).toBe(2);
    expect(sets(phases.indexOf("build"))).toBe(3);
    expect(sets(phases.lastIndexOf("taper"))).toBe(2);
  });

  it("is short, says how long, and counts for no running distance", () => {
    const draft = withStrength();
    const s = strengthOf(draft, 0)[0]!;
    expect(s.notes).toMatch(/^About \d+ minutes\. Stop any movement that hurts\.$/);
    const minutes = Number(/\d+/.exec(s.notes!)![0]);
    expect(minutes).toBeGreaterThanOrEqual(10);
    expect(minutes).toBeLessThanOrEqual(35);
    expect(sessionDistanceM(s as never)).toBe(0);
    expect(s.key).toBe(false);
    expect(volumes(draft)[0]!).toBeGreaterThan(0);
  });

  it("alternates routines from week to week", () => {
    const draft = withStrength({ runsPerWeek: 3 });
    const first = JSON.stringify(strengthOf(draft, 0)[0]!.steps.map((s) => (s as { exerciseId: string }).exerciseId));
    const second = JSON.stringify(strengthOf(draft, 1)[0]!.steps.map((s) => (s as { exerciseId: string }).exerciseId));
    expect(first).not.toBe(second);
  });

  it("assumes bodyweight when no equipment is given, and says so", () => {
    const draft = gen({ strength: { enabled: true } });
    expect(codes(draft.assumptions)).toContain("strength_equipment_default");
    expect(draft.sessions.filter((s) => s.type === "strength").length).toBeGreaterThan(0);
  });

  it("says so, once, when no day is left for a strength session away from the hard runs", () => {
    // Five runs on six free days (Monday unavailable): the hard days and the days before them take every other day.
    const draft = gen({ goal: { distance: "10k" }, runsPerWeek: 5, longRunDay: "sun", runningHistory: "1_to_3_years", unavailableDays: ["mon"], strength: { enabled: true, equipment: "dumbbells" } });
    expect(draft.sessions.filter((s) => s.type === "strength")).toHaveLength(0);
    expect(draft.assumptions.filter((x) => x.code === "strength_no_room")).toHaveLength(1);
    expect(codes(draft.warnings)).not.toContain("strength_near_key_session");
  });

  it("matches the dumbbell load advice to the effort, and keeps a pain-flagged plan gentle", () => {
    const notes = (d: PlanDraft) => [...new Set(d.sessions.filter((s) => s.type === "strength").flatMap((s) => s.steps.flatMap((st) => (st.kind === "exercise" && st.loadNote ? [st.loadNote] : []))))];
    const normal = notes(withStrength({ runningHistory: "1_to_3_years" }));
    expect(normal).toHaveLength(2);
    expect(normal.some((n) => n.includes("3 or 4 reps in reserve"))).toBe(true); // easy sets
    expect(normal.some((n) => n.includes("about 2 reps in reserve"))).toBe(true); // moderate sets
    expect(notes(withStrength({ runningHistory: "1_to_3_years", pain: true }))).toEqual(["Pick a weight that leaves 3 or 4 reps in reserve on every set."]);
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
      strength: fc.record({ enabled: fc.boolean(), equipment: fc.option(fc.constantFrom("bodyweight" as const, "dumbbells" as const), { nil: undefined }) }, { requiredKeys: ["enabled"] }),
      recentResult: fc.record({ distanceM: fc.integer({ min: 1000, max: 42_195 }), timeSec: fc.integer({ min: 120, max: 28_800 }), date: fc.option(fc.integer({ min: -90, max: 30 }).map((d) => addDays(TODAY, d)), { nil: undefined }) }, { requiredKeys: ["distanceM", "timeSec"] }),
    },
    { requiredKeys: [] },
  )
  .chain((a) => fc.constantFrom("5k" as const, "10k" as const, "half_marathon" as const).map((distance): InterviewAnswers => ({ goal: { distance }, ...a })));
const todayArb = fc.integer({ min: 0, max: 400 }).map((d) => addDays("2026-01-01", d));
/** A goal date from 30 days ago to 400 days ahead, or none. */
const goalOffsetArb = fc.option(fc.integer({ min: -30, max: 400 }), { nil: undefined });

describe("generatePlan: properties over random interview answers", () => {
  const run = (a: InterviewAnswers, today: string, goalOffset?: number) =>
    generatePlan({ answers: goalOffset === undefined ? a : { ...a, goal: { distance: a.goal.distance, date: addDays(today, goalOffset) } }, today });

  it("always yields a valid plan: the preset's length, one run a day, inside the plan, unavailable days free, no run past its limit", () => {
    fc.assert(
      fc.property(answersArb, todayArb, goalOffsetArb, (a, today, goalOffset) => {
        const preset = PRESETS[a.goal.distance];
        const draft = run(a, today, goalOffset);
        expect(draft.engine.presetId).toBe(preset.id);
        expect(draft.weekCount).toBeGreaterThanOrEqual(preset.minWeeks);
        expect(draft.weekCount).toBeLessThanOrEqual(preset.maxWeeks + preset.extraBaseWeeksMax);
        if (goalOffset === undefined) expect(draft.weekCount).toBeLessThanOrEqual(preset.maxWeeks);
        expect(draft.assumptions.length).toBeLessThanOrEqual(50);
        expect(draft.warnings.length).toBeLessThanOrEqual(100);
        const byDay = new Map<string, typeof draft.sessions>();
        for (const s of draft.sessions) {
          const w = weekIndex(draft, s.date);
          expect(w).toBeGreaterThanOrEqual(0);
          expect(w).toBeLessThan(draft.weekCount);
          byDay.set(s.date, [...(byDay.get(s.date) ?? []), s]);
          expect(a.unavailableDays ?? []).not.toContain(weekdayOf(s.date));
          const limit = s.type === "long" ? preset.longRunMaxM : s.type === "easy" ? preset.easyRunMaxM : preset.qualityMaxM;
          expect(sessionDistanceM(s as never)).toBeLessThanOrEqual(limit);
        }
        // One run a day; a strength session may share a day with an easy run, never with a hard one.
        for (const [date, list] of byDay) {
          expect(list.length, date).toBeLessThanOrEqual(2);
          if (list.length === 2) {
            expect(list.filter((x) => x.type === "strength")).toHaveLength(1);
            expect(list.every((x) => !x.key)).toBe(true);
          }
        }
        if (a.strength?.enabled !== true) expect(draft.sessions.some((s) => s.type === "strength")).toBe(false);
        for (const text of [...draft.assumptions, ...draft.warnings]) expect(text.message.length).toBeLessThanOrEqual(500);
      }),
      { numRuns: 300 },
    );
  });

  it("keeps strength off the hard days and the day before them, with a rest day left, for every preset", () => {
    fc.assert(
      fc.property(answersArb, todayArb, goalOffsetArb, (a, today, goalOffset) => {
        const draft = run({ ...a, strength: { enabled: true, equipment: "dumbbells" } }, today, goalOffset);
        expect(codes(draft.warnings)).not.toContain("strength_near_key_session");
        expect(codes(draft.warnings)).not.toContain("no_rest_day");
        const perWeek = new Map<number, number>();
        for (const s of draft.sessions.filter((x) => x.type === "strength")) {
          perWeek.set(weekIndex(draft, s.date), (perWeek.get(weekIndex(draft, s.date)) ?? 0) + 1);
          for (const step of s.steps) {
            if (step.kind !== "exercise") throw new Error("exercise steps only");
            expect(exerciseById(step.exerciseId)).toBeDefined();
          }
        }
        for (const count of perWeek.values()) expect(count).toBeLessThanOrEqual(2);
      }),
      { numRuns: 200 },
    );
  });

  it("starts below the stated baseline whenever the baseline allows a sensible first week", () => {
    fc.assert(
      fc.property(answersArb, todayArb, (a, today) => {
        const draft = run(a, today);
        const runs = draft.sessions.filter((s) => weekIndex(draft, s.date) === 0 && s.type !== "strength").length;
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
      fc.property(answersArb, todayArb, goalOffsetArb, (a, today, goalOffset) => {
        const draft = run(a, today, goalOffset);
        const v = volumes(draft);
        const preset = PRESETS[a.goal.distance];
        const history = a.runningHistory;
        const tierCap = preset.tiers[history === "over_3_years" ? "experienced" : history === "1_to_3_years" ? "intermediate" : "beginner"].capM;
        const downEvery = a.pain ? 3 : 4;
        const extra = Math.max(0, draft.weekCount - preset.maxWeeks); // extra base weeks hold the start volume
        for (let w = 1; w < v.length - 2; w++) {
          // A step is at most one growth step (8%) or the return from a down week (1 / 0.88), plus rounding.
          expect(v[w]!, `week ${w + 1}: ${v[w - 1]} to ${v[w]}`).toBeLessThanOrEqual(v[w - 1]! * 1.14 + 300);
          const inPlan = w - extra;
          if (inPlan > 0 && (inPlan + 1) % downEvery === 0) expect(v[w]!, `down week ${w + 1}`).toBeLessThanOrEqual(v[w - 1]!);
          if (w < extra) expect(v[w]!, `base week ${w + 1} holds the start`).toBe(v[0]!);
        }
        const peak = Math.max(...v.slice(0, -2));
        expect(v.at(-2)!).toBeLessThanOrEqual(0.8 * peak + 600);
        expect(v.at(-1)!).toBeLessThanOrEqual(0.6 * peak + 600);
        for (const week of v.slice(0, -2)) expect(week).toBeLessThanOrEqual(Math.max(tierCap, v[0]!) + 300);
        expect(codes(draft.warnings)).not.toContain("weekly_growth_too_high");
        expect(codes(draft.warnings)).not.toContain("no_down_week");
        // A goal date inside a too-short plan is before the taper, which the validators rightly flag.
        if (goalOffset === undefined || goalOffset >= preset.minWeeks * 7 - 1) expect(codes(draft.warnings)).not.toContain("no_taper");
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
      fc.property(answersArb, todayArb, fc.integer({ min: 69, max: 400 }), (a, today, offset) => {
        const goal = addDays(today, offset);
        const draft = generatePlan({ answers: { ...a, goal: { distance: a.goal.distance, date: goal } }, today });
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
