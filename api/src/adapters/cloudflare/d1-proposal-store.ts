import { acceptedChanges, type ProposalChangeRecord, type ProposalPlanChanges, type ProposalStatus, type StoredProposal } from "../../domain/proposal-model";
import type { ProposalStore, StoredCheckIn } from "../../ports";
import { toCheckIn, type CheckInRow } from "./d1-checkin-store";
import { sessionColumns } from "./d1-plan-store";

export interface ProposalRow {
  id: string;
  plan_id: string;
  base_content_revision: number;
  kind: StoredProposal["kind"];
  creator_type: "rules" | "ai";
  creator_version: string;
  reason: string;
  urgent: number;
  changes: string;
  plan_changes: string | null;
  status: ProposalStatus;
  resolved_at: string | null;
  created_at: string;
  revision: number;
  updated_at: string;
  deleted_at: string | null;
  draft_key: string | null;
  /** Present on reads that work out staleness: the status a client should see. */
  eff_status?: ProposalStatus;
}

export const proposalOf = (r: ProposalRow): StoredProposal => ({
  id: r.id,
  planId: r.plan_id,
  baseContentRevision: r.base_content_revision,
  kind: r.kind,
  creator: { type: r.creator_type, version: r.creator_version },
  reason: r.reason,
  urgent: r.urgent === 1,
  changes: JSON.parse(r.changes),
  ...(r.plan_changes !== null ? { planChanges: JSON.parse(r.plan_changes) } : {}),
  status: r.eff_status ?? r.status,
  createdAt: r.created_at,
  updatedAt: r.updated_at,
  deletedAt: r.deleted_at,
  resolvedAt: r.resolved_at,
  revision: r.revision,
  ...(r.draft_key !== null ? { key: r.draft_key } : {}),
});

/** A proposal's status as a client should see it: pending turns stale once the plan's content revision has moved on. */
const WITH_STATUS = `SELECT p.*, CASE WHEN p.status = 'pending' AND p.base_content_revision <> pl.content_revision THEN 'stale' ELSE p.status END AS eff_status
  FROM proposals p JOIN plans pl ON pl.id = p.plan_id WHERE p.user_id = ? AND pl.user_id = ? AND p.deleted_at IS NULL AND pl.deleted_at IS NULL`;

export class D1ProposalStore implements ProposalStore {
  constructor(private readonly db: D1Database) {}

  async create(userId: string, proposals: StoredProposal[]) {
    if (proposals.length === 0) return true;
    // Each insert only runs if the plan is still the user's live plan at the revision the proposal was built on.
    const results = await this.db.batch(
      proposals.map((p) =>
        this.db
          .prepare(
            `INSERT INTO proposals (id, plan_id, user_id, base_content_revision, kind, creator_type, creator_version, reason, urgent, changes,
               plan_changes, status, resolved_at, created_at, revision, updated_at, deleted_at, draft_key)
             SELECT ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?
             WHERE EXISTS (SELECT 1 FROM plans WHERE id = ? AND user_id = ? AND deleted_at IS NULL AND content_revision = ?)`,
          )
          .bind(
            p.id, p.planId, userId, p.baseContentRevision, p.kind, p.creator.type, p.creator.version, p.reason, p.urgent ? 1 : 0, JSON.stringify(p.changes),
            p.planChanges ? JSON.stringify(p.planChanges) : null, p.status, p.resolvedAt, p.createdAt, p.revision, p.updatedAt, p.deletedAt, p.key ?? null,
            p.planId, userId, p.baseContentRevision,
          ),
      ),
    );
    return results.every((r) => r.meta.changes > 0);
  }

  async list(userId: string, planId: string, status: ProposalStatus) {
    const { results } = await this.db
      .prepare(`SELECT * FROM (${WITH_STATUS} AND p.plan_id = ?) WHERE eff_status = ? ORDER BY created_at DESC, id DESC LIMIT 200`)
      .bind(userId, userId, planId, status)
      .all<ProposalRow>();
    return results.map(proposalOf);
  }

  async usedKeys(userId: string, planId: string) {
    const { results } = await this.db
      .prepare(`SELECT draft_key FROM (${WITH_STATUS} AND p.plan_id = ?) WHERE draft_key IS NOT NULL AND eff_status <> 'stale'`)
      .bind(userId, userId, planId)
      .all<{ draft_key: string }>();
    return results.map((r) => r.draft_key);
  }

  async checkInsForPlan(userId: string, planId: string): Promise<StoredCheckIn[]> {
    const { results } = await this.db
      .prepare(
        `SELECT c.* FROM checkins c JOIN sessions s ON s.id = c.session_id JOIN plans p ON p.id = s.plan_id
         WHERE c.user_id = ?1 AND p.user_id = ?1 AND s.plan_id = ?2 AND c.deleted_at IS NULL AND s.deleted_at IS NULL AND p.deleted_at IS NULL
         ORDER BY c.updated_at, c.id`,
      )
      .bind(userId, planId)
      .all<CheckInRow>();
    return results.map(toCheckIn);
  }

  async markStale(userId: string, now: string) {
    await this.db
      .prepare(
        `UPDATE proposals SET status = 'stale', revision = revision + 1, updated_at = ?
         WHERE user_id = ? AND status = 'pending' AND deleted_at IS NULL
           AND base_content_revision <> (SELECT content_revision FROM plans WHERE plans.id = proposals.plan_id)`,
      )
      .bind(now, userId)
      .run();
  }

  private one(userId: string, proposalId: string) {
    return this.db.prepare(`${WITH_STATUS} AND p.id = ?`).bind(userId, userId, proposalId).first<ProposalRow>();
  }

  /** Why a guarded write changed nothing. */
  private async failure(userId: string, proposalId: string) {
    const row = await this.one(userId, proposalId);
    if (!row) return { ok: false as const, reason: "not_found" as const };
    const status = row.eff_status ?? row.status;
    return { ok: false as const, reason: "not_pending" as const, status: status === "pending" ? ("stale" as const) : status };
  }

  /** The claim that decides a status change: only a pending proposal on a plan still at its base revision. */
  private claim(status: "accepted" | "dismissed", userId: string, proposalId: string, now: string) {
    return this.db
      .prepare(
        `UPDATE proposals SET status = ?, resolved_at = ?, updated_at = ?, revision = revision + 1
         WHERE id = ? AND user_id = ? AND status = 'pending' AND deleted_at IS NULL
           AND base_content_revision = (SELECT content_revision FROM plans WHERE id = proposals.plan_id AND user_id = ? AND deleted_at IS NULL)`,
      )
      .bind(status, now, now, proposalId, userId, userId);
  }

  async dismiss(userId: string, proposalId: string, now: string) {
    const result = await this.claim("dismissed", userId, proposalId, now).run();
    if (result.meta.changes === 0) return this.failure(userId, proposalId);
    const row = await this.one(userId, proposalId);
    return { ok: true as const, proposal: proposalOf(row!) };
  }

  async accept(userId: string, proposalId: string, includeUserOwned: boolean, now: string) {
    const row = await this.one(userId, proposalId);
    if (!row) return { ok: false as const, reason: "not_found" as const };
    if ((row.eff_status ?? row.status) !== "pending") return this.failure(userId, proposalId);
    const proposal = proposalOf(row);
    const planId = proposal.planId;
    const changes = acceptedChanges(proposal.changes, includeUserOwned);
    const statements = [
      this.claim("accepted", userId, proposalId, now),
      // Everything below runs in the same transaction; if the claim changed no row this fails and nothing is written.
      this.db.prepare("SELECT json('{') WHERE changes() = 0"),
      ...changes.map((c) => this.apply(userId, planId, c, now)),
      ...this.unlink(userId, planId, changes, now),
      this.planUpdate(userId, planId, proposal.planChanges, now),
      ...this.weekStatements(planId, proposal.planChanges),
    ];
    try {
      await this.db.batch(statements);
    } catch (error) {
      if (!String((error as Error).message).includes("malformed JSON")) throw error;
      return this.failure(userId, proposalId);
    }
    return { ok: true as const, planId };
  }

  private apply(userId: string, planId: string, c: ProposalChangeRecord, now: string) {
    if (c.op === "create") {
      return this.db
        .prepare(
          `INSERT INTO sessions (id, plan_id, user_id, date, type, title, is_key, status, owner, steps, custom, notes, revision, updated_at, deleted_at, create_hash)
           VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, 1, ?, NULL, NULL)`,
        )
        .bind(c.sessionId, planId, userId, ...sessionColumns(c.after), now);
    }
    if (c.op === "update") {
      return this.db
        .prepare(
          `UPDATE sessions SET date = ?, type = ?, title = ?, is_key = ?, status = ?, owner = ?, steps = ?, custom = ?, notes = ?,
             revision = revision + 1, updated_at = ?
           WHERE id = ? AND plan_id = ? AND deleted_at IS NULL`,
        )
        .bind(...sessionColumns(c.after), now, c.sessionId, planId);
    }
    return this.db.prepare("UPDATE sessions SET deleted_at = ?, revision = revision + 1, updated_at = ? WHERE id = ? AND plan_id = ? AND deleted_at IS NULL").bind(now, now, c.sessionId, planId);
  }

  /** The matches of the sessions just deleted go, and an activity they had matched returns to the inbox (task 2.21). */
  private unlink(userId: string, planId: string, changes: ProposalChangeRecord[], now: string) {
    if (!changes.some((c) => c.op === "delete")) return [];
    const gone = "SELECT id FROM sessions WHERE plan_id = ? AND deleted_at = ?";
    return [
      this.db
        .prepare(
          `UPDATE activities SET disposition = 'inbox', revision = revision + 1, updated_at = ?
           WHERE user_id = ? AND disposition = 'matched' AND id IN (SELECT activity_id FROM matches WHERE user_id = ? AND session_id IN (${gone}))`,
        )
        .bind(now, userId, userId, planId, now),
      this.db.prepare(`DELETE FROM matches WHERE user_id = ? AND session_id IN (${gone})`).bind(userId, planId, now),
    ];
  }

  /** The plan moves once: its content revision always, its revision too when plan-level changes apply. */
  private planUpdate(userId: string, planId: string, p: ProposalPlanChanges | undefined, now: string) {
    const sets: string[] = [];
    const binds: unknown[] = [];
    if (p?.goal) {
      sets.push("goal_type = ?", "goal_label = ?", "goal_date = ?", "goal_target_sec = ?");
      binds.push(p.goal.type, p.goal.label ?? null, p.goal.date ?? null, p.goal.targetTimeSec ?? null);
    }
    if (p?.weekCount !== undefined) {
      sets.push("week_count = ?");
      binds.push(p.weekCount);
    }
    if (p?.engine) {
      sets.push("engine_preset_id = ?", "engine_version = ?", "engine_interview = ?");
      binds.push(p.engine.presetId, p.engine.version, p.engine.interview ? JSON.stringify(p.engine.interview) : null);
    }
    if (p) sets.push("revision = revision + 1");
    return this.db
      .prepare(`UPDATE plans SET ${[...sets, "content_revision = content_revision + 1", "updated_at = ?"].join(", ")} WHERE id = ? AND user_id = ?`)
      .bind(...binds, now, planId, userId);
  }

  private weekStatements(planId: string, p: ProposalPlanChanges | undefined) {
    if (!p) return [];
    return [
      ...(p.weeks ?? []).map((w) =>
        this.db
          .prepare("INSERT INTO plan_weeks (plan_id, idx, phase, notes) VALUES (?, ?, ?, ?) ON CONFLICT (plan_id, idx) DO UPDATE SET phase = excluded.phase, notes = excluded.notes")
          .bind(planId, w.index, w.phase ?? null, w.notes ?? null),
      ),
      ...(p.weekCount !== undefined ? [this.db.prepare("DELETE FROM plan_weeks WHERE plan_id = ? AND idx >= ?").bind(planId, p.weekCount)] : []),
    ];
  }
}
