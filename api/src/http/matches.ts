// Matches and dispositions (task 2.12): link an imported activity to a session, unlink it, or mark an activity as
// an extra run or ignored. The rules are in domain/matches.ts; the store writes each change in one transaction.
import { Hono, type Context } from "hono";
import { planMatchChange, type MatchChange, type MatchState } from "../domain/matches";
import { MatchConflictError, type Deps } from "../ports";
import { requireScope, type AuthVariables } from "./auth";
import { activityView } from "./activities";
import { sessionView, warningsFor } from "./plans";
import { problem } from "./problem";
import { readBody } from "./validate";

const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;
const ATTEMPTS = 3;

export function matchRoutes(deps: Deps) {
  const app = new Hono<{ Variables: AuthVariables }>();
  const auth = requireScope(deps, "app");
  const notFound = (c: Context) => problem(c, 404, "not_found", "Not found");
  const invalid = (c: Context, message: string) => problem(c, 400, "bad_request", message);

  /**
   * Loads, decides and writes, again from a fresh read when something changed in between. `found` says whether the
   * state has what the change needs; when it does not, the result is undefined (a 404).
   */
  async function run(userId: string, ref: { sessionId?: string; activityId?: string }, change: MatchChange, found: (s: MatchState) => boolean) {
    for (let attempt = 1; ; attempt++) {
      const state = await deps.matches.load(userId, ref);
      if (!found(state)) return undefined;
      const now = deps.clock.now().toISOString();
      const effects = planMatchChange(state, change, now);
      try {
        await deps.matches.apply(userId, state, effects, now);
        return effects;
      } catch (error) {
        if (!(error instanceof MatchConflictError) || attempt >= ATTEMPTS) throw error;
      }
    }
  }

  async function sessionResult(userId: string, sessionId: string) {
    const got = await deps.plans.getSession(userId, sessionId);
    if (!got) return undefined;
    const plan = await deps.plans.getPlan(userId, got.plan.id);
    return { session: sessionView(got.session), planContentRevision: got.plan.contentRevision, warnings: plan ? warningsFor(plan.plan, plan.sessions) : [] };
  }

  app.put("/v1/sessions/:sessionId/match", auth, async (c) => {
    const sessionId = c.req.param("sessionId");
    const body = await readBody(c.req.raw);
    if (!body || Object.keys(body).some((k) => k !== "activityId" && k !== "status") || typeof body.activityId !== "string" || !UUID.test(body.activityId) || (body.status !== "suggested" && body.status !== "confirmed")) {
      return invalid(c, "Send activityId and a status of suggested or confirmed");
    }
    if (!UUID.test(sessionId)) return notFound(c);
    const userId = c.get("userId");
    const activityId = body.activityId;
    const effects = await run(userId, { sessionId, activityId }, { kind: "put", sessionId, activityId, status: body.status }, (s) =>
      s.sessions.some((x) => x.id === sessionId) && s.activities.some((x) => x.id === activityId),
    );
    const result = effects && (await sessionResult(userId, sessionId));
    return effects?.putMatch && result ? c.json({ match: effects.putMatch, ...result }) : notFound(c);
  });

  app.delete("/v1/sessions/:sessionId/match", auth, async (c) => {
    const sessionId = c.req.param("sessionId");
    if (!UUID.test(sessionId)) return notFound(c);
    const userId = c.get("userId");
    const effects = await run(userId, { sessionId }, { kind: "delete", sessionId }, (s) => s.sessions.some((x) => x.id === sessionId) && s.matches.some((m) => m.sessionId === sessionId));
    const result = effects && (await sessionResult(userId, sessionId));
    return result ? c.json(result) : notFound(c);
  });

  app.patch("/v1/activities/:activityId", auth, async (c) => {
    const activityId = c.req.param("activityId");
    const body = await readBody(c.req.raw);
    const disposition = body?.disposition;
    if (!body || Object.keys(body).length !== 1 || (disposition !== "inbox" && disposition !== "extra" && disposition !== "ignored")) {
      return invalid(c, "Send a disposition of inbox, extra or ignored");
    }
    if (!UUID.test(activityId)) return notFound(c);
    const userId = c.get("userId");
    const effects = await run(userId, { activityId }, { kind: "disposition", activityId, disposition }, (s) => s.activities.some((x) => x.id === activityId));
    const activity = effects && (await deps.activities.get(userId, activityId));
    return activity ? c.json(activityView(activity)) : notFound(c);
  });

  return app;
}
