// POST /v1/sync (task 2.6, design §8.2): the offline edit queue. Operations apply in order, each under an idempotency
// key; a conflict is a revision mismatch, never a clock comparison. The server stops when its D1 query budget
// (50 a request on Workers Free) runs out, answers the operations it reached and leaves the rest for the next call.
import { Hono, type Context } from "hono";
import { sameCheckIn } from "../domain/checkins";
import { canonicalHash } from "../domain/plan-hash";
import { parsePlanUpdate, parseSessionCreate, parseSessionUpdate, type SessionContent, type Week } from "../domain/plan-input";
import { applySessionUpdate } from "../domain/session-edit";
import { encodeCursor, FIXED_QUERIES, KEY_LOOKUP_CHUNK, opCost, parseSyncRequest, PULL_LIMITS, QUERY_LIMIT, type SyncOp } from "../domain/sync";
import type { AppliedOp, Deps, StoredPlan, StoredSession } from "../ports";
import { requireScope, type AuthVariables } from "./auth";
import { planView, sessionView } from "./plans";
import { problem } from "./problem";
import { proposalView, raiseForPain } from "./proposals";

const MAX_BODY_BYTES = 1_000_000;

interface Outcome {
  status: "applied" | "conflict" | "rejected";
  revision?: number;
  problem?: Record<string, unknown>;
  server?: unknown;
}

const rejected = (status: number, type: string, title: string, extra: Record<string, unknown> = {}): Outcome => ({ status: "rejected", problem: { type, title, status, ...extra } });
const notFound = () => rejected(404, "not_found", "Not found");
const idInUse = () => rejected(409, "id_in_use", "That id is already in use");
const invalid = (errors: unknown) => rejected(400, "validation_failed", "Some fields are invalid", { errors });
const conflict = (currentRevision: number, server?: unknown): Outcome => ({
  status: "conflict",
  problem: { type: "revision_conflict", title: "This changed since you loaded it", status: 409, currentRevision },
  ...(server ? { server } : {}),
});

export function syncRoutes(deps: Deps) {
  const app = new Hono<{ Variables: AuthVariables }>();
  const auth = requireScope(deps, "app");

  async function readJson(c: Context): Promise<{ body: unknown } | { response: Response }> {
    const tooLarge = () => ({ response: problem(c, 413, "payload_too_large", "That is too large") });
    if (Number(c.req.header("content-length") ?? 0) > MAX_BODY_BYTES) return tooLarge();
    const text = await c.req.text();
    if (new TextEncoder().encode(text).length > MAX_BODY_BYTES) return tooLarge();
    try {
      return { body: JSON.parse(text) };
    } catch {
      return { response: problem(c, 400, "bad_request", "Send JSON") };
    }
  }

  /** Applies one operation. Each branch stays inside the query cost `OP_COST` gives its kind. */
  async function apply(userId: string, op: SyncOp, now: string): Promise<Outcome> {
    switch (op.kind) {
      case "plan.create": {
        const input = op.data;
        const plan: StoredPlan = {
          id: input.id, goal: input.goal, startDate: input.startDate, weekCount: input.weekCount, source: input.source,
          ...(input.engine ? { engine: input.engine } : {}), adaptive: input.adaptive, weeks: input.weeks,
          revision: 1, contentRevision: 1, updatedAt: now, deletedAt: null,
        };
        const sessions: StoredSession[] = input.sessions.map((s) => ({ ...s, planId: input.id, revision: 1, updatedAt: now, deletedAt: null }));
        const hash = await canonicalHash(input);
        const made = await deps.plans.createPlan(userId, plan, sessions, hash);
        if (made.status === "created") return { status: "applied", revision: 1 };
        if (made.status === "conflict") return idInUse();
        if (made.mine && made.createHash === hash) {
          const stored = await deps.plans.getPlan(userId, input.id);
          if (stored) return { status: "applied", revision: stored.plan.revision };
        }
        return idInUse();
      }
      case "plan.update": {
        const got = await deps.plans.getPlan(userId, op.id);
        if (!got) return notFound();
        const parsed = parsePlanUpdate(op.data, got.plan.weekCount);
        if (!parsed.ok) return invalid(parsed.errors);
        if (got.plan.revision !== op.baseRevision) return conflict(got.plan.revision, planView(got.plan));
        const weeks = new Map<number, Week>(got.plan.weeks.map((w) => [w.index, w]));
        for (const w of parsed.value.weeks ?? []) weeks.set(w.index, w);
        const written = await deps.plans.writePlan(
          userId, op.id, op.baseRevision,
          { goal: parsed.value.goal ?? got.plan.goal, adaptive: parsed.value.adaptive ?? got.plan.adaptive, weeks: [...weeks.values()].sort((a, b) => a.index - b.index) },
          now,
        );
        if (written.ok) return { status: "applied", revision: written.plan.revision };
        if (written.reason === "not_found") return notFound();
        const fresh = await deps.plans.getPlan(userId, op.id);
        return conflict(written.currentRevision, fresh && planView(fresh.plan));
      }
      case "plan.delete": {
        const deleted = await deps.plans.deletePlan(userId, op.id, op.baseRevision, now);
        if (deleted.ok) return { status: "applied", revision: op.baseRevision + 1 };
        if (deleted.reason === "not_found") return notFound();
        const fresh = await deps.plans.getPlan(userId, op.id);
        return conflict(deleted.currentRevision, fresh && planView(fresh.plan));
      }
      case "session.create": {
        const got = await deps.plans.getPlan(userId, op.planId);
        if (!got) return notFound();
        const parsed = parseSessionCreate({ ...op.data, id: op.id }, { startDate: got.plan.startDate, weekCount: got.plan.weekCount });
        if (!parsed.ok) return invalid(parsed.errors);
        const hash = await canonicalHash(parsed.value);
        // A session the user adds is theirs, so the engine never changes it.
        const session: StoredSession = { ...parsed.value, owner: "user", planId: op.planId, revision: 1, updatedAt: now, deletedAt: null };
        const made = await deps.plans.createSession(userId, session, hash);
        if (made.status === "created") return { status: "applied", revision: 1 };
        if (made.status === "no_plan") return notFound();
        if (made.mine && made.createHash === hash && made.session && made.session.planId === op.planId && made.session.deletedAt === null) {
          return { status: "applied", revision: made.session.revision };
        }
        return idInUse();
      }
      case "session.update": {
        const got = await deps.plans.getSession(userId, op.id);
        if (!got) return notFound();
        const parsed = parseSessionUpdate(op.data, { startDate: got.plan.startDate, weekCount: got.plan.weekCount }, got.session.type);
        if (!parsed.ok) return invalid(parsed.errors);
        if (got.session.revision !== op.baseRevision) return conflict(got.session.revision, sessionView(got.session));
        const { id: _id, planId: _plan, revision: _rev, updatedAt: _at, deletedAt: _del, ...content } = got.session;
        const next: SessionContent = applySessionUpdate(content, parsed.value, parsed.onlyStatus);
        const written = await deps.plans.writeSession(userId, op.id, op.baseRevision, next, now);
        if (written.ok) return { status: "applied", revision: written.session.revision };
        if (written.reason === "not_found") return notFound();
        const fresh = await deps.plans.getSession(userId, op.id);
        return conflict(written.currentRevision, fresh && sessionView(fresh.session));
      }
      case "session.delete": {
        const deleted = await deps.plans.deleteSession(userId, op.id, op.baseRevision, now);
        if (deleted.ok) return { status: "applied", revision: deleted.session.revision };
        if (deleted.reason === "not_found") return notFound();
        const fresh = await deps.plans.getSession(userId, op.id);
        return conflict(deleted.currentRevision, fresh && sessionView(fresh.session));
      }
      case "checkin.create": {
        const made = await deps.checkIns.create(userId, { ...op.data, id: op.id, sessionId: op.sessionId, revision: 1, updatedAt: now, deletedAt: null });
        if (made.status === "created") {
          // The pain flag's urgent proposal, as on the check-in endpoint; `opCost` reserves its queries.
          await raiseForPain(deps, userId, made.checkIn);
          return { status: "applied", revision: 1 };
        }
        if (made.status === "no_session") return notFound();
        if (made.mine && sameCheckIn(made.checkIn, { ...op.data, sessionId: op.sessionId })) return { status: "applied", revision: made.checkIn.revision };
        return idInUse();
      }
    }
  }

  app.post("/v1/sync", auth, async (c) => {
    const read = await readJson(c);
    if ("response" in read) return read.response;
    const parsed = parseSyncRequest(read.body);
    if (!parsed.ok) return problem(c, 400, "validation_failed", "Some fields are invalid", {}, { errors: parsed.errors });
    const { cursor, operations } = parsed.value;
    const userId = c.get("userId");
    const now = deps.clock.now().toISOString();

    // The query budget: what is left after the work every call does (token check, remembering keys, the pull).
    let budget = QUERY_LIMIT - FIXED_QUERIES;
    const known = new Map<string, AppliedOp>();
    let looked = 0;
    const results: Record<string, unknown>[] = [];
    const applied: AppliedOp[] = [];

    for (const [i, op] of operations.entries()) {
      // Keys are looked up a chunk at a time, when the loop reaches one not yet looked up.
      if (i >= looked) {
        if (budget < 1) break;
        budget -= 1;
        const chunk = operations.slice(i, i + KEY_LOOKUP_CHUNK);
        for (const found of await deps.sync.findOps(userId, chunk.map((o) => o.idempotencyKey))) known.set(found.idempotencyKey, found);
        looked = i + chunk.length;
      }
      const { idempotencyKey } = op;
      const { idempotencyKey: _k, ...rest } = op;
      const opHash = await canonicalHash(rest);
      const remembered = known.get(idempotencyKey);
      if (remembered) {
        // A retry costs nothing. The same key on a different edit is a client bug, not a retry.
        results.push(
          remembered.opHash === opHash
            ? { idempotencyKey, status: "duplicate", revision: remembered.revision }
            : { idempotencyKey, ...rejected(409, "idempotency_key_reused", "That idempotency key was used for a different edit") },
        );
        continue;
      }
      const cost = opCost(op);
      if (budget < cost) break;
      budget -= cost;
      const outcome = await apply(userId, op, now);
      results.push({ idempotencyKey, ...outcome });
      if (outcome.status === "applied" && outcome.revision !== undefined) applied.push({ idempotencyKey, opHash, revision: outcome.revision });
    }
    // Only applied edits are remembered: a conflict or rejection is looked at afresh when the client resends it.
    await deps.sync.recordOps(userId, applied, now);

    // Proposals whose plan moved are written as stale first, so the pull carries them with a new `updatedAt`.
    await deps.proposals.markStale(userId, now);
    const changes = await deps.sync.changesSince(userId, cursor, PULL_LIMITS);
    return c.json({
      results,
      changes: {
        plans: changes.plans.map(planView),
        sessions: changes.sessions.map(sessionView),
        checkins: changes.checkins,
        proposals: changes.proposals.map(proposalView),
      },
      cursor: encodeCursor(changes.cursor),
      hasMore: changes.hasMore,
    });
  });

  return app;
}
