// Snapshot tests over the base variants of design 6.2: 3 presets x 3 runs a week x 3 experience tiers x strength on
// or off = 54 plans, plus boundary cases for plan length and day constraints. A change to any plan shows up as a
// reviewable diff in the snapshot; update it deliberately (`npx vitest -u`) when the change is intended, and bump
// ENGINE_VERSION when a number in presets.ts or engine.ts moves.
import { describe, expect, it } from "vitest";
import { generatePlan, type DraftSession, type PlanDraft } from "../src/domain/engine";
import type { InterviewAnswers, RunningHistory } from "../src/domain/interview";
import { sessionDistanceM } from "../src/domain/validators";

const TODAY = "2026-11-02"; // a Monday
const DAYS = ["Mon", "Tue", "Wed", "Thu", "Fri", "Sat", "Sun"];
const dayNumber = (date: string) => Date.parse(`${date}T00:00:00Z`) / 86_400_000;
const km = (m: number) => (m / 1000).toFixed(1);

function describeSession(s: DraftSession): string {
  const day = DAYS[(dayNumber(s.date) + 3) % 7]!;
  if (s.type === "strength") return `${day} strength(${s.steps.length}x${(s.steps[0] as { sets: number }).sets}, ${/\d+/.exec(s.notes ?? "")?.[0]}m)`;
  const repeat = s.steps.find((step) => step.kind === "repeat");
  const shape = repeat && repeat.kind === "repeat" ? ` ${repeat.count}x${repeat.steps[0]!.goal.value}` : s.steps.length === 2 && s.type === "long" ? " prog" : "";
  return `${day} ${s.type}${shape} ${km(sessionDistanceM(s as never))}`;
}

/** One plan as text: header, notices, then a line a week. */
function render(draft: PlanDraft): string {
  const weeks = draft.weeks.map((w) => {
    const sessions = draft.sessions.filter((s) => Math.floor((dayNumber(s.date) - dayNumber(draft.startDate)) / 7) === w.index);
    const volume = sessions.reduce((sum, s) => sum + sessionDistanceM(s as never), 0);
    return `w${String(w.index + 1).padStart(2, "0")} ${w.phase.padEnd(5)} ${km(volume).padStart(5)} km: ${sessions.map(describeSession).join(" | ")}`;
  });
  return [
    `${draft.engine.presetId} v${draft.engine.version}: ${draft.weekCount} weeks from ${draft.startDate}${draft.goal.date ? ` to ${draft.goal.date}` : ""}`,
    `assumptions: ${draft.assumptions.map((a) => a.code).join(", ") || "none"}`,
    `warnings: ${draft.warnings.map((w) => `${w.code}${w.weekIndex !== undefined ? `@${w.weekIndex + 1}` : ""}`).join(", ") || "none"}`,
    ...weeks,
  ].join("\n");
}

const PRESET_NAMES = ["5k", "10k", "half_marathon"] as const;
const TIERS: [string, RunningHistory][] = [
  ["beginner", "new_or_returning"],
  ["intermediate", "1_to_3_years"],
  ["experienced", "over_3_years"],
];
const BASELINE: Record<(typeof PRESET_NAMES)[number], Record<string, number>> = {
  "5k": { beginner: 10_000, intermediate: 20_000, experienced: 30_000 },
  "10k": { beginner: 12_000, intermediate: 25_000, experienced: 38_000 },
  half_marathon: { beginner: 15_000, intermediate: 30_000, experienced: 45_000 },
};

describe("base variants (design 6.2): 3 presets x 3 runs a week x 3 tiers x strength on or off", () => {
  const variants = PRESET_NAMES.flatMap((preset) =>
    ([3, 4, 5] as const).flatMap((runs) =>
      TIERS.flatMap(([tier, history]) =>
        ([false, true] as const).map((strength) => ({
          name: `${preset} / ${runs} runs / ${tier} / ${strength ? "with strength" : "no strength"}`,
          answers: {
            goal: { distance: preset },
            runsPerWeek: runs,
            runningHistory: history,
            weeklyDistanceM: BASELINE[preset][tier]!,
            ...(strength ? { strength: { enabled: true, equipment: "bodyweight" as const } } : {}),
          } satisfies InterviewAnswers,
        })),
      ),
    ),
  );

  it("has exactly the 54 variants the design counts", () => {
    expect(variants).toHaveLength(54);
    expect(new Set(variants.map((v) => v.name)).size).toBe(54);
  });

  // One `it` each, so a snapshot keeps its full name (`it.each` shortens long ones).
  for (const { name, answers } of variants) {
    it(name, () => {
      expect(render(generatePlan({ answers, today: TODAY }))).toMatchSnapshot();
    });
  }
});

describe("boundary cases: plan length and day constraints", () => {
  const cases: [string, InterviewAnswers][] = [
    ["5k, goal date exactly 8 weeks away", { goal: { distance: "5k", date: "2026-12-27" }, runsPerWeek: 4 }],
    ["5k, goal date 3 days over 15 weeks (starts later, base weeks)", { goal: { distance: "5k", date: "2027-02-17" }, runsPerWeek: 3 }],
    ["10k, goal date too soon (keeps 8 weeks)", { goal: { distance: "10k", date: "2026-11-30" }, runsPerWeek: 4 }],
    ["10k, goal date 14 weeks away", { goal: { distance: "10k", date: "2027-02-07" }, runsPerWeek: 4, runningHistory: "1_to_3_years" }],
    ["half marathon, goal date too soon (keeps 10 weeks)", { goal: { distance: "half_marathon", date: "2026-12-06" }, runsPerWeek: 4 }],
    ["half marathon, goal date 22 weeks away (16 weeks, starts later)", { goal: { distance: "half_marathon", date: "2027-04-04" }, runsPerWeek: 4, runningHistory: "1_to_3_years" }],
    ["5k, three free days only (Mon, Thu, Sat), long run Sat", { goal: { distance: "5k" }, runsPerWeek: 5, unavailableDays: ["tue", "wed", "fri", "sun"], longRunDay: "sat" }],
    ["10k, long run on an unavailable day (falls back)", { goal: { distance: "10k" }, runsPerWeek: 4, unavailableDays: ["sun"], longRunDay: "sun", strength: { enabled: true, equipment: "dumbbells" } }],
    ["half marathon, five runs, two unavailable days, strength", { goal: { distance: "half_marathon" }, runsPerWeek: 5, runningHistory: "over_3_years", unavailableDays: ["mon", "fri"], strength: { enabled: true, equipment: "dumbbells" } }],
    ["10k with pain (cautious variant)", { goal: { distance: "10k" }, runsPerWeek: 4, runningHistory: "1_to_3_years", pain: true, strength: { enabled: true } }],
    ["5k with a recent race (paces) and heart rate", { goal: { distance: "5k" }, runsPerWeek: 4, runningHistory: "1_to_3_years", recentResult: { distanceM: 5000, timeSec: 1650, date: "2026-10-20" }, targetDisplay: "heart_rate", heartRate: { maxBpm: 190 } }],
    ["half marathon, a baseline far below the goal", { goal: { distance: "half_marathon" }, runsPerWeek: 3, weeklyDistanceM: 6000 }],
  ];

  for (const [name, answers] of cases) {
    it(name, () => {
      expect(render(generatePlan({ answers, today: TODAY }))).toMatchSnapshot();
    });
  }
});
