// The interview answers (design Appendix B), in the shape of `InterviewAnswers` in spec/openapi.yaml.
// Every field but the goal is optional: a skipped question takes the engine's conservative default.

export type Weekday = "mon" | "tue" | "wed" | "thu" | "fri" | "sat" | "sun";
export const WEEKDAYS: readonly Weekday[] = ["mon", "tue", "wed", "thu", "fri", "sat", "sun"];

export type GoalDistance = "5k" | "10k" | "half_marathon";
export type RunningHistory = "new_or_returning" | "under_1_year" | "1_to_3_years" | "over_3_years";

export interface InterviewAnswers {
  goal: { distance: GoalDistance; date?: string; targetTimeSec?: number };
  recentResult?: { distanceM: number; timeSec: number; date?: string };
  /** Average weekly running distance over the last four weeks, in metres. */
  weeklyDistanceM?: number;
  longestRunM?: number;
  runningHistory?: RunningHistory;
  runsPerWeek?: number;
  unavailableDays?: Weekday[];
  longRunDay?: Weekday;
  /** Coarse flag only; true selects the cautious variant. */
  pain?: boolean;
  strength?: { enabled: boolean; equipment?: "bodyweight" | "dumbbells" };
  targetDisplay?: "pace" | "heart_rate" | "effort";
  heartRate?: { maxBpm?: number; zones?: { minBpm: number; maxBpm: number }[] };
}
