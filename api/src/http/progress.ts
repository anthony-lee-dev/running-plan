// Whole-plan progress (task 2.15): the store reads here, the arithmetic in domain/insights.ts.
import { Hono } from "hono";
import { isLocalDate } from "../domain/activities";
import { computeProgress } from "../domain/insights";
import type { Deps } from "../ports";
import { requireScope, type AuthVariables } from "./auth";
import { problem } from "./problem";

const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;

export function progressRoutes(deps: Deps) {
  const app = new Hono<{ Variables: AuthVariables }>();

  app.get("/v1/plans/:planId/progress", requireScope(deps, "app"), async (c) => {
    const today = c.req.query("today");
    if (!isLocalDate(today)) return problem(c, 400, "bad_request", "today is the local date, YYYY-MM-DD");
    const planId = c.req.param("planId");
    const userId = c.get("userId");
    const got = UUID.test(planId) ? await deps.plans.getPlan(userId, planId) : undefined;
    if (!got) return problem(c, 404, "not_found", "Not found");

    const matches = await deps.matches.forPlan(userId, planId);
    const progress = computeProgress({
      plan: { startDate: got.plan.startDate, weekCount: got.plan.weekCount, goalDate: got.plan.goal.date },
      sessions: got.sessions,
      matches,
      activities: matches.flatMap((m) => (m.durationSec === undefined ? [] : [{ id: m.activityId, durationSec: m.durationSec, distanceM: m.distanceM }])),
      asOf: today,
    });
    return c.json({ planId, ...progress });
  });

  return app;
}
