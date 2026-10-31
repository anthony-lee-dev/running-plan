// Suggested matches for an upload (design §8.3): each new activity is offered the planned session on its local date
// whose type fits and whose planned time is closest to the activity's duration. Only a suggestion: the client confirms
// through PUT /v1/sessions/{id}/match. Pure: no I/O.
import type { WorkoutType } from "./activities";
import { plannedTimeSec, type InsightSession } from "./insights";

export interface SuggestActivity {
  id: string;
  workoutType: WorkoutType;
  localDate: string;
  durationSec: number;
}

export type SuggestSession = Pick<InsightSession, "id" | "date" | "type" | "steps" | "custom">;

const RUN_SESSIONS: readonly string[] = ["easy", "long", "intervals", "tempo"];

function fits(workout: WorkoutType, sessionType: string): boolean {
  if (workout === "running") return RUN_SESSIONS.includes(sessionType);
  if (workout === "strength") return sessionType === "strength";
  return sessionType === "custom";
}

/** A planned time further than this factor from the duration (either way) is not the same workout. Starting value. */
const MAX_RATIO = 2;
/** Score for a session with no planned time: eligible, but behind any session with a close time. */
const UNKNOWN_SCORE = 1;

/** Activity id to session id. A session is suggested at most once; the closest fits are assigned first. */
export function suggestSessions(activities: SuggestActivity[], sessions: SuggestSession[]): Map<string, string> {
  const pairs: { a: string; s: string; score: number; order: number }[] = [];
  const planned = new Map(sessions.map((s) => [s.id, plannedTimeSec(s)]));
  activities.forEach((a, ai) => {
    sessions.forEach((s) => {
      if (s.date !== a.localDate || !fits(a.workoutType, s.type)) return;
      const time = planned.get(s.id) ?? 0;
      let score = UNKNOWN_SCORE;
      if (time > 0) {
        const ratio = Math.max(time, a.durationSec) / Math.min(time, a.durationSec);
        if (ratio > MAX_RATIO) return;
        score = Math.log(ratio) / Math.log(MAX_RATIO) * 0.5;
      }
      pairs.push({ a: a.id, s: s.id, score, order: ai });
    });
  });
  // Ties settle by upload order, then session id, so the result does not depend on the order sessions arrive in.
  pairs.sort((x, y) => x.score - y.score || x.order - y.order || (x.s < y.s ? -1 : x.s > y.s ? 1 : 0));
  const out = new Map<string, string>();
  const used = new Set<string>();
  for (const p of pairs) {
    if (out.has(p.a) || used.has(p.s)) continue;
    out.set(p.a, p.s);
    used.add(p.s);
  }
  return out;
}
