// The weekly review (task 2.18, design §6.6a): the summary from domain/insights.ts, the plan's pending proposals and the
// inbox count. A read only: it never makes proposals (that is `proposals:generate`).
import { Hono } from "hono";
import { isLocalDate } from "../domain/activities";
import { computeWeeklyReview } from "../domain/insights";
import { DEFAULT_PROFILE } from "../domain/profile";
import type { Deps } from "../ports";
import { requireScope, type AuthVariables } from "./auth";
import { problem } from "./problem";
import { proposalView } from "./proposals";

const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;

export function reviewRoutes(deps: Deps) {
  const app = new Hono<{ Variables: AuthVariables }>();
  const notFound = (c: Parameters<typeof problem>[0]) => problem(c, 404, "not_found", "Not found");

  app.get("/v1/plans/:planId/reviews/:weekIndex", requireScope(deps, "app"), async (c) => {
    const today = c.req.query("today");
    if (!isLocalDate(today)) return problem(c, 400, "bad_request", "today is the local date, YYYY-MM-DD");
    const planId = c.req.param("planId");
    const week = c.req.param("weekIndex");
    const userId = c.get("userId");
    const got = UUID.test(planId) && /^\d{1,2}$/.test(week) ? await deps.plans.getPlan(userId, planId) : undefined;
    const weekIndex = Number(week);
    if (!got || weekIndex >= got.plan.weekCount) return notFound(c);

    const [matches, checkIns, profile, pending, inboxActivities] = await Promise.all([
      deps.matches.forPlan(userId, planId),
      deps.proposals.checkInsForPlan(userId, planId),
      deps.profiles.get(userId),
      deps.proposals.list(userId, planId, "pending"),
      deps.activities.countInbox(userId),
    ]);
    const review = profile?.review ?? DEFAULT_PROFILE.review;
    const summary = computeWeeklyReview({
      plan: { startDate: got.plan.startDate, weekCount: got.plan.weekCount, goalDate: got.plan.goal.date },
      sessions: got.sessions,
      matches,
      activities: matches.flatMap((m) => (m.durationSec === undefined ? [] : [{ id: m.activityId, durationSec: m.durationSec, distanceM: m.distanceM }])),
      checkIns,
      weekIndex,
      today,
      review,
    });
    // Reviews Off make no proposals, and a blank plan has none unless it is adaptive; show none either way.
    const proposals = review.frequency === "off" || (got.plan.source === "blank" && !got.plan.adaptive) ? [] : pending.map(proposalView);
    return c.json({ planId, ...summary, proposals, looseEnds: { inboxActivities } });
  });

  return app;
}
