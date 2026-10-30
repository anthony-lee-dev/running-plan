// Progress and the weekly review (design 6.6a), computed from the plan, what was matched and what was checked in.
// Pure and deterministic. The API adds proposals, loose ends and the plan id around these. Every threshold is a
// starting value for the coach review (backlog H.1).
import { DEFAULT_PARAMS, sessionDistanceM, type ValidatorSession } from "./validators";

export type SessionType = "easy" | "long" | "intervals" | "tempo" | "strength" | "rest" | "custom";

export interface RunStepInput {
  kind: "warmup" | "work" | "recovery" | "cooldown";
  goal: { type: "time" | "distance" | "open"; value?: number };
}
export interface RepeatStepInput {
  kind: "repeat";
  count: number;
  steps: RunStepInput[];
}
export interface ExerciseStepInput {
  kind: "exercise";
  sets: number;
  reps?: number;
  durationSec?: number;
  restSec?: number;
}
export type StepInput = RunStepInput | RepeatStepInput | ExerciseStepInput;

export interface InsightSession {
  id: string;
  /** Local calendar date, YYYY-MM-DD. */
  date: string;
  type: SessionType;
  title?: string;
  key?: boolean;
  status: "planned" | "done" | "skipped";
  steps: StepInput[];
  custom?: { goal?: { type: "time" | "distance" | "open"; value?: number } };
  deletedAt?: string | null;
}
export interface PlanSpan {
  startDate: string;
  weekCount: number;
  goalDate?: string | undefined;
}
export interface MatchInput {
  sessionId: string;
  activityId: string;
  status: "suggested" | "confirmed";
}
export interface ActivityInput {
  id: string;
  distanceM?: number | undefined;
  durationSec: number;
}
export interface CheckInInput {
  sessionId: string;
  when: "before" | "after";
  feel: number;
  effortFelt?: number | undefined;
  pain?: boolean | undefined;
}
export interface ReviewSettings {
  frequency: "weekly" | "weekly_plus_urgent" | "after_import" | "off";
  day?: "mon" | "tue" | "wed" | "thu" | "fri" | "sat" | "sun";
}

/** The pace that turns a distance into a time (and a time into a distance) when a session only has one: the validators' own. */
const FALLBACK_SECONDS_PER_KM = DEFAULT_PARAMS.fallbackPaceSecPerKm;
const SECONDS_PER_REP = 3;
/** Share of due sessions done (not skipped or missed) at or above which the plan is on track. */
const ON_TRACK_SHARE = 0.7;
/** Fewer sessions than this are too few to judge a plan by. */
const MIN_SESSIONS_TO_JUDGE = 3;
const RUN_TYPES: ReadonlySet<SessionType> = new Set(["easy", "long", "intervals", "tempo"]);
const WEEKDAYS = ["mon", "tue", "wed", "thu", "fri", "sat", "sun"] as const;

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

// ---- A session's plan ----

/** Distance a session plans, in metres: running sessions only. Time goals count at the fallback pace. */
export function plannedDistanceM(session: Pick<InsightSession, "type" | "steps">): number {
  return sessionDistanceM(session as unknown as Pick<ValidatorSession, "type" | "steps">);
}

/** Time a session plans, in seconds: a run by its goals, strength by its sets, cross-training by its time goal. */
export function plannedTimeSec(session: Pick<InsightSession, "type" | "steps" | "custom">): number {
  if (session.type === "rest") return 0;
  if (session.type === "custom") return session.custom?.goal?.type === "time" ? (session.custom.goal.value ?? 0) : 0;
  const runStep = (step: RunStepInput): number =>
    step.goal.type === "time" ? (step.goal.value ?? 0) : step.goal.type === "distance" ? ((step.goal.value ?? 0) / 1000) * FALLBACK_SECONDS_PER_KM : 0;
  const total = (session.steps ?? []).reduce((sum, step) => {
    if (step.kind === "exercise") return sum + step.sets * ((step.durationSec ?? (step.reps ?? 0) * SECONDS_PER_REP) + (step.restSec ?? 0));
    if (step.kind === "repeat") return sum + step.count * step.steps.reduce((n, s) => n + runStep(s), 0);
    return sum + runStep(step);
  }, 0);
  return Math.round(total);
}

// ---- What happened ----

interface Facts {
  live: InsightSession[];
  confirmed: Map<string, ActivityInput | null>;
}

function facts(sessions: InsightSession[], matches: MatchInput[], activities: ActivityInput[]): Facts {
  const byActivity = new Map(activities.map((a) => [a.id, a]));
  const confirmed = new Map<string, ActivityInput | null>();
  for (const m of matches) if (m.status === "confirmed") confirmed.set(m.sessionId, byActivity.get(m.activityId) ?? null);
  return { live: sessions.filter((s) => !s.deletedAt), confirmed };
}

/** A session is done when it was marked done or a match to an imported activity was confirmed. */
const isDone = (s: InsightSession, f: Facts): boolean => s.status === "done" || f.confirmed.has(s.id);

/** What a done session counts for: the activity's own distance and time when there is one, else what was planned. */
function actual(s: InsightSession, f: Facts): { distanceM: number; timeSec: number } {
  const activity = f.confirmed.get(s.id);
  if (activity) return { distanceM: RUN_TYPES.has(s.type) ? (activity.distanceM ?? 0) : 0, timeSec: activity.durationSec };
  return { distanceM: plannedDistanceM(s), timeSec: plannedTimeSec(s) };
}

const weekOf = (span: PlanSpan, date: string): number => Math.floor((dayNumber(date) - dayNumber(span.startDate)) / 7);
/** Sessions that are part of the plan's weeks, leaving out rest days. */
const inPlan = (span: PlanSpan, f: Facts): InsightSession[] =>
  f.live.filter((s) => s.type !== "rest" && weekOf(span, s.date) >= 0 && weekOf(span, s.date) < span.weekCount);

function totals(sessions: InsightSession[], f: Facts) {
  let plannedDistanceTotal = 0;
  let actualDistance = 0;
  let plannedTime = 0;
  let actualTime = 0;
  for (const s of sessions) {
    plannedDistanceTotal += plannedDistanceM(s);
    plannedTime += plannedTimeSec(s);
    if (isDone(s, f)) {
      const a = actual(s, f);
      actualDistance += a.distanceM;
      actualTime += a.timeSec;
    }
  }
  return { plannedDistanceM: Math.round(plannedDistanceTotal), actualDistanceM: Math.round(actualDistance), plannedTimeSec: Math.round(plannedTime), actualTimeSec: Math.round(actualTime) };
}

// ---- Progress ----

export interface Progress {
  asOf: string;
  adherence: { due: number; done: number; skipped: number; missed: number };
  weeks: { index: number; plannedDistanceM: number; actualDistanceM: number; plannedTimeSec: number; actualTimeSec: number }[];
  keySessions: { planned: number; completed: number };
  strengthSessions: { planned: number; completed: number };
  goal: { date?: string; daysToGo?: number; onTrack: "on_track" | "behind" | "unknown" };
}

/**
 * Whole-plan aggregates for the Progress screen. "Due" is every session dated on or before `asOf`; one dated today is
 * due but not yet missed (the day is not over), so due can exceed done + skipped + missed by what is still to do today.
 * Volume counts every done session of the plan, including one dated after `asOf` that was done early; adherence only
 * the sessions due so far. With no goal date the plan is never judged, so `onTrack` stays `unknown`. The key and
 * strength tallies count the sessions due so far, like adherence.
 */
export function computeProgress(input: { plan: PlanSpan; sessions: InsightSession[]; matches: MatchInput[]; activities: ActivityInput[]; asOf: string }): Progress {
  const asOf = dayNumber(input.asOf);
  const f = facts(input.sessions, input.matches, input.activities);
  const sessions = inPlan(input.plan, f);
  const due = sessions.filter((s) => dayNumber(s.date) <= asOf);

  const done = due.filter((s) => isDone(s, f));
  const skipped = due.filter((s) => !isDone(s, f) && s.status === "skipped");
  const missed = due.filter((s) => !isDone(s, f) && s.status === "planned" && dayNumber(s.date) < asOf);

  const weeks = Array.from({ length: input.plan.weekCount }, (_, index) => ({
    index,
    ...totals(sessions.filter((s) => weekOf(input.plan, s.date) === index), f),
  }));
  const tally = (pick: (s: InsightSession) => boolean) => ({ planned: due.filter(pick).length, completed: done.filter(pick).length });

  const goal: Progress["goal"] = { onTrack: "unknown" };
  if (input.plan.goalDate !== undefined) {
    goal.date = input.plan.goalDate;
    const daysToGo = dayNumber(input.plan.goalDate) - asOf;
    if (daysToGo >= 0) goal.daysToGo = daysToGo;
    const judged = done.length + skipped.length + missed.length;
    if (judged >= MIN_SESSIONS_TO_JUDGE) goal.onTrack = done.length / judged >= ON_TRACK_SHARE ? "on_track" : "behind";
  }

  return {
    asOf: input.asOf,
    adherence: { due: due.length, done: done.length, skipped: skipped.length, missed: missed.length },
    weeks,
    keySessions: tally((s) => s.key === true),
    strengthSessions: tally((s) => s.type === "strength"),
    goal,
  };
}

// ---- The weekly review ----

export interface WeeklyReviewSummary {
  weekIndex: number;
  startDate: string;
  endDate: string;
  due: boolean;
  summary: {
    sessions: { planned: number; done: number; skipped: number; missed: number };
    distance: { plannedM: number; actualM: number };
    time: { plannedSec: number; actualSec: number };
    keySessions: { sessionId: string; title?: string; outcome: "hit" | "missed" | "skipped" | "upcoming" }[];
    checkIns: { count: number; averageFeel?: number; averageEffortFelt?: number; painFlags: number };
  };
}

export function computeWeeklyReview(input: {
  plan: PlanSpan;
  sessions: InsightSession[];
  matches: MatchInput[];
  activities: ActivityInput[];
  checkIns: CheckInInput[];
  weekIndex: number;
  today: string;
  review: ReviewSettings;
}): WeeklyReviewSummary {
  const { plan, weekIndex } = input;
  if (!Number.isInteger(weekIndex) || weekIndex < 0 || weekIndex >= plan.weekCount) throw new RangeError(`week ${weekIndex} is not in the plan`);
  const today = dayNumber(input.today);
  const start = dayNumber(plan.startDate) + weekIndex * 7;
  const end = start + 6;
  const f = facts(input.sessions, input.matches, input.activities);
  const week = inPlan(plan, f).filter((s) => weekOf(plan, s.date) === weekIndex).sort((a, b) => (a.date === b.date ? (a.id < b.id ? -1 : 1) : a.date < b.date ? -1 : 1));

  const done = week.filter((s) => isDone(s, f));
  const skipped = week.filter((s) => !isDone(s, f) && s.status === "skipped");
  const missed = week.filter((s) => !isDone(s, f) && s.status === "planned" && dayNumber(s.date) < today);
  const t = totals(week, f);

  const keySessions = week
    .filter((s) => s.key === true)
    .map((s) => {
      const outcome = isDone(s, f) ? "hit" : s.status === "skipped" ? "skipped" : dayNumber(s.date) < today ? "missed" : "upcoming";
      return { sessionId: s.id, ...(s.title !== undefined ? { title: s.title } : {}), outcome } as const;
    });

  const ids = new Set(week.map((s) => s.id));
  const checkIns = input.checkIns.filter((c) => ids.has(c.sessionId));
  const efforts = checkIns.flatMap((c) => (c.effortFelt !== undefined ? [c.effortFelt] : []));
  const mean = (values: number[]) => Math.round((values.reduce((a, b) => a + b, 0) / values.length) * 100) / 100;

  // The review looks back at a finished week. Its review day is the first day with the chosen weekday on or after the
  // week's last day (the last day itself when no day is chosen), and it is due for seven days from then. After an
  // import it is also due as soon as the week has something done, and on the review day as well. Off means never.
  const reviewDay = input.review.day === undefined ? end : end + ((WEEKDAYS.indexOf(input.review.day) - weekdayIndex(end) + 7) % 7);
  const onReviewDay = today >= reviewDay && today <= reviewDay + 6;
  const due =
    input.review.frequency === "off"
      ? false
      : input.review.frequency === "after_import"
        ? onReviewDay || (done.some((s) => dayNumber(s.date) <= today) && today >= start && today <= end + 6)
        : onReviewDay;

  return {
    weekIndex,
    startDate: dateOf(start),
    endDate: dateOf(end),
    due,
    summary: {
      sessions: { planned: week.length, done: done.length, skipped: skipped.length, missed: missed.length },
      distance: { plannedM: t.plannedDistanceM, actualM: t.actualDistanceM },
      time: { plannedSec: t.plannedTimeSec, actualSec: t.actualTimeSec },
      keySessions,
      checkIns: {
        count: checkIns.length,
        ...(checkIns.length > 0 ? { averageFeel: mean(checkIns.map((c) => c.feel)) } : {}),
        ...(efforts.length > 0 ? { averageEffortFelt: mean(efforts) } : {}),
        painFlags: checkIns.filter((c) => c.pain === true).length,
      },
    },
  };
}
