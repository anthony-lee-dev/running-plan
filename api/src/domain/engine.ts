// The plan rule engine (design §6), 5K preset. `generatePlan` turns interview answers into a draft plan with the
// assumptions it made and the warnings it found. Deterministic and pure: the same inputs give the same draft, and
// nothing is read from the clock or the network. The presets and every number below are starting values to be
// reviewed by a qualified coach (backlog H.1); the validators (§6.4) run over the result and warn, never block.
import type { InterviewAnswers } from "./interview";
import { WEEKDAYS } from "./interview";
import { derivePaces, heartRateRange, resolveTargetKind, type DerivedPaces, type PaceRange, type Zone } from "./paces";
import { PRESETS, type GoalType, type PresetParams, type Tier } from "./presets";
import { placeStrength, strengthSession, type StrengthStep } from "./strength";
import { sessionDistanceM, validatePlan, type ValidatorSession } from "./validators";

/** Bump when any number below changes (for example after the coach review, backlog H.1): plans record it. */
export const ENGINE_VERSION = "0.2.0"; // 0.2.0: 10K and half marathon presets, strength sessions

export interface GenerateInput {
  answers: InterviewAnswers;
  /** The user's local date, YYYY-MM-DD. */
  today: string;
  /** An explicit preset; normally the goal distance picks it. */
  presetId?: string;
}

export type Effort = "easy" | "moderate" | "hard";
export type StepTarget =
  | { type: "pace"; range: PaceRange }
  | { type: "heart_rate"; range: { minBpm: number; maxBpm: number } }
  | { type: "effort"; effort: Effort };
export interface RunStep {
  kind: "warmup" | "work" | "recovery" | "cooldown";
  goal: { type: "distance"; value: number };
  target: StepTarget;
}
export interface RepeatStep {
  kind: "repeat";
  count: number;
  steps: RunStep[];
}
export type Step = RunStep | RepeatStep | StrengthStep;

export interface DraftSession {
  date: string;
  type: "easy" | "long" | "intervals" | "tempo" | "strength";
  title: string;
  key: boolean;
  status: "planned";
  owner: "system";
  steps: Step[];
  notes?: string;
}
export interface DraftWeek {
  index: number;
  phase: "base" | "build" | "peak" | "taper";
}
export interface Assumption {
  code: string;
  message: string;
}
export interface DraftWarning {
  code: string;
  severity: "info" | "caution";
  message: string;
  weekIndex?: number;
  suggestedDate?: string;
}
export interface PlanDraft {
  goal: { type: GoalType; date?: string; targetTimeSec?: number };
  startDate: string;
  weekCount: number;
  source: "rules";
  engine: { presetId: string; version: string; interview: InterviewAnswers };
  adaptive: true;
  weeks: DraftWeek[];
  sessions: DraftSession[];
  assumptions: Assumption[];
  warnings: DraftWarning[];
}

// ---- Parameters shared by every preset (the per-preset ones are in presets.ts) ----


const FIRST_WEEK_SHARE = 0.85; // of the stated baseline: a conservative start
const CAUTIOUS = { firstWeekShare: 0.7, growth: 0.05, capShare: 0.75, downEvery: 3 };
const DOWN_EVERY = 4;
const DOWN_FACTOR = 0.88; // small enough that coming back up stays inside the validators' growth cap
const TAPER_FACTORS = [0.8, 0.6]; // the last two weeks, as shares of the peak week
const FEASIBLE_MARGIN = 0.95; // room for quality sessions that round to whole repeats
/** Shares of the week's distance, by runs per week: long run, first quality session, second quality, each easy run. */
const SHARES: Record<number, { long: number; q1: number; q2: number; easy: number[] }> = {
  3: { long: 0.38, q1: 0.27, q2: 0, easy: [0.35] },
  4: { long: 0.33, q1: 0.25, q2: 0, easy: [0.21, 0.21] },
  5: { long: 0.3, q1: 0.2, q2: 0.15, easy: [0.175, 0.175] },
};
const MIN_RUN_M = 1000;

/** No plan fits the answers (for example fewer than three days a week to run on). The generate route answers 422. */
export class NoPlanFitsError extends RangeError {
  override name = "NoPlanFitsError";
}

// ---- Dates ----

function dayNumber(date: string): number {
  const ms = Date.parse(`${date}T00:00:00Z`);
  if (!/^\d{4}-\d{2}-\d{2}$/.test(date) || Number.isNaN(ms) || new Date(ms).toISOString().slice(0, 10) !== date) {
    throw new RangeError(`not a calendar date: "${date}"`);
  }
  return ms / 86_400_000;
}
const dateOf = (day: number): string => new Date(day * 86_400_000).toISOString().slice(0, 10);
/** Monday is 0. 1970-01-01 was a Thursday. */
const weekdayIndex = (day: number): number => (((day + 3) % 7) + 7) % 7;
const round100 = (m: number): number => Math.round(m / 100) * 100;
const circular = (a: number, b: number): number => Math.min(Math.abs(a - b), 7 - Math.abs(a - b));

// ---- Load ----

/** Weekly running volume in metres for each week: conservative start, capped growth, down weeks, taper. */
function volumeSchedule(weekCount: number, start: number, growth: number, cap: number, downEvery: number): number[] {
  const volumes: number[] = [];
  const peakCap = cap;
  let level = start; // the last full (non-down) week
  const isDown = (w: number) => (w + 1) % downEvery === 0 && w < weekCount - 2;
  for (let w = 0; w < weekCount; w++) {
    if (w >= weekCount - 2) {
      const peak = Math.max(...volumes);
      volumes.push(round100(peak * TAPER_FACTORS[w - (weekCount - 2)]!));
    } else if (w === 0) volumes.push(start);
    else if (isDown(w)) volumes.push(round100(level * DOWN_FACTOR));
    else if (isDown(w - 1)) volumes.push(level); // back to the level before the down week, no growth yet
    else {
      level = Math.min(round100(level * (1 + growth)), peakCap);
      volumes.push(level);
    }
  }
  return volumes;
}

function phaseOf(week: number, weekCount: number): DraftWeek["phase"] {
  const taperStart = weekCount - 2;
  if (week >= taperStart) return "taper";
  const body = taperStart;
  const base = Math.max(2, Math.round(0.3 * body));
  const peak = Math.max(1, Math.round(0.2 * body));
  return week < base ? "base" : week >= body - peak ? "peak" : "build";
}

// ---- Placing runs on days ----

type Role = "long" | "q1" | "q2" | "easy";

function placeRuns(startWeekday: number, unavailable: Set<number>, runsWanted: number, preferredLong: number) {
  const available = [0, 1, 2, 3, 4, 5, 6].filter((k) => !unavailable.has((startWeekday + k) % 7));
  if (available.length < 3) throw new NoPlanFitsError("at least 3 days a week must be available to run");
  const runs = Math.min(runsWanted, available.length);
  const weekdayOf = (k: number) => (startWeekday + k) % 7;

  let longChanged = false;
  let long = available.find((k) => weekdayOf(k) === preferredLong);
  if (long === undefined) {
    longChanged = true;
    // The nearest available day, later in the week on a tie.
    long = [...available].sort((a, b) => circular(weekdayOf(a), preferredLong) - circular(weekdayOf(b), preferredLong) || b - a)[0]!;
  }
  const chosen: { offset: number; role: Role }[] = [{ offset: long, role: "long" }];
  const free = () => available.filter((k) => !chosen.some((c) => c.offset === k));
  const score = (k: number, among = chosen) => Math.min(...among.map((c) => circular(k, c.offset)));
  const farthest = (among = chosen) => free().sort((a, b) => score(b, among) - score(a, among) || a - b)[0]!;
  // A hard session needs an easy or rest day on each side (counting across the week boundary). The first quality
  // session takes the best day it can; a second one is only added when a day with that space exists, else it is an easy run.
  chosen.push({ offset: farthest(), role: "q1" });
  const hard = () => chosen.filter((c) => c.role !== "easy");
  if (runs >= 5) {
    const spaced = free().filter((k) => score(k, hard()) >= 2);
    chosen.push(spaced.length > 0 ? { offset: spaced.sort((a, b) => score(b, hard()) - score(a, hard()) || a - b)[0]!, role: "q2" } : { offset: farthest(), role: "easy" });
  }
  while (chosen.length < runs) chosen.push({ offset: farthest(), role: "easy" });
  return { slots: chosen.sort((a, b) => a.offset - b.offset), runs, longChanged, runsReduced: runs < runsWanted };
}

// ---- Sessions ----

interface TargetContext {
  kind: ReturnType<typeof resolveTargetKind>;
  paces: DerivedPaces;
  heartRate: InterviewAnswers["heartRate"];
}

function target(ctx: TargetContext, zone: Zone, effort: Effort): StepTarget {
  if (ctx.kind === "pace") {
    const range = ctx.paces[zone];
    if (range) return { type: "pace", range: { ...range } };
  } else if (ctx.kind === "heart_rate") {
    const range = heartRateRange(ctx.heartRate, zone);
    if (range) return { type: "heart_rate", range };
  }
  return { type: "effort", effort };
}

const run = (kind: RunStep["kind"], metres: number, t: StepTarget): RunStep => ({ kind, goal: { type: "distance", value: metres }, target: t });

function easyRun(date: string, metres: number, ctx: TargetContext): DraftSession {
  return { date, type: "easy", title: "Easy run", key: false, status: "planned", owner: "system", steps: [run("work", metres, target(ctx, "easy", "easy"))] };
}

function longRun(date: string, metres: number, ctx: TargetContext, progressive: boolean): DraftSession {
  const base = { date, type: "long" as const, title: "Long run", key: true, status: "planned" as const, owner: "system" as const };
  if (!progressive) return { ...base, steps: [run("work", metres, target(ctx, "long", "easy"))] };
  // Progressive: the last third at a steadier effort, so the long run teaches the legs to run on tired.
  const steady = Math.max(1000, round100(metres / 3));
  return { ...base, title: "Progressive long run", steps: [run("work", metres - steady, target(ctx, "long", "easy")), run("work", steady, target(ctx, "tempo", "moderate"))] };
}

function tempoRun(date: string, wanted: number, ctx: TargetContext): DraftSession {
  const edge = Math.max(300, round100(wanted * 0.2));
  const block = Math.max(500, wanted - 2 * edge);
  return {
    date, type: "tempo", title: "Tempo run", key: true, status: "planned", owner: "system",
    steps: [run("warmup", edge, target(ctx, "easy", "easy")), run("work", block, target(ctx, "tempo", "moderate")), run("cooldown", edge, target(ctx, "easy", "easy"))],
  };
}

function intervalRun(date: string, wanted: number, repM: number, ctx: TargetContext): DraftSession {
  const edge = Math.max(300, round100(wanted * 0.2));
  const recoveryM = 200;
  const reps = Math.min(10, Math.max(2, Math.round(Math.max(800, wanted - 2 * edge) / (repM + recoveryM))));
  return {
    date, type: "intervals", title: "Intervals", key: true, status: "planned", owner: "system",
    steps: [
      run("warmup", edge, target(ctx, "easy", "easy")),
      { kind: "repeat", count: reps, steps: [run("work", repM, target(ctx, "interval", "hard")), run("recovery", recoveryM, { type: "effort", effort: "easy" })] },
      run("cooldown", edge, target(ctx, "easy", "easy")),
    ],
  };
}

const metresOf = (s: DraftSession): number => sessionDistanceM(s as unknown as ValidatorSession);

// ---- The engine ----

export function generatePlan(input: GenerateInput): PlanDraft {
  const { answers } = input;
  const preset: PresetParams | undefined = PRESETS[(input.presetId ?? answers.goal.distance) as GoalType];
  if (!preset) throw new Error(`No preset called "${input.presetId}"`);
  const today = dayNumber(input.today);
  const assumptions: Assumption[] = [];
  const warnings: DraftWarning[] = [];

  // Experience tier. Without a history the conservative one applies.
  const tier: Tier =
    answers.runningHistory === "over_3_years" ? "experienced" : answers.runningHistory === "1_to_3_years" ? "intermediate" : "beginner";
  const tierParams = preset.tiers[tier];
  if (!answers.runningHistory) assumptions.push({ code: "tier_default", message: "You didn't say how long you've been running, so this plan starts as it would for a newer runner." });

  const cautious = answers.pain === true;
  if (cautious) {
    assumptions.push({ code: "cautious_variant", message: "Because of the pain you mentioned, this plan builds more slowly and leaves out hard interval sessions." });
    warnings.push({ code: "pain_flag", severity: "caution", message: "You mentioned pain or injury. This plan is gentler, but it is not medical advice: please talk to a qualified professional before you start." });
  }

  // Baseline and the first week.
  let baseline = answers.weeklyDistanceM;
  if (baseline === undefined) {
    baseline = tierParams.baselineM;
    assumptions.push({ code: "baseline_default", message: `You didn't say how far you run in a week, so we assumed ${baseline / 1000} km.` });
  }

  // Runs per week and the days they fall on.
  let runsWanted = answers.runsPerWeek ?? 3;
  if (answers.runsPerWeek === undefined) assumptions.push({ code: "runs_per_week_default", message: "You didn't say how many days a week you want to run, so we planned 3." });
  runsWanted = Math.min(5, Math.max(3, runsWanted));

  // Plan length and start. The plan always ends on the goal date, so the taper falls just before it.
  let startDay = today;
  let weekCount = tierParams.weeks;
  let goalDate: string | undefined;
  let extraBaseWeeks = 0;
  if (answers.goal.date !== undefined) {
    const goalDay = dayNumber(answers.goal.date);
    const fit = Math.floor((goalDay - today + 1) / 7); // whole weeks from today to the goal date
    if (goalDay < today) {
      warnings.push({ code: "later_goal_date", severity: "caution", message: "Your goal date has already passed, so this plan has no goal date. Pick a later date to build towards.", suggestedDate: dateOf(today + weekCount * 7 - 1) });
    } else if (fit > preset.maxWeeks) {
      goalDate = answers.goal.date;
      weekCount = Math.min(fit, preset.maxWeeks + preset.extraBaseWeeksMax);
      extraBaseWeeks = weekCount - preset.maxWeeks;
      startDay = goalDay - weekCount * 7 + 1; // the plan always ends on the goal date
      if (fit > weekCount) {
        warnings.push({ code: "goal_date_far", severity: "info", message: `Your goal is ${fit} weeks away, so the plan is ${weekCount} weeks long and starts on ${dateOf(startDay)}, with ${extraBaseWeeks} extra base weeks, instead of today.` });
      } else {
        warnings.push({ code: "base_phase_added", severity: "info", message: `Your goal is ${fit} weeks away, so the plan starts with ${extraBaseWeeks} extra base weeks at an easy, steady load before it builds.` });
        if (startDay !== today) assumptions.push({ code: "start_date_aligned", message: `The plan starts on ${dateOf(startDay)} so that its last day is your goal date.` });
      }
    } else if (fit < preset.minWeeks) {
      goalDate = answers.goal.date;
      weekCount = preset.minWeeks; // never compress the ramp
      warnings.push({ code: "later_goal_date", severity: "caution", message: `${preset.minWeeks} weeks is the shortest sensible ${preset.name} plan and your goal date is sooner. Consider a later goal date.`, suggestedDate: dateOf(startDay + preset.minWeeks * 7 - 1) });
    } else {
      goalDate = answers.goal.date;
      weekCount = fit;
      startDay = goalDay - fit * 7 + 1;
      if (startDay !== today) assumptions.push({ code: "start_date_aligned", message: `The plan starts on ${dateOf(startDay)} so that its last day is your goal date.` });
    }
  }
  if (goalDate === undefined && answers.goal.date === undefined) {
    assumptions.push({ code: "plan_length_default", message: `With no goal date we planned ${weekCount} weeks, the usual length for a ${tier} runner.` });
  }

  const startWeekday = weekdayIndex(startDay);
  const unavailable = new Set((answers.unavailableDays ?? []).map((d) => WEEKDAYS.indexOf(d)));
  const preferredLong = WEEKDAYS.indexOf(answers.longRunDay ?? "sun");
  if (answers.longRunDay === undefined) assumptions.push({ code: "long_run_day_default", message: "You didn't pick a long run day, so we chose Sunday if it's free." });
  const placed = placeRuns(startWeekday, unavailable, runsWanted, preferredLong);
  if (placed.runsReduced) assumptions.push({ code: "runs_reduced", message: `Only ${placed.runs} days a week are free, so the plan has ${placed.runs} runs, not ${runsWanted}.` });
  if (placed.longChanged) assumptions.push({ code: "long_run_day_changed", message: `${answers.longRunDay ?? "Sunday"} isn't free, so the long run is on another day.` });

  // The most a week can hold without any single run passing its limit, given the shares each run takes.
  const shares = SHARES[Math.max(3, placed.runs)]!;
  const feasible = Math.floor(
    FEASIBLE_MARGIN * Math.min(preset.longRunMaxM / shares.long, preset.qualityMaxM / shares.q1, shares.q2 > 0 ? preset.qualityMaxM / shares.q2 : Infinity, preset.easyRunMaxM / Math.max(...shares.easy)),
  );
  const cap = Math.min(cautious ? Math.round(tierParams.capM * CAUTIOUS.capShare) : tierParams.capM, feasible);
  const wantedFirst = Math.max(round100(baseline * (cautious ? CAUTIOUS.firstWeekShare : FIRST_WEEK_SHARE)), 5000, placed.runs * 1800);
  const firstWeek = Math.min(wantedFirst, round100(cap));
  if (firstWeek < wantedFirst) {
    assumptions.push({ code: "weekly_distance_capped", message: `You run more than this ${preset.name} plan builds to, so it holds at about ${Math.round(firstWeek / 1000)} km a week.` });
  }
  // Extra base weeks hold the conservative start; the build, down weeks and taper follow over the usual length.
  if (answers.weeklyDistanceM !== undefined && answers.weeklyDistanceM < preset.farBelowBaselineM) {
    warnings.push({
      code: "baseline_far_below_goal",
      severity: "caution",
      message: `You're running very little right now, and this plan starts at about ${Math.round(firstWeek / 1000)} km a week, which may be a big step. A run-walk start or a later goal date would suit you better.`,
      suggestedDate: dateOf(startDay + (weekCount + 4) * 7 - 1),
    });
  }
  const volumes = [
    ...Array<number>(extraBaseWeeks).fill(firstWeek),
    ...volumeSchedule(weekCount - extraBaseWeeks, firstWeek, cautious ? Math.min(tierParams.growth, CAUTIOUS.growth) : tierParams.growth, cap, cautious ? CAUTIOUS.downEvery : DOWN_EVERY),
  ];

  // Paces and targets.
  let paces: DerivedPaces;
  try {
    paces = derivePaces({ ...(answers.recentResult ? { recentResult: answers.recentResult } : {}), today: input.today });
  } catch {
    // A result that is not a real run (a typo, or dated in the future): do not guess paces from it.
    paces = { source: "none" };
    assumptions.push({ code: "result_ignored", message: "We couldn't use the recent run you entered (the distance and time don't look like a real run, or the date is in the future), so this plan uses effort targets." });
  }
  const kind = resolveTargetKind({ ...(answers.targetDisplay ? { display: answers.targetDisplay } : {}), paces, ...(answers.heartRate ? { heartRate: answers.heartRate } : {}) });
  if (paces.source === "none") assumptions.push({ code: "paces_effort_only", message: "Without a recent run or race we use effort targets (easy, moderate, hard). Tell us about your first hard effort and we'll calibrate paces." });
  else assumptions.push({ code: "paces_derived", message: `Training paces are based on ${paces.basedOn}${paces.source === "estimated" ? ", so treat them as an estimate" : ""}.` });
  if (answers.targetDisplay === "heart_rate" && kind !== "heart_rate") {
    assumptions.push({ code: "heart_rate_unavailable", message: "Heart rate targets need your maximum heart rate or zones, so this plan shows effort instead." });
  }
  const ctx: TargetContext = { kind, paces, heartRate: answers.heartRate };
  const strengthOn = answers.strength?.enabled === true;
  const equipment = answers.strength?.equipment ?? "bodyweight";
  if (strengthOn && answers.strength?.equipment === undefined) assumptions.push({ code: "strength_equipment_default", message: "You didn't say what equipment you have, so the strength sessions use only your bodyweight." });

  // Sessions, week by week.
  const weeks: DraftWeek[] = [];
  const sessions: DraftSession[] = [];
  let build = 0;
  let strengthShort = false;
  for (let w = 0; w < weekCount; w++) {
    const inPlan = w - extraBaseWeeks; // the week within the usual-length plan; negative for the extra base weeks
    const phase = inPlan < 0 ? "base" : phaseOf(inPlan, weekCount - extraBaseWeeks);
    weeks.push({ index: w, phase });
    const volume = volumes[w]!;
    const alternate = preset.quality1 === "alternate";
    const quality1 = cautious || !alternate || phase === "base" || phase === "taper" ? "tempo" : phase === "peak" ? "intervals" : build++ % 2 === 0 ? "intervals" : "tempo";
    const progress = inPlan > 0 && weekCount - extraBaseWeeks > 1 ? inPlan / (weekCount - extraBaseWeeks - 1) : 0;
    const repM = preset.repLengthsM[progress < 0.4 ? 0 : progress < 0.7 ? 1 : 2];

    const day = (offset: number) => dateOf(startDay + w * 7 + offset);
    const weekSessions: DraftSession[] = [];
    let longM = Math.min(round100(volume * shares.long), preset.longRunMaxM);
    const qualityOf = (role: "q1" | "q2", offset: number): DraftSession | undefined => {
      const wanted = round100(volume * (role === "q1" ? shares.q1 : shares.q2));
      if (role === "q1") return quality1 === "intervals" ? intervalRun(day(offset), wanted, repM, ctx) : tempoRun(day(offset), wanted, ctx);
      if (phase === "base" || phase === "taper") return undefined;
      return preset.quality2 === "intervals" && !cautious ? intervalRun(day(offset), wanted, repM, ctx) : tempoRun(day(offset), wanted, ctx);
    };
    const easySlots = placed.slots.filter((s) => s.role === "easy");
    const qualitySessions: DraftSession[] = [];
    const easyFromQ2: number[] = [];
    for (const slot of placed.slots) {
      if (slot.role === "q1" || slot.role === "q2") {
        const s = qualityOf(slot.role, slot.offset);
        if (s) qualitySessions.push(s);
        else easyFromQ2.push(slot.offset); // no second hard session in base or taper weeks: an easy run instead
      }
    }
    const qualityM = qualitySessions.reduce((sum, s) => sum + metresOf(s), 0);
    const easyOffsets = [...easySlots.map((s) => s.offset), ...easyFromQ2].sort((a, b) => a - b);
    // The easy runs take what is left of the week, but never less than a short run each.
    if (volume - longM - qualityM < easyOffsets.length * MIN_RUN_M) longM = Math.max(MIN_RUN_M, volume - qualityM - easyOffsets.length * MIN_RUN_M);
    const remaining = Math.max(easyOffsets.length * MIN_RUN_M, volume - longM - qualityM);
    const each = easyOffsets.length > 0 ? Math.floor(remaining / easyOffsets.length / 100) * 100 : 0;
    easyOffsets.forEach((offset, i) => {
      const metres = i === 0 ? remaining - each * (easyOffsets.length - 1) : each;
      weekSessions.push(easyRun(day(offset), metres, ctx));
    });
    weekSessions.push(longRun(day(placed.slots.find((s) => s.role === "long")!.offset), longM, ctx, preset.progressiveLong && !cautious && (phase === "build" || phase === "peak")), ...qualitySessions);
    if (strengthOn) {
      // One or two short sessions, away from the hard runs and the day before them.
      const count = cautious || runsWanted < 4 || tier === "beginner" ? 1 : 2;
      // The hard slots, not this week's hard sessions: a second quality session starts in the build, and a strength
      // session on the last day of a base week must not land the day before it.
      const hardOffsets = new Set(placed.slots.filter((slot) => slot.role !== "easy").map((slot) => slot.offset));
      const offsets = placeStrength({
        runs: weekSessions.map((s) => {
          const offset = Math.round(dayNumber(s.date) - (startDay + w * 7));
          return { offset, hard: hardOffsets.has(offset) };
        }),
        unavailable: new Set([...unavailable].map((weekday) => (weekday - startWeekday + 7) % 7)),
        count,
      });
      offsets.forEach((offset, i) => {
        const dose = strengthSession(equipment, phase, w + i, cautious);
        weekSessions.push({ date: day(offset), type: "strength", title: "Strength", key: false, status: "planned", owner: "system", steps: dose.steps, notes: `About ${dose.minutes} minutes. Stop any movement that hurts.` });
      });
      if (offsets.length < count) strengthShort = true;
    }
    sessions.push(...weekSessions.sort((a, b) => (a.date < b.date ? -1 : 1)));
  }

  if (strengthShort) assumptions.push({ code: "strength_no_room", message: "There isn't a day for every strength session away from your hard runs, so some weeks have fewer." });

  // The validators (§6.4) have the last word: their findings join the engine's own notices.
  const validated = validatePlan(
    {
      startDate: dateOf(startDay),
      weekCount,
      sessions: sessions.map((s, i) => ({ ...(s as unknown as ValidatorSession), id: `draft-${i}` })),
      ...(goalDate ? { goalDate } : {}),
    },
    { baselineWeeklyM: baseline },
  );
  for (const w of validated.warnings) warnings.push({ code: w.code, severity: w.severity, message: w.message, weekIndex: w.weekIndex });

  return {
    goal: { type: preset.id, ...(goalDate ? { date: goalDate } : {}), ...(answers.goal.targetTimeSec !== undefined ? { targetTimeSec: answers.goal.targetTimeSec } : {}) },
    startDate: dateOf(startDay),
    weekCount,
    source: "rules",
    engine: { presetId: preset.id, version: ENGINE_VERSION, interview: structuredClone(answers) },
    adaptive: true,
    weeks,
    sessions,
    assumptions,
    warnings,
  };
}

