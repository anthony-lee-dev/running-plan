import { describe, expect, it } from "vitest";
import { parseGenerateRequest } from "../src/domain/generate-input";

const minimal = { answers: { goal: { distance: "5k" } }, today: "2026-11-02" };
const full = {
  answers: {
    goal: { distance: "half_marathon", date: "2027-04-18", targetTimeSec: 7200 },
    recentResult: { distanceM: 5000, timeSec: 1500, date: "2026-10-20" },
    weeklyDistanceM: 25000,
    longestRunM: 12000,
    runningHistory: "1_to_3_years",
    runsPerWeek: 4,
    unavailableDays: ["mon", "fri"],
    longRunDay: "sun",
    pain: false,
    strength: { enabled: true, equipment: "dumbbells" },
    targetDisplay: "heart_rate",
    heartRate: { maxBpm: 190, zones: [{ minBpm: 100, maxBpm: 120 }, { minBpm: 120, maxBpm: 140 }, { minBpm: 140, maxBpm: 160 }, { minBpm: 160, maxBpm: 175 }, { minBpm: 175, maxBpm: 190 }] },
  },
  today: "2026-11-02",
  presetId: "half_marathon",
};

const withAnswers = (over: Record<string, unknown>) => ({ ...minimal, answers: { ...minimal.answers, ...over } });

describe("parseGenerateRequest", () => {
  it("accepts the minimal request: only the goal distance and today", () => {
    expect(parseGenerateRequest(minimal)).toEqual({ ok: true, value: minimal });
  });

  it("accepts every answer and keeps them as sent", () => {
    expect(parseGenerateRequest(full)).toEqual({ ok: true, value: full });
  });

  it.each<[string, unknown, string]>([
    ["not an object", [], "/"],
    ["no answers", { today: "2026-11-02" }, "/answers"],
    ["no today", { answers: minimal.answers }, "/today"],
    ["today not a calendar date", { ...minimal, today: "2026-02-30" }, "/today"],
    ["today past 2099", { ...minimal, today: "9999-12-20" }, "/today"],
    ["goal date before 2000", withAnswers({ goal: { distance: "5k", date: "1999-12-31" } }), "/answers/goal/date"],
    ["today with a time", { ...minimal, today: "2026-11-02T10:00:00Z" }, "/today"],
    ["unknown top-level field", { ...minimal, extra: 1 }, "/extra"],
    ["no goal", { ...minimal, answers: {} }, "/answers/goal"],
    ["unknown goal distance", withAnswers({ goal: { distance: "marathon" } }), "/answers/goal/distance"],
    ["unknown goal field", withAnswers({ goal: { distance: "5k", name: "x" } }), "/answers/goal/name"],
    ["goal date not a date", withAnswers({ goal: { distance: "5k", date: "soon" } }), "/answers/goal/date"],
    ["target time too fast", withAnswers({ goal: { distance: "5k", targetTimeSec: 599 } }), "/answers/goal/targetTimeSec"],
    ["target time not whole", withAnswers({ goal: { distance: "5k", targetTimeSec: 1500.5 } }), "/answers/goal/targetTimeSec"],
    ["recent result without a time", withAnswers({ recentResult: { distanceM: 5000 } }), "/answers/recentResult/timeSec"],
    ["recent result too short", withAnswers({ recentResult: { distanceM: 999, timeSec: 300 } }), "/answers/recentResult/distanceM"],
    ["recent result unknown field", withAnswers({ recentResult: { distanceM: 5000, timeSec: 1500, hr: 150 } }), "/answers/recentResult/hr"],
    ["negative weekly distance", withAnswers({ weeklyDistanceM: -1 }), "/answers/weeklyDistanceM"],
    ["weekly distance too high", withAnswers({ weeklyDistanceM: 200001 }), "/answers/weeklyDistanceM"],
    ["weekly distance as text", withAnswers({ weeklyDistanceM: "20000" }), "/answers/weeklyDistanceM"],
    ["longest run too long", withAnswers({ longestRunM: 50001 }), "/answers/longestRunM"],
    ["unknown history", withAnswers({ runningHistory: "forever" }), "/answers/runningHistory"],
    ["two runs a week", withAnswers({ runsPerWeek: 2 }), "/answers/runsPerWeek"],
    ["six runs a week", withAnswers({ runsPerWeek: 6 }), "/answers/runsPerWeek"],
    ["five unavailable days", withAnswers({ unavailableDays: ["mon", "tue", "wed", "thu", "fri"] }), "/answers/unavailableDays"],
    ["repeated unavailable day", withAnswers({ unavailableDays: ["mon", "mon"] }), "/answers/unavailableDays"],
    ["unknown weekday", withAnswers({ unavailableDays: ["monday"] }), "/answers/unavailableDays/0"],
    ["long run day not a weekday", withAnswers({ longRunDay: "weekend" }), "/answers/longRunDay"],
    ["pain as text", withAnswers({ pain: "yes" }), "/answers/pain"],
    ["strength without enabled", withAnswers({ strength: { equipment: "bodyweight" } }), "/answers/strength/enabled"],
    ["unknown equipment", withAnswers({ strength: { enabled: true, equipment: "kettlebell" } }), "/answers/strength/equipment"],
    ["unknown target display", withAnswers({ targetDisplay: "power" }), "/answers/targetDisplay"],
    ["max heart rate too high", withAnswers({ heartRate: { maxBpm: 231 } }), "/answers/heartRate/maxBpm"],
    ["four heart-rate zones", withAnswers({ heartRate: { zones: [{ minBpm: 100, maxBpm: 120 }, { minBpm: 120, maxBpm: 140 }, { minBpm: 140, maxBpm: 160 }, { minBpm: 160, maxBpm: 175 }] } }), "/answers/heartRate/zones"],
    ["unknown preset", { ...minimal, presetId: "marathon" }, "/presetId"],
    ["preset named after an object property", { ...minimal, presetId: "toString" }, "/presetId"],
    ["preset id too long", { ...minimal, presetId: "x".repeat(65) }, "/presetId"],
  ])("rejects %s", (_name, body, path) => {
    const result = parseGenerateRequest(body);
    expect(result.ok).toBe(false);
    if (!result.ok) expect(result.errors.map((e) => e.path)).toContain(path);
  });

  it("rejects a __proto__ key sent in JSON", () => {
    const result = parseGenerateRequest(JSON.parse('{"answers":{"goal":{"distance":"5k"},"__proto__":{"x":1}},"today":"2026-11-02"}'));
    expect(result.ok).toBe(false);
    if (!result.ok) expect(result.errors.map((e) => e.path)).toContain("/answers/__proto__");
  });

  it("reports every problem at once", () => {
    const result = parseGenerateRequest({ answers: { goal: { distance: "5k" }, runsPerWeek: 9, pain: 1 }, today: "x" });
    expect(result.ok).toBe(false);
    if (!result.ok) expect(result.errors.map((e) => e.path).sort()).toEqual(["/answers/pain", "/answers/runsPerWeek", "/today"]);
  });
});
