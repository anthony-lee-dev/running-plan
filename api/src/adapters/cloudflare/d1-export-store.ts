import type { MatchRow, MatchStatus } from "../../domain/matches";
import type { Week } from "../../domain/plan-input";
import type { AccountData, AccountExportStore, ExportedProposal } from "../../ports";
import { toActivity, type Row as ActivityRow } from "./d1-activity-store";
import { toCheckIn, type CheckInRow } from "./d1-checkin-store";
import { planOf, sessionOf, type PlanRow, type SessionRow } from "./d1-plan-store";

interface ProposalRow {
  id: string;
  plan_id: string;
  base_content_revision: number;
  kind: ExportedProposal["kind"];
  creator_type: ExportedProposal["creator"]["type"];
  creator_version: string;
  reason: string;
  urgent: number;
  changes: string;
  plan_changes: string | null;
  status: ExportedProposal["status"];
  resolved_at: string | null;
  created_at: string;
  updated_at: string;
  deleted_at: string | null;
}

const toProposal = (r: ProposalRow): ExportedProposal => ({
  id: r.id,
  planId: r.plan_id,
  baseContentRevision: r.base_content_revision,
  kind: r.kind,
  creator: { type: r.creator_type, version: r.creator_version },
  reason: r.reason,
  urgent: r.urgent === 1,
  changes: JSON.parse(r.changes),
  ...(r.plan_changes !== null ? { planChanges: JSON.parse(r.plan_changes) } : {}),
  status: r.status,
  createdAt: r.created_at,
  updatedAt: r.updated_at,
  deletedAt: r.deleted_at,
  resolvedAt: r.resolved_at,
});

// Every statement is bound to the user alone (one bind each, far from D1's 100-per-query limit) and reaches the
// plan through a join rather than a list of ids. A deleted plan's sessions are not tombstoned, so each table that hangs
// off a plan joins it and requires it live.
const LIVE_PLAN = "p.user_id = ?1 AND p.deleted_at IS NULL";

/**
 * The data export in D1: one `db.batch` of eight selects, which Workers counts as one query, however much the
 * account holds. The D1 SQL here may use SQLite features; only the migrations stay portable.
 */
export class D1ExportStore implements AccountExportStore {
  constructor(private readonly db: D1Database) {}

  async read(userId: string): Promise<AccountData | undefined> {
    const select = (sql: string) => this.db.prepare(sql).bind(userId);
    const [user, plans, weeks, sessions, activities, matches, checkins, proposals] = await this.db.batch([
      select("SELECT email FROM users WHERE id = ?1"),
      select("SELECT * FROM plans p WHERE p.user_id = ?1 AND p.deleted_at IS NULL ORDER BY p.start_date DESC, p.id DESC"),
      select(`SELECT w.plan_id, w.idx, w.phase, w.notes FROM plan_weeks w JOIN plans p ON p.id = w.plan_id WHERE ${LIVE_PLAN} ORDER BY w.plan_id, w.idx`),
      select(`SELECT s.* FROM sessions s JOIN plans p ON p.id = s.plan_id WHERE ${LIVE_PLAN} AND s.deleted_at IS NULL ORDER BY s.date, s.id`),
      select("SELECT * FROM activities WHERE user_id = ?1 AND deleted_at IS NULL ORDER BY local_date DESC, started_at DESC, id DESC"),
      select(
        `SELECT m.session_id, m.activity_id, m.status, m.updated_at FROM matches m
           JOIN sessions s ON s.id = m.session_id JOIN plans p ON p.id = s.plan_id JOIN activities a ON a.id = m.activity_id
          WHERE m.user_id = ?1 AND p.user_id = ?1 AND p.deleted_at IS NULL AND s.deleted_at IS NULL AND a.deleted_at IS NULL
          ORDER BY m.session_id`,
      ),
      select(
        `SELECT c.* FROM checkins c JOIN sessions s ON s.id = c.session_id JOIN plans p ON p.id = s.plan_id
          WHERE c.user_id = ?1 AND p.user_id = ?1 AND p.deleted_at IS NULL AND s.deleted_at IS NULL AND c.deleted_at IS NULL
          ORDER BY c.updated_at, c.id`,
      ),
      select(`SELECT r.* FROM proposals r JOIN plans p ON p.id = r.plan_id WHERE r.user_id = ?1 AND ${LIVE_PLAN} AND r.deleted_at IS NULL ORDER BY r.created_at, r.id`),
    ]);
    const email = (user!.results as { email: string }[])[0]?.email;
    if (email === undefined) return undefined;

    const weeksByPlan = new Map<string, Week[]>();
    for (const w of weeks!.results as { plan_id: string; idx: number; phase: Week["phase"] | null; notes: string | null }[]) {
      const list = weeksByPlan.get(w.plan_id) ?? [];
      list.push({ index: w.idx, ...(w.phase ? { phase: w.phase } : {}), ...(w.notes !== null ? { notes: w.notes } : {}) });
      weeksByPlan.set(w.plan_id, list);
    }
    return {
      email,
      plans: (plans!.results as unknown as PlanRow[]).map((r) => planOf(r, weeksByPlan.get(r.id) ?? [])),
      sessions: (sessions!.results as unknown as SessionRow[]).map(sessionOf),
      activities: (activities!.results as unknown as ActivityRow[]).map(toActivity),
      matches: (matches!.results as { session_id: string; activity_id: string; status: MatchStatus; updated_at: string }[]).map(
        (r): MatchRow => ({ sessionId: r.session_id, activityId: r.activity_id, status: r.status, updatedAt: r.updated_at }),
      ),
      checkins: (checkins!.results as unknown as CheckInRow[]).map(toCheckIn),
      proposals: (proposals!.results as unknown as ProposalRow[]).map(toProposal),
    };
  }
}
