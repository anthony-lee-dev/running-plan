import { Hono, type Context } from "hono";
import { canonicalHash } from "../domain/plan-hash";
import { dayNumber, parsePlanCreate, parsePlanUpdate, parseSessionCreate, parseSessionUpdate, type SessionContent, type Week } from "../domain/plan-input";
import { applySessionUpdate } from "../domain/session-edit";
import { validatePlan } from "../domain/validators";
import type { Deps, StoredPlan, StoredSession } from "../ports";
import { requireScope, type AuthVariables } from "./auth";
import { problem } from "./problem";
import { parseIfMatch } from "./profile";

const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;
const MAX_BODY_BYTES = 1_000_000;

const syncMeta = (e: { id: string; revision: number; updatedAt: string; deletedAt: string | null }) => ({
  id: e.id,
  revision: e.revision,
  updatedAt: e.updatedAt,
  deletedAt: e.deletedAt,
});

export const sessionView = (s: StoredSession) => ({
  ...syncMeta(s),
  planId: s.planId,
  date: s.date,
  type: s.type,
  ...(s.title !== undefined ? { title: s.title } : {}),
  key: s.key ?? false,
  status: s.status,
  owner: s.owner,
  steps: s.steps,
  ...(s.custom ? { custom: s.custom } : {}),
  ...(s.notes !== undefined ? { notes: s.notes } : {}),
});

const planFields = (p: StoredPlan) => ({
  goal: p.goal,
  startDate: p.startDate,
  weekCount: p.weekCount,
  source: p.source,
  ...(p.engine ? { engine: p.engine } : {}),
  adaptive: p.adaptive,
});

/** The validators' findings for a plan, in the spec's Warning shape. They warn and never block. */
export function warningsFor(plan: StoredPlan, sessions: StoredSession[]) {
  const baseline = plan.engine?.interview?.weeklyDistanceM;
  const { warnings } = validatePlan(
    { startDate: plan.startDate, weekCount: plan.weekCount, sessions, ...(plan.goal.date ? { goalDate: plan.goal.date } : {}) },
    typeof baseline === "number" ? { baselineWeeklyM: baseline } : {},
  );
  return warnings.map((w) => ({ code: w.code, severity: w.severity, message: w.message, weekIndex: w.weekIndex, ...(w.sessionIds ? { sessionIds: w.sessionIds.slice(0, 20) } : {}) }));
}

const planDetail = (plan: StoredPlan, sessions: StoredSession[]) => ({
  ...syncMeta(plan),
  ...planFields(plan),
  weeks: plan.weeks,
  contentRevision: plan.contentRevision,
  sessions: sessions.map(sessionView),
  warnings: warningsFor(plan, sessions),
});

const encodeCursor = (p: { startDate: string; id: string }) => btoa(JSON.stringify({ s: p.startDate, i: p.id })).replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/, "");
function decodeCursor(text: string): { startDate: string; id: string } | undefined {
  try {
    const padded = text.replace(/-/g, "+").replace(/_/g, "/").padEnd(Math.ceil(text.length / 4) * 4, "=");
    const value = JSON.parse(atob(padded)) as { s?: unknown; i?: unknown };
    return dayNumber(value.s) !== undefined && typeof value.i === "string" && UUID.test(value.i) ? { startDate: value.s as string, id: value.i } : undefined;
  } catch {
    return undefined;
  }
}

export function planRoutes(deps: Deps) {
  const app = new Hono<{ Variables: AuthVariables }>();
  const auth = requireScope(deps, "app");
  app.use("/v1/plans", auth);
  app.use("/v1/plans/*", auth);
  app.use("/v1/sessions/*", auth);

  const now = () => deps.clock.now().toISOString();
  const notFound = (c: Context) => problem(c, 404, "not_found", "Not found");
  const needIfMatch = (c: Context) => problem(c, 400, "bad_request", 'Send If-Match with the revision you edited, like "7"');
  const conflict = (c: Context, currentRevision: number) => problem(c, 409, "revision_conflict", "This changed since you loaded it", {}, { currentRevision });
  const invalid = (c: Context, errors: unknown) => problem(c, 400, "validation_failed", "Some fields are invalid", {}, { errors });
  const withEtag = (body: unknown, status: number, revision?: number) =>
    new Response(JSON.stringify(body), { status, headers: { "content-type": "application/json", ...(revision !== undefined ? { etag: `"${revision}"` } : {}) } });

  /** The parsed JSON body, or a problem response. */
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

  async function sessionResult(c: Context, userId: string, planId: string, session: StoredSession, contentRevision: number, status: 200 | 201) {
    const got = await deps.plans.getPlan(userId, planId);
    const body = { session: sessionView(session), planContentRevision: contentRevision, warnings: got ? warningsFor(got.plan, got.sessions) : [] };
    return c.json(body, status);
  }

  app.get("/v1/plans", async (c) => {
    const limitText = c.req.query("limit");
    const limit = limitText === undefined ? 50 : /^\d{1,3}$/.test(limitText) ? Number(limitText) : 0;
    if (limit < 1 || limit > 200) return problem(c, 400, "bad_request", "limit is 1 to 200");
    const cursorText = c.req.query("cursor");
    const after = cursorText === undefined ? undefined : decodeCursor(cursorText);
    if (cursorText !== undefined && !after) return problem(c, 400, "bad_request", "That cursor is not valid");
    const plans = await deps.plans.listPlans(c.get("userId"), limit + 1, after);
    const page = plans.slice(0, limit);
    const last = page.at(-1);
    return c.json({
      plans: page.map((p) => ({ ...syncMeta(p), goal: p.goal, startDate: p.startDate, weekCount: p.weekCount, source: p.source, adaptive: p.adaptive })),
      ...(plans.length > limit && last ? { nextCursor: encodeCursor(last) } : {}),
    });
  });

  app.post("/v1/plans", async (c) => {
    const read = await readJson(c);
    if ("response" in read) return read.response;
    const parsed = parsePlanCreate(read.body);
    if (!parsed.ok) return invalid(c, parsed.errors);
    const input = parsed.value;
    const userId = c.get("userId");
    const at = now();
    const plan: StoredPlan = {
      id: input.id, goal: input.goal, startDate: input.startDate, weekCount: input.weekCount, source: input.source,
      ...(input.engine ? { engine: input.engine } : {}), adaptive: input.adaptive, weeks: input.weeks,
      revision: 1, contentRevision: 1, updatedAt: at, deletedAt: null,
    };
    const sessions: StoredSession[] = input.sessions.map((s) => ({ ...s, planId: input.id, revision: 1, updatedAt: at, deletedAt: null }));
    const hash = await canonicalHash(input);
    const outcome = await deps.plans.createPlan(userId, plan, sessions, hash);
    if (outcome.status === "conflict") return problem(c, 409, "conflict", "A session id is already in use");
    if (outcome.status === "created") return withEtag(planDetail(plan, sessions), 201, 1);
    // The id is taken: only an identical repeat by its owner is an answer; anything else is a conflict.
    if (outcome.mine && outcome.createHash === hash) {
      const stored = await deps.plans.getPlan(userId, input.id);
      if (stored) return withEtag(planDetail(stored.plan, stored.sessions), 200, stored.plan.revision);
    }
    return problem(c, 409, "conflict", "That id is already in use");
  });

  const planId = (c: Context) => {
    const id = c.req.param("planId") ?? "";
    return UUID.test(id) ? id : undefined;
  };

  app.get("/v1/plans/:planId", async (c) => {
    const id = planId(c);
    const got = id && (await deps.plans.getPlan(c.get("userId"), id));
    return got ? withEtag(planDetail(got.plan, got.sessions), 200, got.plan.revision) : notFound(c);
  });

  app.patch("/v1/plans/:planId", async (c) => {
    const base = parseIfMatch(c.req.header("if-match"));
    if (base === undefined) return needIfMatch(c);
    const id = planId(c);
    const userId = c.get("userId");
    const got = id ? await deps.plans.getPlan(userId, id) : undefined;
    if (!id || !got) return notFound(c);
    const read = await readJson(c);
    if ("response" in read) return read.response;
    const parsed = parsePlanUpdate(read.body, got.plan.weekCount);
    if (!parsed.ok) return invalid(c, parsed.errors);
    if (got.plan.revision !== base) return conflict(c, got.plan.revision);

    // Weeks are matched by index: a listed week replaces that week, the others stay.
    const weeks = new Map<number, Week>(got.plan.weeks.map((w) => [w.index, w]));
    for (const w of parsed.value.weeks ?? []) weeks.set(w.index, w);
    const result = await deps.plans.writePlan(
      userId, id, base,
      {
        goal: parsed.value.goal ?? got.plan.goal,
        adaptive: parsed.value.adaptive ?? got.plan.adaptive,
        weeks: [...weeks.values()].sort((a, b) => a.index - b.index),
      },
      now(),
    );
    if (!result.ok) return result.reason === "conflict" ? conflict(c, result.currentRevision) : notFound(c);
    const fresh = await deps.plans.getPlan(userId, id);
    return fresh ? withEtag(planDetail(fresh.plan, fresh.sessions), 200, fresh.plan.revision) : notFound(c);
  });

  app.delete("/v1/plans/:planId", async (c) => {
    const base = parseIfMatch(c.req.header("if-match"));
    if (base === undefined) return needIfMatch(c);
    const id = planId(c);
    if (!id) return notFound(c);
    const result = await deps.plans.deletePlan(c.get("userId"), id, base, now());
    if (result.ok) return c.body(null, 204);
    return result.reason === "conflict" ? conflict(c, result.currentRevision) : notFound(c);
  });

  app.post("/v1/plans/:planId/sessions", async (c) => {
    const id = planId(c);
    const userId = c.get("userId");
    const got = id ? await deps.plans.getPlan(userId, id) : undefined;
    if (!id || !got) return notFound(c);
    const read = await readJson(c);
    if ("response" in read) return read.response;
    const parsed = parseSessionCreate(read.body, { startDate: got.plan.startDate, weekCount: got.plan.weekCount });
    if (!parsed.ok) return invalid(c, parsed.errors);
    const hash = await canonicalHash(parsed.value);
    // A session the user adds is theirs, so the engine never changes it.
    const session: StoredSession = { ...parsed.value, owner: "user", planId: id, revision: 1, updatedAt: now(), deletedAt: null };
    const outcome = await deps.plans.createSession(userId, session, hash);
    if (outcome.status === "no_plan") return notFound(c);
    if (outcome.status === "created") return sessionResult(c, userId, id, session, outcome.contentRevision, 201);
    if (outcome.mine && outcome.createHash === hash && outcome.session && outcome.session.planId === id && outcome.session.deletedAt === null) {
      return sessionResult(c, userId, id, outcome.session, outcome.contentRevision ?? got.plan.contentRevision, 200);
    }
    return problem(c, 409, "conflict", "That id is already in use");
  });

  const sessionId = (c: Context) => {
    const id = c.req.param("sessionId") ?? "";
    return UUID.test(id) ? id : undefined;
  };

  app.patch("/v1/sessions/:sessionId", async (c) => {
    const base = parseIfMatch(c.req.header("if-match"));
    if (base === undefined) return needIfMatch(c);
    const id = sessionId(c);
    const userId = c.get("userId");
    const got = id ? await deps.plans.getSession(userId, id) : undefined;
    if (!id || !got) return notFound(c);
    const read = await readJson(c);
    if ("response" in read) return read.response;
    const parsed = parseSessionUpdate(read.body, { startDate: got.plan.startDate, weekCount: got.plan.weekCount }, got.session.type);
    if (!parsed.ok) return invalid(c, parsed.errors);
    if (got.session.revision !== base) return conflict(c, got.session.revision);

    const { id: _id, planId: _plan, revision: _rev, updatedAt: _at, deletedAt: _del, ...content } = got.session;
    const next: SessionContent = applySessionUpdate(content, parsed.value, parsed.onlyStatus);
    const result = await deps.plans.writeSession(userId, id, base, next, now());
    if (!result.ok) return result.reason === "conflict" ? conflict(c, result.currentRevision) : notFound(c);
    return sessionResult(c, userId, got.session.planId, result.session, result.contentRevision, 200);
  });

  app.delete("/v1/sessions/:sessionId", async (c) => {
    const base = parseIfMatch(c.req.header("if-match"));
    if (base === undefined) return needIfMatch(c);
    const id = sessionId(c);
    const userId = c.get("userId");
    if (!id) return notFound(c);
    const result = await deps.plans.deleteSession(userId, id, base, now());
    if (!result.ok) return result.reason === "conflict" ? conflict(c, result.currentRevision) : notFound(c);
    return sessionResult(c, userId, result.session.planId, result.session, result.contentRevision, 200);
  });

  return app;
}
