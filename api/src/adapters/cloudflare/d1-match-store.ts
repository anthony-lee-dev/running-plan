import type { Disposition } from "../../domain/activities";
import type { MatchEffects, MatchRow, MatchState, MatchStatus, SessionStatus } from "../../domain/matches";
import { MatchConflictError, type MatchStore } from "../../ports";
import { sessionOf, type SessionRow } from "./d1-plan-store";

const LIVE_SESSION = `SELECT s.id FROM sessions s JOIN plans p ON p.id = s.plan_id
  WHERE p.user_id = ?1 AND p.deleted_at IS NULL AND s.deleted_at IS NULL`;

/**
 * Matches in D1. A change is one read (a batch of three selects) and one write batch. The write batch opens with a
 * guard that fails the whole transaction when anything read has changed: `json('{')` raises "malformed JSON" only
 * when its row is selected. The D1 SQL here may use SQLite features; only the migrations stay portable.
 */
export class D1MatchStore implements MatchStore {
  constructor(private readonly db: D1Database) {}

  async load(userId: string, ref: { sessionId?: string; activityId?: string }): Promise<MatchState> {
    const sid = ref.sessionId ?? "";
    const aid = ref.activityId ?? "";
    // Every match, also one whose session (or plan) was deleted: the change then removes it, and the guard's count
    // in apply sees the same rows.
    const matchesSql = `SELECT session_id, activity_id, status, updated_at FROM matches
      WHERE user_id = ?1 AND (session_id = ?2 OR activity_id = ?3) ORDER BY session_id`;
    const [sessions, activities, matches] = await this.db.batch([
      this.db
        .prepare(
          `SELECT s.id, s.plan_id, s.status, s.revision FROM sessions s WHERE s.id IN (${LIVE_SESSION})
             AND (s.id = ?2 OR s.id IN (SELECT session_id FROM matches WHERE user_id = ?1 AND activity_id = ?3)) ORDER BY s.id`,
        )
        .bind(userId, sid, aid),
      this.db
        .prepare(
          `SELECT id, disposition, revision FROM activities WHERE user_id = ?1 AND deleted_at IS NULL
             AND (id = ?3 OR id IN (SELECT activity_id FROM matches WHERE user_id = ?1 AND session_id = ?2)) ORDER BY id`,
        )
        .bind(userId, sid, aid),
      this.db.prepare(matchesSql).bind(userId, sid, aid),
    ]);
    // The named session and activity first, as the memory store and the callers expect.
    const first = <T extends { id: string }>(list: T[], id: string) => [...list.filter((x) => x.id === id), ...list.filter((x) => x.id !== id)];
    return {
      sessions: first(
        (sessions!.results as { id: string; plan_id: string; status: SessionStatus; revision: number }[]).map((r) => ({ id: r.id, planId: r.plan_id, status: r.status, revision: r.revision })),
        sid,
      ),
      activities: first((activities!.results as { id: string; disposition: Disposition; revision: number }[]).map((r) => ({ ...r })), aid),
      matches: (matches!.results as { session_id: string; activity_id: string; status: MatchStatus; updated_at: string }[]).map(toMatch),
    };
  }

  async suggestionCandidates(userId: string, from: string, to: string) {
    const { results } = await this.db
      .prepare(
        `SELECT s.* FROM sessions s JOIN plans p ON p.id = s.plan_id
          WHERE p.user_id = ?1 AND p.deleted_at IS NULL AND s.deleted_at IS NULL AND s.status = 'planned'
            AND s.date >= ?2 AND s.date <= ?3
            AND NOT EXISTS (SELECT 1 FROM matches m WHERE m.session_id = s.id)
          ORDER BY s.date, s.id`,
      )
      .bind(userId, from, to)
      .all<SessionRow>();
    return results.map(sessionOf);
  }

  async apply(userId: string, state: MatchState, effects: MatchEffects, now: string) {
    const conditions: string[] = [];
    const binds: unknown[] = [];
    for (const s of state.sessions) {
      conditions.push(`(SELECT s.revision FROM sessions s JOIN plans p ON p.id = s.plan_id
        WHERE s.id = ? AND s.deleted_at IS NULL AND p.deleted_at IS NULL AND p.user_id = ?) IS ?`);
      binds.push(s.id, userId, s.revision);
    }
    for (const a of state.activities) {
      conditions.push(`(SELECT revision FROM activities WHERE id = ? AND user_id = ? AND deleted_at IS NULL) IS ?`);
      binds.push(a.id, userId, a.revision);
    }
    // The same matches as read: the same count around these sessions and activities, and each one unchanged.
    const ids = [...state.sessions.map((s) => s.id), ...state.activities.map((a) => a.id)];
    const marks = ids.map(() => "?").join(", ") || "NULL";
    conditions.push(`(SELECT count(*) FROM matches WHERE user_id = ? AND (session_id IN (${marks}) OR activity_id IN (${marks}))) = ?`);
    binds.push(userId, ...ids, ...ids, state.matches.length);
    for (const m of state.matches) {
      conditions.push(`EXISTS (SELECT 1 FROM matches WHERE session_id = ? AND activity_id = ? AND status = ? AND updated_at = ?)`);
      binds.push(m.sessionId, m.activityId, m.status, m.updatedAt);
    }

    const statements = [
      this.db.prepare(`SELECT json('{') WHERE NOT (${conditions.join(" AND ")})`).bind(...binds),
      ...effects.removeMatches.map((sessionId) => this.db.prepare("DELETE FROM matches WHERE user_id = ? AND session_id = ?").bind(userId, sessionId)),
      ...(effects.putMatch
        ? [
            this.db
              .prepare("INSERT INTO matches (session_id, activity_id, user_id, status, updated_at) VALUES (?, ?, ?, ?, ?)")
              .bind(effects.putMatch.sessionId, effects.putMatch.activityId, userId, effects.putMatch.status, effects.putMatch.updatedAt),
          ]
        : []),
      ...effects.sessions.flatMap((s) => [
        this.db.prepare("UPDATE sessions SET status = ?, revision = revision + 1, updated_at = ? WHERE id = ? AND revision = ?").bind(s.status, now, s.id, s.baseRevision),
        this.db.prepare("UPDATE plans SET content_revision = content_revision + 1 WHERE id = ? AND user_id = ?").bind(s.planId, userId),
      ]),
      ...effects.activities.map((a) =>
        this.db
          .prepare("UPDATE activities SET disposition = ?, revision = revision + 1, updated_at = ? WHERE id = ? AND user_id = ? AND revision = ?")
          .bind(a.disposition, now, a.id, userId, a.baseRevision),
      ),
    ];
    try {
      await this.db.batch(statements);
    } catch (error) {
      if (String((error as Error).message).includes("malformed JSON")) throw new MatchConflictError("changed since it was read");
      throw error;
    }
  }

  async forActivities(userId: string, activityIds: string[]) {
    if (activityIds.length === 0) return [];
    const { results } = await this.db
      .prepare(
        `SELECT session_id, activity_id, status, updated_at FROM matches WHERE user_id = ?1 AND session_id IN (${LIVE_SESSION})
           AND activity_id IN (SELECT value FROM json_each(?2))`,
      )
      .bind(userId, JSON.stringify(activityIds))
      .all<{ session_id: string; activity_id: string; status: MatchStatus; updated_at: string }>();
    return results.map(toMatch);
  }
}

const toMatch = (r: { session_id: string; activity_id: string; status: MatchStatus; updated_at: string }): MatchRow => ({
  sessionId: r.session_id,
  activityId: r.activity_id,
  status: r.status,
  updatedAt: r.updated_at,
});
