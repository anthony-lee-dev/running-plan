import { describe, expect, it } from "vitest";
import {
  sessionDistanceM,
  validatePlan,
  type PlanToValidate,
  type ValidatorSession,
} from "../src/domain/validators";

const START = "2026-11-02"; // a Monday

function addDays(date: string, days: number): string {
  const d = new Date(`${date}T00:00:00Z`);
  d.setUTCDate(d.getUTCDate() + days);
  return d.toISOString().slice(0, 10);
}

let n = 0;
/** A run session `day` days after the start, with a distance goal in km. */
function run(day: number, type: ValidatorSession["type"], km: number, extra: Partial<ValidatorSession> = {}) {
  n += 1;
  return {
    id: `s${n}`,
    date: addDays(START, day),
    type,
    steps: [{ kind: "work", goal: { type: "distance", value: km * 1000 } }],
    ...extra,
  } as ValidatorSession;
}

function plan(weekCount: number, sessions: ValidatorSession[], extra: Partial<PlanToValidate> = {}): PlanToValidate {
  return { startDate: START, weekCount, sessions, ...extra };
}

const codes = (p: PlanToValidate, opts = {}) => validatePlan(p, opts).warnings.map((w) => w.code);

/** A calm week: easy Tue, easy Thu, long Sun, rest on the other days. */
const calmWeek = (w: number, km = 5, longKm = 8) => [
  run(w * 7 + 1, "easy", km),
  run(w * 7 + 3, "easy", km),
  run(w * 7 + 6, "long", longKm),
];

describe("sessionDistanceM", () => {
  it("sums distance goals and multiplies repeat groups", () => {
    const s = run(0, "intervals", 0, {
      steps: [
        { kind: "warmup", goal: { type: "distance", value: 1000 } },
        {
          kind: "repeat",
          count: 4,
          steps: [
            { kind: "work", goal: { type: "distance", value: 400 } },
            { kind: "recovery", goal: { type: "distance", value: 200 } },
          ],
        },
        { kind: "cooldown", goal: { type: "distance", value: 1000 } },
      ],
    });
    expect(sessionDistanceM(s)).toBe(4400);
  });

  it("estimates time goals at the fallback pace and ignores open goals", () => {
    const s = run(0, "easy", 0, {
      steps: [
        { kind: "work", goal: { type: "time", value: 1800 } },
        { kind: "cooldown", goal: { type: "open" } },
      ],
    });
    expect(sessionDistanceM(s, 360)).toBe(5000);
  });

  it("counts nothing for strength, rest and custom sessions", () => {
    expect(sessionDistanceM(run(0, "strength", 5))).toBe(0);
    expect(sessionDistanceM(run(0, "rest", 5))).toBe(0);
    expect(sessionDistanceM(run(0, "custom", 5))).toBe(0);
  });
});

describe("validatePlan", () => {
  it("is quiet for a gentle, well-formed plan", () => {
    const sessions = [0, 1, 2, 3].flatMap((w) => calmWeek(w, 5 + w * 0.3, 8 + w * 0.3));
    expect(codes(plan(4, sessions), { baselineWeeklyM: 20000 })).toEqual([]);
  });

  describe("first week", () => {
    it("warns when week 1 is above the stated baseline", () => {
      const p = plan(2, [...calmWeek(0, 8, 12), ...calmWeek(1, 8, 12)]);
      const w = validatePlan(p, { baselineWeeklyM: 20000 }).warnings.find((x) => x.code === "first_week_above_baseline");
      expect(w).toMatchObject({ weekIndex: 0, severity: "caution" });
    });
    it("stays quiet without a baseline", () => {
      expect(codes(plan(1, calmWeek(0, 8, 12)))).not.toContain("first_week_above_baseline");
    });
    it("accepts a week exactly at the baseline", () => {
      expect(codes(plan(1, calmWeek(0, 6, 8)), { baselineWeeklyM: 20000 })).not.toContain("first_week_above_baseline");
    });
  });

  describe("weekly growth", () => {
    it.each([
      { name: "10 to 12 km (+20%, +2 km)", from: [3, 3, 4], to: [4, 4, 4], warn: false },
      { name: "20 to 30 km (+50%)", from: [6, 6, 8], to: [9, 9, 12], warn: true },
      { name: "20 to 22 km (+10%)", from: [6, 6, 8], to: [6.6, 6.6, 8.8], warn: false },
      { name: "30 to 36 km (+20%)", from: [9, 9, 12], to: [11, 11, 14], warn: true },
    ])("$name", ({ from, to, warn }) => {
      const mk = (w: number, [a, b, c]: number[]) => [
        run(w * 7 + 1, "easy", a!),
        run(w * 7 + 3, "easy", b!),
        run(w * 7 + 6, "long", c!),
      ];
      const found = validatePlan(plan(2, [...mk(0, from), ...mk(1, to)])).warnings.find(
        (x) => x.code === "weekly_growth_too_high",
      );
      expect(Boolean(found)).toBe(warn);
      if (found) expect(found.weekIndex).toBe(1);
    });

    it("warns when four weeks climb in a row with no down week", () => {
      const sessions = [0, 1, 2, 3, 4].flatMap((w) => calmWeek(w, 5 + w * 0.4, 8 + w * 0.4));
      expect(codes(plan(5, sessions))).toContain("no_down_week");
    });
    it("accepts a down week inside the run of weeks", () => {
      const km = [5, 5.5, 6, 4.5, 5.5];
      const sessions = km.flatMap((k, w) => calmWeek(w, k, k + 3));
      expect(codes(plan(5, sessions))).not.toContain("no_down_week");
    });
  });

  describe("hard sessions", () => {
    it("warns on back-to-back hard days and names both sessions", () => {
      const a = run(1, "intervals", 6);
      const b = run(2, "tempo", 6);
      const w = validatePlan(plan(1, [a, b, run(4, "easy", 5)])).warnings.find((x) => x.code === "hard_days_back_to_back");
      expect(w?.sessionIds).toEqual([a.id, b.id]);
      expect(w?.weekIndex).toBe(0);
    });
    it("treats a long run and a hard custom session as hard", () => {
      const a = run(5, "long", 10);
      const b = run(6, "custom", 0, { steps: [], custom: { effort: "hard" } });
      expect(codes(plan(1, [a, b]))).toContain("hard_days_back_to_back");
    });
    it("does not count easy, strength, rest or moderate custom days", () => {
      const sessions = [
        run(1, "intervals", 6),
        run(2, "easy", 4),
        run(3, "tempo", 6),
        run(4, "strength", 0),
        run(5, "custom", 0, { steps: [], custom: { effort: "moderate" } }),
        run(6, "long", 10),
      ];
      expect(codes(plan(1, sessions))).not.toContain("hard_days_back_to_back");
    });
    it("catches hard days that straddle two weeks", () => {
      const a = run(6, "long", 10);
      const b = run(7, "intervals", 6);
      expect(codes(plan(2, [a, b]))).toContain("hard_days_back_to_back");
    });
  });

  describe("rest day", () => {
    it("warns for a full week with a session on every day", () => {
      const sessions = [0, 1, 2, 3, 4, 5, 6].map((d) => run(d, d === 6 ? "long" : "easy", 4));
      const w = validatePlan(plan(1, sessions)).warnings.find((x) => x.code === "no_rest_day");
      expect(w?.weekIndex).toBe(0);
    });
    it("counts a `rest` session as a free day", () => {
      const sessions = [0, 1, 2, 3, 4, 5, 6].map((d) => run(d, d === 3 ? "rest" : "easy", 4));
      expect(codes(plan(1, sessions))).not.toContain("no_rest_day");
    });
    it("does not complain about a week with no sessions at all", () => {
      expect(codes(plan(2, calmWeek(0)))).not.toContain("no_rest_day");
    });
  });

  describe("long run share", () => {
    it("warns when the long run is more than half the week", () => {
      const p = plan(1, [run(1, "easy", 4), run(3, "easy", 4), run(6, "long", 14)]);
      expect(codes(p)).toContain("long_run_share_high");
    });
    it("accepts a long run at exactly half", () => {
      const p = plan(1, [run(1, "easy", 4), run(3, "easy", 4), run(6, "long", 8)]);
      expect(codes(p)).not.toContain("long_run_share_high");
    });
    it("skips weeks with a single run", () => {
      expect(codes(plan(1, [run(6, "long", 10)]))).not.toContain("long_run_share_high");
    });
  });

  describe("taper", () => {
    const weeks = (km: number[]) => km.flatMap((k, w) => calmWeek(w, k, k + 3));
    const goalDate = addDays(START, 6 * 7 + 6); // last day of week 7 of 7

    it("warns when the final week before the goal is not lighter than the peak", () => {
      const p = plan(7, weeks([4, 4.5, 5, 5.5, 5.5, 6, 6]), { goalDate });
      expect(codes(p)).toContain("no_taper");
    });
    it("accepts a final week at 85% of the peak or less", () => {
      const p = plan(7, weeks([4, 4.5, 5, 5.5, 6, 6.5, 4.5]), { goalDate });
      expect(codes(p)).not.toContain("no_taper");
    });
    it("is not checked without a goal date or for very short plans", () => {
      expect(codes(plan(7, weeks([4, 4, 4, 4, 4, 4, 4])))).not.toContain("no_taper");
      expect(codes(plan(3, weeks([4, 4, 4]), { goalDate: addDays(START, 20) }))).not.toContain("no_taper");
    });
  });

  describe("strength placement", () => {
    it("warns on the day of, or the day before, a key hard run", () => {
      const lift = run(2, "strength", 0);
      const hard = run(3, "intervals", 6);
      const w = validatePlan(plan(1, [lift, hard, run(5, "easy", 4)])).warnings.find(
        (x) => x.code === "strength_near_key_session",
      );
      expect(w?.sessionIds).toEqual([lift.id, hard.id]);
      expect(codes(plan(1, [run(3, "strength", 0), run(3, "tempo", 5)]))).toContain("strength_near_key_session");
      expect(codes(plan(1, [run(5, "strength", 0), run(6, "long", 10)]))).toContain("strength_near_key_session");
    });
    it("accepts strength the day after a hard run or on an easy day", () => {
      const sessions = [run(1, "intervals", 6), run(2, "strength", 0), run(3, "easy", 4), run(6, "long", 10)];
      expect(codes(plan(1, sessions))).not.toContain("strength_near_key_session");
    });
  });

  it("ignores tombstoned sessions", () => {
    const a = run(1, "intervals", 6, { deletedAt: "2026-11-01T00:00:00Z" });
    expect(codes(plan(1, [a, run(2, "tempo", 6)]))).not.toContain("hard_days_back_to_back");
  });

  it("returns the same result for the same input and never mutates it", () => {
    const p = plan(3, [...calmWeek(0, 8, 12), ...calmWeek(1, 12, 16), run(8, "tempo", 5), run(9, "intervals", 5)]);
    const copy = structuredClone(p);
    expect(validatePlan(p, { baselineWeeklyM: 10000 })).toEqual(validatePlan(p, { baselineWeeklyM: 10000 }));
    expect(p).toEqual(copy);
  });

  it("orders warnings by week, then code", () => {
    // Week 1: tempo then intervals back to back, and a long run that is most of the week.
    const p = plan(2, [run(1, "tempo", 5), run(2, "intervals", 5), run(6, "long", 20), ...calmWeek(1, 5, 8)]);
    const found = validatePlan(p, { baselineWeeklyM: 10000 }).warnings.map((w) => `${w.weekIndex}:${w.code}`);
    expect(found).toEqual([
      "0:first_week_above_baseline",
      "0:hard_days_back_to_back",
      "0:long_run_share_high",
    ]);
  });
});

describe("validatePlan errors (invalid data only)", () => {
  it("rejects a session outside the plan span", () => {
    const before = run(-1, "easy", 5);
    const after = run(14, "easy", 5);
    const result = validatePlan(plan(2, [before, after, run(1, "easy", 5)]));
    expect(result.errors.map((e) => e.code)).toEqual(["session_outside_plan", "session_outside_plan"]);
    expect(result.errors.map((e) => e.sessionId)).toEqual([before.id, after.id]);
  });
  it("rejects a malformed or impossible date and leaves it out of the warnings", () => {
    const bad = run(1, "easy", 5, { date: "2026-13-45" });
    const shape = run(1, "easy", 5, { date: "02/11/2026" });
    const result = validatePlan(plan(1, [bad, shape]));
    expect(result.errors.map((e) => e.code)).toEqual(["invalid_date", "invalid_date"]);
    expect(result.warnings).toEqual([]);
  });
  it("rejects duplicate session ids", () => {
    const a = run(1, "easy", 5);
    const b = { ...run(3, "easy", 5), id: a.id };
    expect(validatePlan(plan(1, [a, b])).errors.map((e) => e.code)).toEqual(["duplicate_session_id"]);
  });
  it("returns an error, not an exception, for a bad start date or week count", () => {
    for (const bad of [{ startDate: "nope" }, { weekCount: -1 }, { weekCount: 2.5 }]) {
      const result = validatePlan({ ...plan(2, calmWeek(0)), ...bad });
      expect(result.errors.map((e) => e.code)).toEqual(["invalid_plan"]);
      expect(result.warnings).toEqual([]);
    }
  });
  it("has no errors for a valid plan", () => {
    expect(validatePlan(plan(1, calmWeek(0))).errors).toEqual([]);
  });
});
