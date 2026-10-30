// The plan presets (design 6.2). Every number is a starting value for the coach review (backlog H.1); bump
// `ENGINE_VERSION` in engine.ts when one changes.

export type GoalType = "5k" | "10k" | "half_marathon";
export type Tier = "beginner" | "intermediate" | "experienced";

export interface TierParams {
  /** Weekly distance assumed when the user did not say. */
  baselineM: number;
  /** Largest weekly growth, as a fraction. */
  growth: number;
  /** The most a peak week reaches. */
  capM: number;
  /** The usual plan length with no goal date. */
  weeks: number;
}

export interface PresetParams {
  id: GoalType;
  /** For messages: "5K", "10K", "half marathon". */
  name: string;
  /** Shortest and longest plan length for a goal date; the preset's typical range (design 6.2). */
  minWeeks: number;
  maxWeeks: number;
  /** A goal further than `maxWeeks` away gets up to this many extra base weeks; beyond that the plan starts later. */
  extraBaseWeeksMax: number;
  tiers: Record<Tier, TierParams>;
  /** Longest single sessions: the long run, a quality session, an easy run. */
  longRunMaxM: number;
  qualityMaxM: number;
  easyRunMaxM: number;
  /** Below this weekly distance the runner is not running regularly yet (design 6.5). */
  farBelowBaselineM: number;
  /** Length of each interval rep early, mid and late in the plan. */
  repLengthsM: [number, number, number];
  /** The first quality session alternates tempo and intervals through the build, or is always tempo. */
  quality1: "alternate" | "tempo";
  /** The second quality session of a five-run week. */
  quality2: "tempo" | "intervals";
  /** The long run finishes at a steadier effort in the build and peak (half marathon). */
  progressiveLong: boolean;
}

export const PRESETS: Record<GoalType, PresetParams> = {
  "5k": {
    id: "5k",
    name: "5K",
    minWeeks: 8,
    maxWeeks: 12,
    extraBaseWeeksMax: 4,
    tiers: {
      beginner: { baselineM: 10_000, growth: 0.07, capM: 24_000, weeks: 12 },
      intermediate: { baselineM: 20_000, growth: 0.08, capM: 36_000, weeks: 10 },
      experienced: { baselineM: 30_000, growth: 0.08, capM: 48_000, weeks: 8 },
    },
    longRunMaxM: 14_000,
    qualityMaxM: 12_000,
    easyRunMaxM: 10_000,
    farBelowBaselineM: 4000,
    repLengthsM: [400, 600, 800],
    quality1: "alternate",
    quality2: "tempo",
    progressiveLong: false,
  },
  "10k": {
    id: "10k",
    name: "10K",
    minWeeks: 8,
    maxWeeks: 14,
    extraBaseWeeksMax: 4,
    tiers: {
      beginner: { baselineM: 12_000, growth: 0.07, capM: 32_000, weeks: 12 },
      intermediate: { baselineM: 25_000, growth: 0.08, capM: 45_000, weeks: 10 },
      experienced: { baselineM: 38_000, growth: 0.08, capM: 60_000, weeks: 8 },
    },
    longRunMaxM: 18_000,
    qualityMaxM: 14_000,
    easyRunMaxM: 12_000,
    farBelowBaselineM: 8000,
    repLengthsM: [800, 1000, 1200],
    quality1: "alternate",
    quality2: "tempo",
    progressiveLong: false,
  },
  half_marathon: {
    id: "half_marathon",
    name: "half marathon",
    minWeeks: 10,
    maxWeeks: 16,
    extraBaseWeeksMax: 4,
    tiers: {
      beginner: { baselineM: 15_000, growth: 0.07, capM: 40_000, weeks: 16 },
      intermediate: { baselineM: 30_000, growth: 0.08, capM: 55_000, weeks: 14 },
      experienced: { baselineM: 45_000, growth: 0.08, capM: 70_000, weeks: 12 },
    },
    longRunMaxM: 24_000,
    qualityMaxM: 16_000,
    easyRunMaxM: 14_000,
    farBelowBaselineM: 12_000,
    repLengthsM: [1000, 1200, 1600],
    quality1: "tempo",
    quality2: "intervals",
    progressiveLong: true,
  },
};
