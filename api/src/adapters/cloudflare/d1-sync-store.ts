import type { Week } from "../../domain/plan-input";
import type { AppliedOp, SyncCursor, SyncPosition, SyncStore } from "../../ports";
import { toCheckIn, type CheckInRow } from "./d1-checkin-store";
import { planOf, sessionOf, type PlanRow, type SessionRow } from "./d1-plan-store";
import { proposalOf, type ProposalRow } from "./d1-proposal-store";

/** `AND (updated_at, id) > position`, in the plain form SQLite and Postgres both take. */
const after = (p: SyncPosition | undefined) =>
  p ? { sql: " AND (updated_at > ? OR (updated_at = ? AND id > ?))", binds: [p.updatedAt, p.updatedAt, p.id] } : { sql: "", binds: [] as string[] };

/** The offline edit queue in D1: idempotency keys and the pull, at most 4 queries for the pull however much it returns. */
export class D1SyncStore implements SyncStore {
  constructor(private readonly db: D1Database) {}

  async findOps(userId: string, keys: string[]) {
    if (keys.length === 0) return [];
    const { results } = await this.db
      .prepare(`SELECT idempotency_key, op_hash, revision FROM sync_ops WHERE user_id = ? AND idempotency_key IN (${keys.map(() => "?").join(",")})`)
      .bind(userId, ...keys)
      .all<{ idempotency_key: string; op_hash: string; revision: number }>();
    return results.map((r): AppliedOp => ({ idempotencyKey: r.idempotency_key, opHash: r.op_hash, revision: r.revision }));
  }

  async recordOps(userId: string, ops: AppliedOp[], now: string) {
    if (ops.length === 0) return;
    await this.db.batch(
      ops.map((o) =>
        this.db
          .prepare("INSERT INTO sync_ops (user_id, idempotency_key, op_hash, revision, created_at) VALUES (?, ?, ?, ?, ?) ON CONFLICT (user_id, idempotency_key) DO NOTHING")
          .bind(userId, o.idempotencyKey, o.opHash, o.revision, now),
      ),
    );
  }

  async changesSince(userId: string, cursor: SyncCursor, limits: { plans: number; sessions: number; checkins: number; proposals: number }) {
    const page = <T>(table: string, p: SyncPosition | undefined, limit: number) => {
      const a = after(p);
      return this.db
        .prepare(`SELECT * FROM ${table} WHERE user_id = ?${a.sql} ORDER BY updated_at, id LIMIT ?`)
        .bind(userId, ...a.binds, limit + 1)
        .all<T>();
    };
    const [plans, sessions, checkins, proposals] = await Promise.all([
      page<PlanRow>("plans", cursor.plans, limits.plans),
      page<SessionRow>("sessions", cursor.sessions, limits.sessions),
      page<CheckInRow>("checkins", cursor.checkins, limits.checkins),
      page<ProposalRow>("proposals", cursor.proposals, limits.proposals),
    ]);
    const planRows = plans.results.slice(0, limits.plans);
    const sessionRows = sessions.results.slice(0, limits.sessions);
    const checkinRows = checkins.results.slice(0, limits.checkins);
    const proposalRows = proposals.results.slice(0, limits.proposals);

    const weeks = new Map<string, Week[]>();
    if (planRows.length > 0) {
      const { results } = await this.db
        .prepare(`SELECT plan_id, idx, phase, notes FROM plan_weeks WHERE plan_id IN (${planRows.map(() => "?").join(",")}) ORDER BY plan_id, idx`)
        .bind(...planRows.map((p) => p.id))
        .all<{ plan_id: string; idx: number; phase: Week["phase"] | null; notes: string | null }>();
      for (const w of results) {
        const list = weeks.get(w.plan_id) ?? [];
        list.push({ index: w.idx, ...(w.phase ? { phase: w.phase } : {}), ...(w.notes !== null ? { notes: w.notes } : {}) });
        weeks.set(w.plan_id, list);
      }
    }
    const last = (rows: { updated_at: string; id: string }[], fallback: SyncPosition | undefined): SyncPosition | undefined => {
      const row = rows.at(-1);
      return row ? { updatedAt: row.updated_at, id: row.id } : fallback;
    };
    const next: SyncCursor = {};
    const positions = {
      plans: last(planRows, cursor.plans),
      sessions: last(sessionRows, cursor.sessions),
      checkins: last(checkinRows, cursor.checkins),
      proposals: last(proposalRows, cursor.proposals),
    };
    for (const key of ["plans", "sessions", "checkins", "proposals"] as const) if (positions[key]) next[key] = positions[key];
    return {
      plans: planRows.map((r) => planOf(r, weeks.get(r.id) ?? [])),
      sessions: sessionRows.map(sessionOf),
      checkins: checkinRows.map(toCheckIn),
      proposals: proposalRows.map(proposalOf),
      cursor: next,
      hasMore:
        plans.results.length > limits.plans ||
        sessions.results.length > limits.sessions ||
        checkins.results.length > limits.checkins ||
        proposals.results.length > limits.proposals,
    };
  }
}
