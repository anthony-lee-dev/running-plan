// The proposal engine (design 6.6): `proposeAdjustments` looks at what happened and suggests changes to the plan.
// It never edits the plan and never applies anything: the user accepts or dismisses each proposal. Pure and
// deterministic. Every number is a starting value for the coach review (backlog H.1); bump
// `PROPOSAL_RULES_VERSION` when one changes.
import { sessionDistanceM, type ValidatorSession } from "./validators";

export const PROPOSAL_RULES_VERSION = "0.1.0";

export type SessionType = "easy" | "long" | "intervals" | "tempo" | "strength" | "rest" | "custom";

export interface RunStepInput {
  kind: "warmup" | "work" | "recovery" | "cooldown";
  goal: { type: "time" | "distance" | "open"; value?: number };
  target?: unknown;
  note?: string;
}
export interface RepeatStepInput {
  kind: "repeat";
  count: number;
  steps: RunStepInput[];
}
export interface ExerciseStepInput {
  kind: "exercise";
  exerciseId: string;
  sets: number;
  reps?: number;
  durationSec?: number;
  restSec?: number;
}
export type StepInput = RunStepInput | RepeatStepInput | ExerciseStepInput;

export interface SessionContent {
  date: string;
  type: SessionType;
  title?: string;
  key?: boolean;
  status: "planned" | "done" | "skipped";
  owner: "system" | "user";
  steps: StepInput[];
  custom?: unknown;
  notes?: string;
}
export interface SessionInput extends SessionContent {
  id: string;
}
export interface PlanInput {
  /** Whether the engine may propose adjustments: on for rule-based plans, off for blank plans unless opted in. */
  adaptive: boolean;
  source: "blank" | "rules" | "ai";
  sessions: SessionInput[];
}
export interface CheckInInput {
  sessionId: string;
  when: "before" | "after";
  /** 1 (awful) to 5 (great). */
  feel: number;
  /** Perceived effort, 1 to 10. */
  effortFelt?: number | undefined;
  pain?: boolean | undefined;
}
export interface MatchInput {
  sessionId: string;
  status: "suggested" | "confirmed";
}

export type ProposalChange =
  | { op: "update"; sessionId: string; before: SessionContent; after: SessionContent; userOwned: boolean }
  | { op: "delete"; sessionId: string; before: SessionContent; userOwned: boolean };

export interface ProposalDraft {
  /** Stable while the facts behind it stay the same, so a proposal that was dismissed is not made again. */
  key: string;
  kind: "adjustment";
  creator: { type: "rules"; version: string };
  reason: string;
  /** Raised straight away (pain, a missed key session) rather than waiting for the weekly review. */
  urgent: boolean;
  changes: ProposalChange[];
}

// ---- Parameters ----

const MISSED_LOOKBACK_DAYS = 14;
const PAIN_LOOKBACK_DAYS = 7;
const RECENT_CHECKINS = 3;
const HARD_EFFORT = 8; // perceived effort at or above this, or a feel of 1, is "much harder than planned"
const EASY_EFFORT = 4;
const EASY_FEEL = 4;
const HARD_COUNT = 2; // of the recent check-ins
const EASE_FACTOR = 0.85;
const PAIN_FACTOR = 0.7;
const PROGRESS_FACTOR = 1.05;
const MIN_SESSION_M = 800;
const ROUND_M = 50;
const RUN_TYPES: ReadonlySet<SessionType> = new Set(["easy", "long", "intervals", "tempo"]);

// ---- Helpers ----

/** Dates come from a validated plan; a malformed one is a bug upstream, so it throws rather than being skipped. */
function dayNumber(date: string): number {
  const ms = Date.parse(`${date}T00:00:00Z`);
  if (!/^\d{4}-\d{2}-\d{2}$/.test(date) || Number.isNaN(ms) || new Date(ms).toISOString().slice(0, 10) !== date) {
    throw new RangeError(`not a calendar date: "${date}"`);
  }
  return ms / 86_400_000;
}

/** The content fields of a session, copied. Other fields a stored session may carry (revision, plan id...) stay out. */
const content = (s: SessionInput): SessionContent =>
  structuredClone({
    date: s.date,
    type: s.type,
    ...(s.title !== undefined ? { title: s.title } : {}),
    ...(s.key !== undefined ? { key: s.key } : {}),
    status: s.status,
    owner: s.owner,
    steps: s.steps,
    ...(s.custom !== undefined ? { custom: s.custom } : {}),
    ...(s.notes !== undefined ? { notes: s.notes } : {}),
  });
const roundTo = (value: number, step: number): number => Math.round(value / step) * step;

function scaleSteps(steps: StepInput[], factor: number): StepInput[] {
  // Short steps (a 200 m recovery) round to 10 m, longer ones to 50 m. A floor never raises a step above where it
  // started, so cutting the load can never lengthen a step.
  const scaleGoal = (goal: RunStepInput["goal"]): RunStepInput["goal"] => {
    if (goal.value === undefined || goal.type === "open") return { ...goal };
    const grid = goal.type === "distance" ? (goal.value >= 1000 ? ROUND_M : 10) : 10;
    const floor = goal.type === "distance" ? 100 : 30;
    const value = factor < 1 ? Math.min(goal.value, Math.max(floor, roundTo(goal.value * factor, grid))) : roundTo(goal.value * factor, grid);
    return { ...goal, value };
  };
  const scaleRun = (step: RunStepInput): RunStepInput => ({ ...step, goal: scaleGoal(step.goal) });
  return steps.map((step) => (step.kind === "repeat" ? { ...step, steps: step.steps.map(scaleRun) } : step.kind === "exercise" ? { ...step } : scaleRun(step)));
}

const metres = (s: { type: SessionType; steps: StepInput[] }): number => sessionDistanceM(s as unknown as Pick<ValidatorSession, "type" | "steps">);

/** The session with its load scaled; a session is never reduced below a short run. */
function scaled(session: SessionInput, factor: number): SessionContent {
  const after = content(session);
  const original = after.steps;
  after.steps = scaleSteps(original, factor);
  const before = metres(session);
  // Never below a short run: scale less, from a fresh copy of the steps (not the caller's).
  if (factor < 1 && before > 0 && metres(after) < MIN_SESSION_M) after.steps = scaleSteps(structuredClone(original), Math.min(1, MIN_SESSION_M / before));
  return after;
}

/** A hard session turned into an easy run of the reduced distance (for a week with pain). */
function asEasyRun(session: SessionInput, factor: number): SessionContent {
  const after = content(session);
  const total = Math.max(MIN_SESSION_M, roundTo(metres(session) * factor, ROUND_M));
  after.type = "easy";
  after.title = "Easy run";
  after.key = false;
  delete after.notes; // the notes described the hard session this replaces
  after.steps = [{ kind: "work", goal: { type: "distance", value: total }, target: { type: "effort", effort: "easy" } }];
  return after;
}

// ---- The rules ----

export function proposeAdjustments(input: { plan: PlanInput; checkIns: CheckInInput[]; matches: MatchInput[]; today: string }): ProposalDraft[] {
  const { plan } = input;
  const today = dayNumber(input.today);
  if (!plan.adaptive) return [];

  const creator = { type: "rules" as const, version: PROPOSAL_RULES_VERSION };
  const byId = new Map(plan.sessions.map((s) => [s.id, s]));
  // A session is done when its match is confirmed or the user checked in after it: they ran it, whatever the import says.
  const done = new Set([
    ...input.matches.filter((m) => m.status === "confirmed").map((m) => m.sessionId),
    ...input.checkIns.filter((c) => c.when === "after").map((c) => c.sessionId),
  ]);
  const proposals: ProposalDraft[] = [];
  const byDate = (a: SessionInput, b: SessionInput) => (a.date === b.date ? (a.id < b.id ? -1 : 1) : a.date < b.date ? -1 : 1);

  // 1. A missed key session is dropped, not rescheduled. One proposal each, so each can be decided alone.
  const missed = plan.sessions
    .filter((s) => s.key === true && s.status === "planned" && !done.has(s.id) && dayNumber(s.date) < today && dayNumber(s.date) >= today - MISSED_LOOKBACK_DAYS)
    .sort(byDate);
  for (const s of missed) {
    proposals.push({
      key: `missed_key:${s.id}`,
      kind: "adjustment",
      creator,
      reason: `You missed ${(s.title ?? s.type).slice(0, 60)} on ${s.date}. We suggest dropping it instead of squeezing it in, so the rest of the week stays on track.`.slice(0, 200),
      urgent: true,
      changes: [{ op: "delete", sessionId: s.id, before: content(s), userOwned: s.owner === "user" }],
    });
  }

  // The check-ins that happened, newest session first. Check-ins for sessions the plan does not have are ignored.
  // One check-in of each kind per session: if there are several, the last one given counts.
  const latest = new Map<string, CheckInInput>();
  for (const c of input.checkIns) latest.set(`${c.sessionId}|${c.when}`, c);
  const known = [...latest.values()]
    .map((c) => ({ c, s: byId.get(c.sessionId) }))
    .filter((x): x is { c: CheckInInput; s: SessionInput } => x.s !== undefined && dayNumber(x.s.date) <= today)
    .sort((a, b) => -byDate(a.s, b.s));
  const recentAfter = known.filter((x) => x.c.when === "after").slice(0, RECENT_CHECKINS);

  // Next week's sessions are the ones a load change can reach.
  const nextWeek = plan.sessions.filter((s) => s.status === "planned" && RUN_TYPES.has(s.type) && dayNumber(s.date) > today && dayNumber(s.date) <= today + 7).sort(byDate);
  const updates = (make: (s: SessionInput) => SessionContent | undefined): ProposalChange[] =>
    nextWeek.flatMap((s): ProposalChange[] => {
      const before = content(s);
      const after = make(s);
      // A change that leaves the session as it was is not a proposal (short steps can round back to themselves).
      return after && JSON.stringify(after) !== JSON.stringify(before) ? [{ op: "update", sessionId: s.id, before, after, userOwned: s.owner === "user" }] : [];
    });

  // 2. Pain reduces the load, with guidance. It outranks the other load rules.
  const pain = known.find((x) => x.c.pain === true && dayNumber(x.s.date) >= today - PAIN_LOOKBACK_DAYS);
  if (pain) {
    const changes = updates((s) => (s.type === "intervals" || s.type === "tempo" ? asEasyRun(s, PAIN_FACTOR) : scaled(s, PAIN_FACTOR)));
    if (changes.length > 0) {
      proposals.push({
        key: `pain:${pain.s.id}`,
        kind: "adjustment",
        creator,
        reason: "You flagged pain, so we suggest a lighter week with easy runs in place of hard sessions. If it keeps hurting, please see a qualified professional.",
        urgent: true,
        changes,
      });
    }
    return proposals;
  }

  // 3. Sessions that felt much harder than planned ease the next week.
  const hard = recentAfter.filter((x) => (x.c.effortFelt ?? 0) >= HARD_EFFORT || x.c.feel <= 1);
  if (hard.length >= HARD_COUNT) {
    const changes = updates((s) => scaled(s, EASE_FACTOR));
    if (changes.length > 0) {
      proposals.push({
        key: `ease_week:${hard.map((x) => x.s.id).sort().join("+")}`,
        kind: "adjustment",
        creator,
        reason: "Your last few sessions felt much harder than planned, so we suggest easing next week a little.",
        urgent: false,
        changes,
      });
    }
    return proposals;
  }

  // 4. Consistently easy sessions progress a little, but not while a key session is being dropped.
  const easy =
    recentAfter.length === RECENT_CHECKINS &&
    recentAfter.every((x) => x.c.feel >= EASY_FEEL && x.c.effortFelt !== undefined && x.c.effortFelt <= EASY_EFFORT);
  if (easy && missed.length === 0) {
    const changes = updates((s) => (s.type === "easy" || s.type === "long" ? scaled(s, PROGRESS_FACTOR) : undefined));
    if (changes.length > 0) {
      proposals.push({
        key: `progress:${recentAfter.map((x) => x.s.id).sort().join("+")}`,
        kind: "adjustment",
        creator,
        reason: "Your last three sessions felt easy, so we suggest adding a little to next week's easy and long runs.",
        urgent: false,
        changes,
      });
    }
  }
  return proposals;
}
