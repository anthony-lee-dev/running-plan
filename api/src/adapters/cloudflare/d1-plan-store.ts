import type { Goal, SessionContent, Week } from "../../domain/plan-input";
import type { PlanStore, PlanWriteFields, StoredPlan, StoredSession, WriteFailure } from "../../ports";

interface PlanRow {
  id: string;
  goal_type: Goal["type"];
  goal_label: string | null;
  goal_date: string | null;
  goal_target_sec: number | null;
  start_date: string;
  week_count: number;
  source: StoredPlan["source"];
  engine_preset_id: string | null;
  engine_version: string | null;
  engine_interview: string | null;
  adaptive: number;
  revision: number;
  content_revision: number;
  updated_at: string;
  deleted_at: string | null;
  create_hash: string | null;
}

export interface SessionRow {
  id: string;
  plan_id: string;
  date: string;
  type: SessionContent["type"];
  title: string | null;
  is_key: number;
  status: SessionContent["status"];
  owner: SessionContent["owner"];
  steps: string;
  custom: string | null;
  notes: string | null;
  revision: number;
  updated_at: string;
  deleted_at: string | null;
  create_hash: string | null;
}

const goalOf = (r: PlanRow): Goal => ({
  type: r.goal_type,
  ...(r.goal_label !== null ? { label: r.goal_label } : {}),
  ...(r.goal_date !== null ? { date: r.goal_date } : {}),
  ...(r.goal_target_sec !== null ? { targetTimeSec: r.goal_target_sec } : {}),
});

const planOf = (r: PlanRow, weeks: Week[]): StoredPlan => ({
  id: r.id,
  goal: goalOf(r),
  startDate: r.start_date,
  weekCount: r.week_count,
  source: r.source,
  ...(r.engine_preset_id !== null && r.engine_version !== null
    ? { engine: { presetId: r.engine_preset_id, version: r.engine_version, ...(r.engine_interview !== null ? { interview: JSON.parse(r.engine_interview) } : {}) } }
    : {}),
  adaptive: r.adaptive === 1,
  weeks,
  revision: r.revision,
  contentRevision: r.content_revision,
  updatedAt: r.updated_at,
  deletedAt: r.deleted_at,
});

export const sessionOf = (r: SessionRow): StoredSession => ({
  id: r.id,
  planId: r.plan_id,
  date: r.date,
  type: r.type,
  ...(r.title !== null ? { title: r.title } : {}),
  key: r.is_key === 1,
  status: r.status,
  owner: r.owner,
  steps: JSON.parse(r.steps),
  ...(r.custom !== null ? { custom: JSON.parse(r.custom) } : {}),
  ...(r.notes !== null ? { notes: r.notes } : {}),
  revision: r.revision,
  updatedAt: r.updated_at,
  deletedAt: r.deleted_at,
});

const sessionColumns = (s: SessionContent) => [
  s.date,
  s.type,
  s.title ?? null,
  s.key ? 1 : 0,
  s.status,
  s.owner,
  JSON.stringify(s.steps),
  s.custom ? JSON.stringify(s.custom) : null,
  s.notes ?? null,
];

export class D1PlanStore implements PlanStore {
  constructor(private readonly db: D1Database) {}

  private weeks(planId: string): Promise<D1Result<{ idx: number; phase: Week["phase"] | null; notes: string | null }>> {
    return this.db.prepare("SELECT idx, phase, notes FROM plan_weeks WHERE plan_id = ? ORDER BY idx").bind(planId).all();
  }

  private async weeksOf(planId: string): Promise<Week[]> {
    const { results } = await this.weeks(planId);
    return results.map((w) => ({ index: w.idx, ...(w.phase ? { phase: w.phase } : {}), ...(w.notes !== null ? { notes: w.notes } : {}) }));
  }

  private insertWeek(planId: string, w: Week, guarded: boolean) {
    // Guarded by changes(): the statement before it must have changed a row, i.e. the revision check passed.
    return this.db
      .prepare(
        `INSERT INTO plan_weeks (plan_id, idx, phase, notes) SELECT ?1, ?2, ?3, ?4 ${guarded ? "WHERE changes() > 0" : "WHERE 1"}
         ON CONFLICT (plan_id, idx) DO UPDATE SET phase = excluded.phase, notes = excluded.notes`,
      )
      .bind(planId, w.index, w.phase ?? null, w.notes ?? null);
  }

  async createPlan(userId: string, plan: StoredPlan, sessions: StoredSession[], createHash: string) {
    const existing = () => this.db.prepare("SELECT user_id, create_hash FROM plans WHERE id = ?").bind(plan.id).first<{ user_id: string; create_hash: string | null }>();
    const found = await existing();
    if (found) return { status: "exists" as const, mine: found.user_id === userId, createHash: found.user_id === userId ? found.create_hash : null };

    const statements = [
      this.db
        .prepare(
          `INSERT INTO plans (id, user_id, goal_type, goal_label, goal_date, goal_target_sec, start_date, week_count, source,
             engine_preset_id, engine_version, engine_interview, adaptive, revision, content_revision, updated_at, deleted_at, create_hash)
           VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)`,
        )
        .bind(
          plan.id, userId, plan.goal.type, plan.goal.label ?? null, plan.goal.date ?? null, plan.goal.targetTimeSec ?? null,
          plan.startDate, plan.weekCount, plan.source, plan.engine?.presetId ?? null, plan.engine?.version ?? null,
          plan.engine?.interview ? JSON.stringify(plan.engine.interview) : null, plan.adaptive ? 1 : 0, plan.revision,
          plan.contentRevision, plan.updatedAt, plan.deletedAt, createHash,
        ),
      ...plan.weeks.map((w) => this.insertWeek(plan.id, w, false)),
      ...sessions.map((s) =>
        this.db
          .prepare(
            `INSERT INTO sessions (id, plan_id, user_id, date, type, title, is_key, status, owner, steps, custom, notes, revision, updated_at, deleted_at, create_hash)
             VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)`,
          )
          .bind(s.id, plan.id, userId, ...sessionColumns(s), s.revision, s.updatedAt, s.deletedAt, createHash),
      ),
    ];
    try {
      await this.db.batch(statements); // one transaction: a taken session id leaves no plan behind
    } catch (error) {
      const raced = await existing(); // two creates of the same id at once
      if (raced) return { status: "exists" as const, mine: raced.user_id === userId, createHash: raced.user_id === userId ? raced.create_hash : null };
      // A session id already in use (by any user) rolled the whole batch back.
      for (const s of sessions) {
        if (await this.db.prepare("SELECT 1 AS ok FROM sessions WHERE id = ?").bind(s.id).first()) return { status: "conflict" as const };
      }
      throw error;
    }
    return { status: "created" as const };
  }

  async getPlan(userId: string, planId: string) {
    const row = await this.db.prepare("SELECT * FROM plans WHERE id = ? AND user_id = ? AND deleted_at IS NULL").bind(planId, userId).first<PlanRow>();
    if (!row) return undefined;
    const [weeks, sessions] = await Promise.all([
      this.weeksOf(planId),
      this.db.prepare("SELECT * FROM sessions WHERE plan_id = ? AND deleted_at IS NULL ORDER BY date, id").bind(planId).all<SessionRow>(),
    ]);
    return { plan: planOf(row, weeks), sessions: sessions.results.map(sessionOf), createHash: row.create_hash };
  }

  async listPlans(userId: string, limit: number, after?: { startDate: string; id: string }) {
    const { results } = await (after
      ? this.db
          .prepare(
            `SELECT * FROM plans WHERE user_id = ? AND deleted_at IS NULL AND (start_date < ? OR (start_date = ? AND id < ?))
             ORDER BY start_date DESC, id DESC LIMIT ?`,
          )
          .bind(userId, after.startDate, after.startDate, after.id, limit)
      : this.db.prepare("SELECT * FROM plans WHERE user_id = ? AND deleted_at IS NULL ORDER BY start_date DESC, id DESC LIMIT ?").bind(userId, limit)
    ).all<PlanRow>();
    return results.map((r) => planOf(r, []));
  }

  /** Why a write changed nothing: the row is not this user's live row, or its revision moved. */
  private async planFailure(userId: string, planId: string): Promise<WriteFailure> {
    const row = await this.db.prepare("SELECT revision FROM plans WHERE id = ? AND user_id = ? AND deleted_at IS NULL").bind(planId, userId).first<{ revision: number }>();
    return row ? { ok: false, reason: "conflict", currentRevision: row.revision } : { ok: false, reason: "not_found" };
  }

  async writePlan(userId: string, planId: string, baseRevision: number, fields: PlanWriteFields, now: string) {
    const listed = fields.weeks.map((w) => w.index);
    const results = await this.db.batch([
      this.db
        .prepare(
          `UPDATE plans SET goal_type = ?, goal_label = ?, goal_date = ?, goal_target_sec = ?, adaptive = ?,
             revision = revision + 1, content_revision = content_revision + 1, updated_at = ?
           WHERE id = ? AND user_id = ? AND revision = ? AND deleted_at IS NULL`,
        )
        .bind(fields.goal.type, fields.goal.label ?? null, fields.goal.date ?? null, fields.goal.targetTimeSec ?? null, fields.adaptive ? 1 : 0, now, planId, userId, baseRevision),
      // Each later statement runs only if the one before it changed a row, so a lost revision race writes nothing.
      ...fields.weeks.map((w) => this.insertWeek(planId, w, true)),
      this.db
        .prepare(`DELETE FROM plan_weeks WHERE plan_id = ? AND changes() > 0${listed.length ? ` AND idx NOT IN (${listed.map(() => "?").join(",")})` : ""}`)
        .bind(planId, ...listed),
    ]);
    if (results[0]!.meta.changes === 0) return this.planFailure(userId, planId);
    const got = await this.getPlan(userId, planId);
    return { ok: true as const, plan: got!.plan };
  }

  async deletePlan(userId: string, planId: string, baseRevision: number, now: string) {
    const results = await this.db.batch([
      this.db
        .prepare(
          `UPDATE plans SET deleted_at = ?, revision = revision + 1, content_revision = content_revision + 1, updated_at = ?
           WHERE id = ? AND user_id = ? AND revision = ? AND deleted_at IS NULL`,
        )
        .bind(now, now, planId, userId, baseRevision),
      ...this.unlink(userId, "SELECT id FROM sessions WHERE plan_id = ?", planId, "SELECT 1 FROM plans WHERE id = ? AND deleted_at = ?", planId, now),
    ]);
    return results[0]!.meta.changes > 0 ? { ok: true as const } : this.planFailure(userId, planId);
  }

  /**
   * Unlinks the matches of deleted sessions (backlog 2.21): an activity they had matched goes back to the inbox with a
   * new revision, and the match rows go. Runs in the delete's batch and only if the delete happened, which `deleted`
   * checks by the tombstone time just written.
   */
  private unlink(userId: string, sessions: string, sessionsArg: string, deleted: string, deletedArg: string, now: string) {
    return [
      this.db
        .prepare(
          `UPDATE activities SET disposition = 'inbox', revision = revision + 1, updated_at = ?
           WHERE user_id = ? AND disposition = 'matched'
             AND id IN (SELECT activity_id FROM matches WHERE user_id = ? AND session_id IN (${sessions}))
             AND EXISTS (${deleted})`,
        )
        .bind(now, userId, userId, sessionsArg, deletedArg, now),
      this.db
        .prepare(`DELETE FROM matches WHERE user_id = ? AND session_id IN (${sessions}) AND EXISTS (${deleted})`)
        .bind(userId, sessionsArg, deletedArg, now),
    ];
  }

  async createSession(userId: string, session: StoredSession, createHash: string) {
    const exists = async () => {
      const row = await this.db.prepare("SELECT s.*, p.user_id AS owner_id, p.content_revision AS cr FROM sessions s JOIN plans p ON p.id = s.plan_id WHERE s.id = ?").bind(session.id).first<SessionRow & { owner_id: string; cr: number }>();
      if (!row) return undefined;
      const mine = row.owner_id === userId;
      return mine
        ? { status: "exists" as const, mine, createHash: row.create_hash, session: sessionOf(row), contentRevision: row.cr }
        : { status: "exists" as const, mine, createHash: null };
    };
    const taken = await exists();
    if (taken) return (await this.db.prepare("SELECT 1 AS ok FROM plans WHERE id = ? AND user_id = ? AND deleted_at IS NULL").bind(session.planId, userId).first()) || !taken.mine ? taken : { status: "no_plan" as const };
    try {
      const results = await this.db.batch([
        this.db
          .prepare(
            `INSERT INTO sessions (id, plan_id, user_id, date, type, title, is_key, status, owner, steps, custom, notes, revision, updated_at, deleted_at, create_hash)
             SELECT ?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?10, ?11, ?12, ?13, ?14, ?15, ?16
             WHERE EXISTS (SELECT 1 FROM plans WHERE id = ?2 AND user_id = ?3 AND deleted_at IS NULL)`,
          )
          .bind(session.id, session.planId, userId, ...sessionColumns(session), session.revision, session.updatedAt, session.deletedAt, createHash),
        this.db.prepare("UPDATE plans SET content_revision = content_revision + 1 WHERE id = ? AND changes() > 0 RETURNING content_revision").bind(session.planId),
      ]);
      const bumped = results[1]!.results[0] as { content_revision: number } | undefined;
      return bumped ? { status: "created" as const, contentRevision: bumped.content_revision } : { status: "no_plan" as const };
    } catch (error) {
      const raced = await exists(); // the same id created at the same moment
      if (raced) return raced;
      throw error;
    }
  }

  async getSession(userId: string, sessionId: string) {
    const row = await this.db
      .prepare("SELECT s.* FROM sessions s JOIN plans p ON p.id = s.plan_id WHERE s.id = ? AND p.user_id = ? AND s.deleted_at IS NULL AND p.deleted_at IS NULL")
      .bind(sessionId, userId)
      .first<SessionRow>();
    if (!row) return undefined;
    const plan = await this.db.prepare("SELECT * FROM plans WHERE id = ?").bind(row.plan_id).first<PlanRow>();
    return { session: sessionOf(row), plan: planOf(plan!, []), createHash: row.create_hash };
  }

  private async sessionFailure(userId: string, sessionId: string): Promise<WriteFailure> {
    const row = await this.db
      .prepare("SELECT s.revision FROM sessions s JOIN plans p ON p.id = s.plan_id WHERE s.id = ? AND p.user_id = ? AND s.deleted_at IS NULL AND p.deleted_at IS NULL")
      .bind(sessionId, userId)
      .first<{ revision: number }>();
    return row ? { ok: false, reason: "conflict", currentRevision: row.revision } : { ok: false, reason: "not_found" };
  }

  /** Runs a guarded session update and, in the same transaction, moves the plan's contentRevision. */
  private async change(userId: string, sessionId: string, update: D1PreparedStatement, after: D1PreparedStatement[] = []) {
    const results = await this.db.batch([
      update,
      this.db.prepare("UPDATE plans SET content_revision = content_revision + 1 WHERE id = (SELECT plan_id FROM sessions WHERE id = ?) AND changes() > 0 RETURNING content_revision").bind(sessionId),
      ...after,
    ]);
    const bumped = results[1]!.results[0] as { content_revision: number } | undefined;
    if (results[0]!.meta.changes === 0 || !bumped) return this.sessionFailure(userId, sessionId);
    const row = await this.db.prepare("SELECT * FROM sessions WHERE id = ?").bind(sessionId).first<SessionRow>();
    return { ok: true as const, session: sessionOf(row!), contentRevision: bumped.content_revision };
  }

  async writeSession(userId: string, sessionId: string, baseRevision: number, next: SessionContent, now: string) {
    return this.change(
      userId,
      sessionId,
      this.db
        .prepare(
          `UPDATE sessions SET date = ?, type = ?, title = ?, is_key = ?, status = ?, owner = ?, steps = ?, custom = ?, notes = ?,
             revision = revision + 1, updated_at = ?
           WHERE id = ? AND revision = ? AND deleted_at IS NULL
             AND plan_id IN (SELECT id FROM plans WHERE user_id = ? AND deleted_at IS NULL)`,
        )
        .bind(...sessionColumns(next), now, sessionId, baseRevision, userId),
    );
  }

  async deleteSession(userId: string, sessionId: string, baseRevision: number, now: string) {
    return this.change(
      userId,
      sessionId,
      this.db
        .prepare(
          `UPDATE sessions SET deleted_at = ?, revision = revision + 1, updated_at = ?
           WHERE id = ? AND revision = ? AND deleted_at IS NULL
             AND plan_id IN (SELECT id FROM plans WHERE user_id = ? AND deleted_at IS NULL)`,
        )
        .bind(now, now, sessionId, baseRevision, userId),
      this.unlink(userId, "?", sessionId, "SELECT 1 FROM sessions WHERE id = ? AND deleted_at = ?", sessionId, now),
    );
  }
}
