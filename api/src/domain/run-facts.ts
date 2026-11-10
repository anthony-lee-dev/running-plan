// The facts behind a run's written summary (issue #132). Every number the summary may mention is worked out here, as a
// ready-formatted string; the template and the model only repeat them, and the checks refuse any other number.
// Pure: no I/O. Left out on purpose: names, notes, titles, dates and ids (nothing user-typed ever reaches the model).
import type { StoredActivity } from "./activities";
import type { SessionType, Step } from "./plan-input";

/** Runs this many days back (and the run's own day) are the "recent runs" a run is compared with. */
export const RECENT_DAYS = 28;
/** A recent run is "of about this length" when its distance is within this share of the run's. */
export const SIMILAR_SHARE = 0.2;
/** Fewer similar runs than this make no comparison. */
export const MIN_SIMILAR = 3;

export type Direction = "quicker" | "slower" | "same";
export type HeartDirection = "higher" | "lower" | "same";

export interface RunFacts {
  distance?: string;
  time: string;
  pace?: string;
  avgHr?: string;
  vsRecent?: {
    count: number;
    window: string;
    avgPace: string;
    pace: { dir: Direction; text: string };
    avgHr?: string;
    hr?: { dir: HeartDirection; text: string };
  };
  plan?: { type: SessionType; distance?: string; time?: string };
  /** The after-run check-in's feel (1 to 5) and effort (1 to 10). Not carried for a run with pain. */
  feel?: number;
  effort?: number;
  /** The check-in flags pain. The facts never describe it beyond this flag. */
  pain: boolean;
}

export interface RunFactsInput {
  run: StoredActivity;
  /** The user's other running activities, any dates: the builder picks the window. Ignored ones are left out by the caller. */
  others: StoredActivity[];
  /** The matched session, when there is one. */
  session?: { type: SessionType; steps: Step[] };
  /** The latest live after-run check-in of the matched session. */
  checkIn?: { feel: number; effortFelt?: number; pain?: boolean };
}

const DAY_MS = 86_400_000;
const dayNumber = (date: string) => Date.parse(`${date}T00:00:00Z`) / DAY_MS;

export const formatDistance = (metres: number): string => `${(metres / 1000).toFixed(1)} km`;
export function formatDuration(sec: number): string {
  const minutes = Math.max(1, Math.round(sec / 60));
  if (minutes < 60) return `${minutes} min`;
  return `${Math.floor(minutes / 60)} h ${String(minutes % 60).padStart(2, "0")} min`;
}
export function formatPace(secPerKm: number): string {
  const total = Math.round(secPerKm);
  return `${Math.floor(total / 60)}:${String(total % 60).padStart(2, "0")}/km`;
}
const paceOf = (a: Pick<StoredActivity, "durationSec" | "distanceM">): number | undefined =>
  a.distanceM !== undefined && a.distanceM > 0 ? a.durationSec / (a.distanceM / 1000) : undefined;

/** The distance and time a session's steps state outright (repeats counted out); a missing goal is left out, never guessed. */
export function statedGoals(steps: Step[]): { distanceM?: number; timeSec?: number } {
  let distanceM = 0;
  let timeSec = 0;
  const add = (step: Step, times: number) => {
    if (step.kind === "exercise") return;
    if (step.kind === "repeat") {
      for (const s of step.steps) add(s, times * step.count);
      return;
    }
    if (step.goal.type === "distance") distanceM += (step.goal.value ?? 0) * times;
    if (step.goal.type === "time") timeSec += (step.goal.value ?? 0) * times;
  };
  for (const step of steps) add(step, 1);
  return { ...(distanceM > 0 ? { distanceM } : {}), ...(timeSec > 0 ? { timeSec } : {}) };
}

const SAME_PACE_SEC = 3;
const SAME_HR_BPM = 2;

/** Quality sessions are not compared with the user's other runs: their pace says little about an easy-run average. */
const COMPARABLE: ReadonlySet<SessionType | "none"> = new Set(["none", "easy", "long"]);

export function buildRunFacts(input: RunFactsInput): RunFacts {
  const { run } = input;
  const pain = input.checkIn?.pain === true;
  const facts: RunFacts = { time: formatDuration(run.durationSec), pain };
  if (run.distanceM !== undefined && run.distanceM > 0) facts.distance = formatDistance(run.distanceM);
  const pace = paceOf(run);
  if (pace !== undefined) facts.pace = formatPace(pace);
  if (run.avgHeartRate !== undefined) facts.avgHr = `${Math.round(run.avgHeartRate)} bpm`;

  if (input.session && COMPARABLE.has(input.session.type) === false) {
    // intervals, tempo and anything else: no comparison with other runs
  } else if (run.distanceM !== undefined && run.distanceM > 0 && pace !== undefined) {
    const day = dayNumber(run.localDate);
    const similar = input.others.filter((o) => {
      if (o.id === run.id || o.workoutType !== "running" || o.disposition === "ignored") return false;
      const d = dayNumber(o.localDate);
      if (d > day || d < day - RECENT_DAYS) return false;
      if (o.distanceM === undefined || o.distanceM <= 0) return false;
      return Math.abs(o.distanceM - run.distanceM!) <= SIMILAR_SHARE * run.distanceM!;
    });
    if (similar.length >= MIN_SIMILAR) {
      const totalSec = similar.reduce((n, o) => n + o.durationSec, 0);
      const totalKm = similar.reduce((n, o) => n + o.distanceM! / 1000, 0);
      const avg = totalSec / totalKm;
      const diff = Math.round(pace) - Math.round(avg);
      const paceDiff = Math.abs(diff) < SAME_PACE_SEC ? { dir: "same" as const, text: "about the same pace" } : diff < 0 ? { dir: "quicker" as const, text: `${-diff} s/km quicker` } : { dir: "slower" as const, text: `${diff} s/km slower` };
      const vs: NonNullable<RunFacts["vsRecent"]> = { count: similar.length, window: "4 weeks", avgPace: formatPace(avg), pace: paceDiff };
      const withHr = similar.filter((o) => o.avgHeartRate !== undefined);
      if (run.avgHeartRate !== undefined && withHr.length >= MIN_SIMILAR) {
        const avgHr = withHr.reduce((n, o) => n + o.avgHeartRate!, 0) / withHr.length;
        const d = Math.round(run.avgHeartRate) - Math.round(avgHr);
        vs.avgHr = `${Math.round(avgHr)} bpm`;
        vs.hr = Math.abs(d) < SAME_HR_BPM ? { dir: "same", text: "about the same heart rate" } : d > 0 ? { dir: "higher", text: `${d} bpm higher` } : { dir: "lower", text: `${-d} bpm lower` };
      }
      facts.vsRecent = vs;
    }
  }

  if (input.session) {
    const goals = statedGoals(input.session.steps);
    facts.plan = {
      type: input.session.type,
      ...(goals.distanceM !== undefined ? { distance: formatDistance(goals.distanceM) } : {}),
      ...(goals.timeSec !== undefined ? { time: formatDuration(goals.timeSec) } : {}),
    };
  }
  if (input.checkIn && !pain) {
    facts.feel = input.checkIn.feel;
    if (input.checkIn.effortFelt !== undefined) facts.effort = input.checkIn.effortFelt;
  }
  return facts;
}

/** The numbers in a text, normalised so "05" and "5" agree. `5:41` stays as it is. */
export function numbersIn(text: string): string[] {
  return (text.match(/\d+(?::\d+)+|\d+(?:\.\d+)?/g) ?? []).map((n) => (n.includes(":") ? n.replace(/(^|:)0+(?=\d)/g, "$1") : String(Number(n))));
}

const PLAN_TYPE_NAME: Record<string, string> = { easy: "easy run", long: "long run", intervals: "interval session", tempo: "tempo run", strength: "strength session" };
export const planTypeName = (type: SessionType): string => PLAN_TYPE_NAME[type] ?? "session";

/** Every number a text about these facts may contain. Anything else in a paragraph is invented. */
export function allowedNumbers(facts: RunFacts): Set<string> {
  // The 4-week window is a constant of the summary, named even when there is nothing to compare with.
  const parts: string[] = [`${RECENT_DAYS / 7} weeks`, facts.distance, facts.time, facts.pace, facts.avgHr].filter((x): x is string => x !== undefined);
  if (facts.vsRecent) {
    const v = facts.vsRecent;
    parts.push(String(v.count), v.window, v.avgPace, v.pace.text);
    if (v.avgHr) parts.push(v.avgHr);
    if (v.hr) parts.push(v.hr.text);
  }
  if (facts.plan) parts.push(...[facts.plan.distance, facts.plan.time].filter((x): x is string => x !== undefined));
  if (facts.feel !== undefined) parts.push(String(facts.feel), "5");
  if (facts.effort !== undefined) parts.push(String(facts.effort), "10");
  return new Set(parts.flatMap(numbersIn));
}
