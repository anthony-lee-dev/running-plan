import { describe, expect, it } from "vitest";
import type { Activity } from "./api/types";
import { MONTHS_SHOWN, WEEKS_SHOWN, buckets, comparison, durationText, earliestShown, localToday, planWeekLines } from "./runTotals";

const run = (id: string, localDate: string, over: Partial<Activity> = {}): Activity => ({
  id, source: "apple_health", externalId: id, workoutType: "running", startedAt: `${localDate}T06:30:00Z`, localDate,
  durationSec: 1800, distanceM: 5000, importedAt: "2026-11-04T07:00:00Z", disposition: "matched", ...over,
});

// 2026-11-04 is a Wednesday: its week is Mon 2026-11-02 to Sun 2026-11-08.
const today = "2026-11-04";

describe("run totals", () => {
  it("buckets weeks Monday to Sunday on the local date", () => {
    const runs = [run("a", "2026-11-02"), run("b", "2026-11-08"), run("c", "2026-11-01"), run("d", "2026-10-26")];
    const weeks = buckets(runs, today, "week");
    expect(weeks).toHaveLength(WEEKS_SHOWN);
    const this_ = weeks[weeks.length - 1]!;
    const last = weeks[weeks.length - 2]!;
    expect([this_.first, this_.last, this_.isCurrent, this_.runs, this_.distanceM]).toEqual(["2026-11-02", "2026-11-08", true, 2, 10000]);
    expect([last.first, last.runs, last.isCurrent]).toEqual(["2026-10-26", 2, false]);
  });

  it("buckets calendar months, oldest first", () => {
    const months = buckets([run("a", "2026-11-01"), run("b", "2026-10-31"), run("c", "2026-10-01")], today, "month");
    expect(months).toHaveLength(MONTHS_SHOWN);
    expect(months.slice(-2).map((m) => m.label)).toEqual(["Oct", "Nov"]);
    expect(months.map((m) => m.runs).slice(-2)).toEqual([2, 1]);
    expect([months[0]!.first, months[5]!.last]).toEqual(["2026-06-01", "2026-11-30"]);
  });

  it("crosses the year", () => {
    const months = buckets([run("a", "2025-12-31")], "2026-02-10", "month");
    expect(months.slice(-3).map((m) => m.label)).toEqual(["Dec", "Jan", "Feb"]);
    expect(months[months.length - 3]!.runs).toBe(1);
    expect(months[months.length - 3]!.last).toBe("2025-12-31");
  });

  it("counts running workouts that are matched, in the inbox or extra, and leaves out ignored and other types", () => {
    const runs = [
      run("a", "2026-11-03"),
      run("b", "2026-11-03", { disposition: "inbox" }),
      run("c", "2026-11-03", { disposition: "extra" }),
      run("d", "2026-11-03", { disposition: "ignored" }),
      run("e", "2026-11-03", { workoutType: "cycling" }),
    ];
    expect(buckets(runs, today, "week").at(-1)!.runs).toBe(3);
  });

  it("works pace out from total time over total distance of the runs that have a distance", () => {
    const runs = [
      run("a", "2026-11-03", { distanceM: 5000, durationSec: 1500 }),
      run("b", "2026-11-04", { distanceM: 10000, durationSec: 3600 }),
      run("c", "2026-11-05", { distanceM: undefined, durationSec: 600 }),
    ];
    const week = buckets(runs, today, "week").at(-1)!;
    expect([week.runs, week.distanceM, week.timeSec, week.paceSecPerKm]).toEqual([3, 15000, 5700, 340]);
  });

  it("has no pace without a distance", () => {
    expect(buckets([run("a", "2026-11-03", { distanceM: undefined })], today, "week").at(-1)!.paceSecPerKm).toBeUndefined();
    expect(buckets([], today, "week").at(-1)!.paceSecPerKm).toBeUndefined();
  });

  it("leaves out runs outside the shown buckets, and says where to start loading", () => {
    expect(buckets([run("a", "2025-01-01"), run("b", "2026-11-09")], today, "week").reduce((n, b) => n + b.runs, 0)).toBe(0);
    expect(earliestShown(today)).toBe("2026-06-01");
  });

  it("compares with the period before, only when it had a run", () => {
    const runs = [run("a", "2026-11-03", { distanceM: 10000 }), run("b", "2026-10-28", { distanceM: 8000 })];
    expect(comparison(buckets(runs, today, "week"), "week")).toBe("2 km more than last week");
    const months = buckets([run("a", "2026-11-03", { distanceM: 10000 }), run("b", "2026-10-28", { distanceM: 30000 })], today, "month");
    expect(comparison(months, "month")).toBe("20 km less than last month");
    expect(comparison(buckets([run("a", "2026-11-03")], today, "week"), "week")).toBeUndefined();
    expect(comparison(buckets([run("a", "2026-11-03"), run("b", "2026-10-28")], today, "week"), "week")).toBe("Same distance as last week");
  });

  it("writes durations to the minute", () => {
    expect([0, 45 * 60, 59 * 60 + 40, 3 * 3600 + 12 * 60].map(durationText)).toEqual(["0 min", "45 min", "1 h 00 min", "3 h 12 min"]);
  });

  it("describes the plan week", () => {
    expect(planWeekLines({ plannedM: 25000, ranM: 18500, done: 3, planned: 5 })).toEqual(["18.5 of 25 km planned", "3 of 5 sessions done"]);
  });

  it("reads today from the local clock, not UTC", () => {
    expect(localToday(new Date(2026, 10, 4, 22, 30))).toBe("2026-11-04");
    expect(localToday(new Date(2026, 0, 5, 0, 5))).toBe("2026-01-05");
  });
});
