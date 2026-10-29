// Plan validators (design §6.4). They run on generated, edited and blank plans and warn, never block.
// Errors are only for invalid data. Pure and deterministic: same input, same output, no mutation.

export type SessionType = "easy" | "long" | "intervals" | "tempo" | "strength" | "rest" | "custom";

export type StepGoal = { type: "time" | "distance" | "open"; value?: number };
export type RunStep = { kind: "warmup" | "work" | "recovery" | "cooldown"; goal: StepGoal };
export type RepeatStep = { kind: "repeat"; count: number; steps: RunStep[] };
export type ExerciseStep = { kind: "exercise" };
export type ValidatorStep = RunStep | RepeatStep | ExerciseStep;

export interface ValidatorSession {
  id: string;
  /** Local calendar date, YYYY-MM-DD. */
  date: string;
  type: SessionType;
  key?: boolean;
  steps?: ValidatorStep[];
  custom?: { effort?: "easy" | "moderate" | "hard" };
  deletedAt?: string | null;
}

export interface PlanToValidate {
  startDate: string;
  weekCount: number;
  sessions: ValidatorSession[];
  goalDate?: string;
}

export interface ValidatorOptions {
  /** Average weekly running distance the user stated, in metres. */
  baselineWeeklyM?: number;
  params?: Partial<ValidatorParams>;
}

/** Tunable values; to be validated with a coach (§6.4, backlog H.1). */
export interface ValidatorParams {
  /** Largest week-to-week volume increase, as a fraction. */
  maxWeeklyGrowth: number;
  /** Increases smaller than this many metres are never flagged, so small weeks do not trip the cap. */
  growthSlackM: number;
  /** Consecutive weekly increases allowed before a down week is expected. */
  maxRisingWeeks: number;
  /** Largest share of a week's running volume that the long run may take. */
  maxLongRunShare: number;
  /** The final week before the goal must be at most this fraction of the peak week. */
  taperMaxFraction: number;
  /** Plans shorter than this many weeks are not checked for a taper. */
  taperMinWeeks: number;
  /** Pace used to turn time goals into distance when totalling volume, in seconds per km. */
  fallbackPaceSecPerKm: number;
}

export const DEFAULT_PARAMS: ValidatorParams = {
  maxWeeklyGrowth: 0.15,
  growthSlackM: 3000,
  maxRisingWeeks: 3,
  maxLongRunShare: 0.5,
  taperMaxFraction: 0.85,
  taperMinWeeks: 4,
  fallbackPaceSecPerKm: 420,
};

export interface PlanWarning {
  code: string;
  severity: "info" | "caution";
  message: string;
  weekIndex: number;
  sessionIds?: string[];
}

export interface PlanError {
  code: "invalid_plan" | "invalid_date" | "session_outside_plan" | "duplicate_session_id";
  message: string;
  /** Absent for plan-level errors. */
  sessionId?: string;
}

export interface ValidationResult {
  warnings: PlanWarning[];
  errors: PlanError[];
}

const RUN_TYPES: ReadonlySet<SessionType> = new Set(["easy", "long", "intervals", "tempo"]);
const HARD_RUN_TYPES: ReadonlySet<SessionType> = new Set(["long", "intervals", "tempo"]);

/** Whole days since 1970-01-01 for a valid YYYY-MM-DD, or undefined when the date is not real. */
function dayNumber(date: string): number | undefined {
  if (!/^\d{4}-\d{2}-\d{2}$/.test(date)) return undefined;
  const ms = Date.parse(`${date}T00:00:00Z`);
  if (Number.isNaN(ms) || new Date(ms).toISOString().slice(0, 10) !== date) return undefined;
  return ms / 86_400_000;
}

/** Running distance of a session in metres, derived from its steps. Time goals use the fallback pace. */
export function sessionDistanceM(
  session: Pick<ValidatorSession, "type" | "steps">,
  fallbackPaceSecPerKm: number = DEFAULT_PARAMS.fallbackPaceSecPerKm,
): number {
  if (!RUN_TYPES.has(session.type)) return 0;
  const stepM = (step: ValidatorStep): number => {
    if (step.kind === "repeat") return step.count * step.steps.reduce((sum, s) => sum + stepM(s), 0);
    if (step.kind === "exercise") return 0;
    const { type, value } = step.goal;
    if (value === undefined) return 0;
    if (type === "distance") return value;
    if (type === "time") return Math.round((value / fallbackPaceSecPerKm) * 1000);
    return 0;
  };
  return (session.steps ?? []).reduce((sum, s) => sum + stepM(s), 0);
}

const isHard = (s: ValidatorSession): boolean =>
  HARD_RUN_TYPES.has(s.type) || (s.type === "custom" && s.custom?.effort === "hard");

const km = (m: number): string => `${(m / 1000).toFixed(1)} km`;

interface Dated {
  session: ValidatorSession;
  day: number;
  week: number;
}

export function validatePlan(plan: PlanToValidate, options: ValidatorOptions = {}): ValidationResult {
  const params: ValidatorParams = { ...DEFAULT_PARAMS, ...options.params };
  const warnings: PlanWarning[] = [];
  const errors: PlanError[] = [];

  const startDay = dayNumber(plan.startDate);
  if (startDay === undefined || !Number.isInteger(plan.weekCount) || plan.weekCount < 0) {
    errors.push({ code: "invalid_plan", message: "The plan needs a calendar start date and a whole number of weeks." });
    return { warnings, errors };
  }

  // Invalid data first; sessions with errors stay out of the warnings.
  const seen = new Set<string>();
  const dated: Dated[] = [];
  for (const session of plan.sessions) {
    if (session.deletedAt) continue;
    const day = dayNumber(session.date);
    if (day === undefined) {
      errors.push({ code: "invalid_date", message: `Session date "${session.date}" is not a calendar date.`, sessionId: session.id });
      continue;
    }
    if (day < startDay || day >= startDay + plan.weekCount * 7) {
      errors.push({ code: "session_outside_plan", message: `Session on ${session.date} is outside the plan.`, sessionId: session.id });
      continue;
    }
    if (seen.has(session.id)) {
      errors.push({ code: "duplicate_session_id", message: `Session id ${session.id} appears twice.`, sessionId: session.id });
      continue;
    }
    seen.add(session.id);
    dated.push({ session, day, week: Math.floor((day - startDay) / 7) });
  }
  dated.sort((a, b) => a.day - b.day || (a.session.id < b.session.id ? -1 : 1));

  const volume = new Array<number>(plan.weekCount).fill(0);
  const byWeek: Dated[][] = Array.from({ length: plan.weekCount }, () => []);
  for (const d of dated) {
    volume[d.week]! += sessionDistanceM(d.session, params.fallbackPaceSecPerKm);
    byWeek[d.week]!.push(d);
  }
  const vol = (w: number): number => volume[w] ?? 0;
  const warn = (w: Omit<PlanWarning, "severity">) => warnings.push({ severity: "caution", ...w });

  // Conservative first week.
  if (options.baselineWeeklyM !== undefined && vol(0) > options.baselineWeeklyM) {
    warn({
      code: "first_week_above_baseline",
      message: `Week 1 is ${km(vol(0))}, above the ${km(options.baselineWeeklyM)} a week you run now. Start at or below your current volume.`,
      weekIndex: 0,
    });
  }

  // Capped growth, with down weeks.
  let rising = 0;
  for (let w = 1; w < plan.weekCount; w++) {
    const prev = vol(w - 1);
    const cur = vol(w);
    if (prev > 0 && cur > prev * (1 + params.maxWeeklyGrowth) && cur - prev > params.growthSlackM) {
      warn({
        code: "weekly_growth_too_high",
        message: `Week ${w + 1} is ${km(cur)}, up ${Math.round(((cur - prev) / prev) * 100)}% from ${km(prev)}. Keep weekly increases small.`,
        weekIndex: w,
      });
    }
    rising = cur > prev ? rising + 1 : 0;
    if (rising === params.maxRisingWeeks + 1) {
      warn({
        code: "no_down_week",
        message: `Volume has risen for ${rising} weeks in a row by week ${w + 1}. Add an easier week.`,
        weekIndex: w,
      });
    }
  }

  // Easy or rest day between hard sessions.
  const hard = dated.filter((d) => isHard(d.session));
  for (let i = 1; i < hard.length; i++) {
    const a = hard[i - 1]!;
    const b = hard[i]!;
    if (b.day - a.day === 1) {
      warn({
        code: "hard_days_back_to_back",
        message: `Hard sessions on ${a.session.date} and ${b.session.date} are back to back. Leave an easy or rest day between them.`,
        weekIndex: a.week,
        sessionIds: [a.session.id, b.session.id],
      });
    }
  }

  // One protected rest day, and the long run's share of the week.
  for (let w = 0; w < plan.weekCount; w++) {
    const sessions = byWeek[w]!;
    if (sessions.length === 0) continue;
    const busyDays = new Set(sessions.filter((d) => d.session.type !== "rest").map((d) => d.day));
    if (busyDays.size >= 7) {
      warn({ code: "no_rest_day", message: `Week ${w + 1} has a session every day. Keep one rest day.`, weekIndex: w });
    }
    const runs = sessions.filter((d) => sessionDistanceM(d.session, params.fallbackPaceSecPerKm) > 0);
    const longest = sessions
      .filter((d) => d.session.type === "long")
      .reduce((max, d) => Math.max(max, sessionDistanceM(d.session, params.fallbackPaceSecPerKm)), 0);
    if (runs.length >= 2 && vol(w) > 0 && longest / vol(w) > params.maxLongRunShare) {
      warn({
        code: "long_run_share_high",
        message: `The long run is ${Math.round((longest / vol(w)) * 100)}% of week ${w + 1}. Spread more of the week across other runs.`,
        weekIndex: w,
        sessionIds: sessions.filter((d) => d.session.type === "long").map((d) => d.session.id),
      });
    }
  }

  // Taper before the goal date.
  const goalDay = plan.goalDate === undefined ? undefined : dayNumber(plan.goalDate);
  if (goalDay !== undefined && plan.weekCount >= params.taperMinWeeks) {
    const finalWeek = Math.min(Math.max(Math.floor((goalDay - startDay) / 7), 0), plan.weekCount - 1);
    const peak = Math.max(0, ...volume.slice(0, finalWeek));
    if (peak > 0 && vol(finalWeek) > peak * params.taperMaxFraction) {
      warn({
        code: "no_taper",
        message: `Week ${finalWeek + 1}, before the goal, is ${km(vol(finalWeek))}, close to the ${km(peak)} peak. Ease off before race day.`,
        weekIndex: finalWeek,
      });
    }
  }

  // Strength away from key hard runs and the long run: not on the day, nor the day before.
  for (const lift of dated.filter((d) => d.session.type === "strength")) {
    const near = dated.find(
      (d) => (HARD_RUN_TYPES.has(d.session.type) || d.session.key === true) && d.session.type !== "strength" && (d.day === lift.day || d.day === lift.day + 1),
    );
    if (near) {
      warn({
        code: "strength_near_key_session",
        message: `Strength on ${lift.session.date} is too close to the ${near.session.type} session on ${near.session.date}. Move it away from hard days.`,
        weekIndex: lift.week,
        sessionIds: [lift.session.id, near.session.id],
      });
    }
  }

  warnings.sort((a, b) => a.weekIndex - b.weekIndex || (a.code < b.code ? -1 : a.code > b.code ? 1 : 0));
  return { warnings, errors };
}
