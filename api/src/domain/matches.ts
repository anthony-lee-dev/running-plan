// Matches between imported activities and planned sessions (design §8.3). A session has at most one match and an
// activity at most one; matching an activity elsewhere moves it. Confirming marks the session done and takes the
// activity out of the inbox; undoing a confirmed match puts both back. Pure: the store reads the state, this decides
// what changes, and the store writes all of it in one transaction.
import type { Disposition } from "./activities";

export type MatchStatus = "suggested" | "confirmed";
export type SessionStatus = "planned" | "done" | "skipped";

export interface MatchRow {
  sessionId: string;
  activityId: string;
  status: MatchStatus;
  updatedAt: string;
}

/** What a change looks at: the sessions, activities and matches it may touch, as read from the store. */
export interface MatchState {
  sessions: { id: string; planId: string; status: SessionStatus; revision: number }[];
  activities: { id: string; disposition: Disposition; revision: number }[];
  matches: MatchRow[];
}

export type MatchChange =
  | { kind: "put"; sessionId: string; activityId: string; status: MatchStatus }
  | { kind: "delete"; sessionId: string }
  | { kind: "disposition"; activityId: string; disposition: "inbox" | "extra" | "ignored" };

/** The writes, each with the revision it was based on so the store can refuse them if anything moved. */
export interface MatchEffects {
  /** Session ids whose match is removed. */
  removeMatches: string[];
  putMatch?: MatchRow;
  sessions: { id: string; planId: string; status: SessionStatus; baseRevision: number }[];
  activities: { id: string; disposition: Disposition; baseRevision: number }[];
}

export function planMatchChange(state: MatchState, change: MatchChange, now: string): MatchEffects {
  const sessionStatus = new Map(state.sessions.map((s) => [s.id, s.status]));
  const disposition = new Map(state.activities.map((a) => [a.id, a.disposition]));
  const matches = [...state.matches];
  const removeMatches: string[] = [];

  const unlink = (m: MatchRow) => {
    removeMatches.push(m.sessionId);
    matches.splice(matches.indexOf(m), 1);
    // A confirmed match leaves a done session planned. A session skipped or planned by hand stays as it is (one marked
    // done by hand before the match was confirmed is reset too: the match does not remember the earlier status).
    if (m.status === "confirmed" && sessionStatus.get(m.sessionId) === "done") sessionStatus.set(m.sessionId, "planned");
    if (disposition.get(m.activityId) === "matched") disposition.set(m.activityId, "inbox");
  };

  let putMatch: MatchRow | undefined;
  if (change.kind === "put") {
    const same = matches.find((m) => m.sessionId === change.sessionId && m.activityId === change.activityId);
    for (const m of [...matches]) if (m !== same && (m.sessionId === change.sessionId || m.activityId === change.activityId)) unlink(m);
    if (same && same.status === "confirmed" && change.status === "suggested") unlink(same);
    else if (same) removeMatches.push(same.sessionId);
    putMatch = { sessionId: change.sessionId, activityId: change.activityId, status: change.status, updatedAt: now };
    if (change.status === "confirmed") {
      sessionStatus.set(change.sessionId, "done");
      disposition.set(change.activityId, "matched");
    } else if (disposition.get(change.activityId) === "matched") {
      disposition.set(change.activityId, "inbox");
    }
  } else if (change.kind === "delete") {
    for (const m of [...matches]) if (m.sessionId === change.sessionId) unlink(m);
  } else {
    for (const m of [...matches]) if (m.activityId === change.activityId) unlink(m);
    disposition.set(change.activityId, change.disposition);
  }

  return {
    removeMatches: [...new Set(removeMatches)],
    ...(putMatch ? { putMatch } : {}),
    sessions: state.sessions
      .filter((s) => sessionStatus.get(s.id) !== s.status)
      .map((s) => ({ id: s.id, planId: s.planId, status: sessionStatus.get(s.id)!, baseRevision: s.revision })),
    activities: state.activities
      .filter((a) => disposition.get(a.id) !== a.disposition)
      .map((a) => ({ id: a.id, disposition: disposition.get(a.id)!, baseRevision: a.revision })),
  };
}
