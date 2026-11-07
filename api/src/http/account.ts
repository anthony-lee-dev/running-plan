// Account data export (task 2.16, design 10). Delete is in auth.ts.
import { Hono } from "hono";
import type { Deps } from "../ports";
import { activityView } from "./activities";
import { requireScope, type AuthVariables } from "./auth";
import { planDetail } from "./plans";
import { problem } from "./problem";
import { currentProfile } from "./profile";

const HOUR = 3600;
/** The most expensive read the API has (every row the user owns), so it is limited per account. */
export const EXPORT_PER_USER = 5;

export function accountRoutes(deps: Deps) {
  const app = new Hono<{ Variables: AuthVariables }>();

  app.post("/v1/account/export", requireScope(deps, "app"), async (c) => {
    const userId = c.get("userId");
    const now = deps.clock.now();
    const limited = await deps.rateLimiter.hit(`export:user:${userId}`, EXPORT_PER_USER, HOUR, now);
    if (!limited.allowed) return problem(c, 429, "rate_limited", "Too many exports, try again later", { "retry-after": String(limited.retryAfterSec) });

    const data = await deps.accountExport.read(userId);
    if (!data) return problem(c, 401, "unauthorized", "Sign in again", { "www-authenticate": 'Bearer realm="running-plan"' });

    const sessionsByPlan = new Map<string, typeof data.sessions>();
    for (const s of data.sessions) sessionsByPlan.set(s.planId, [...(sessionsByPlan.get(s.planId) ?? []), s]);
    const matchByActivity = new Map(data.matches.map((m) => [m.activityId, m]));

    // Personal data: never cached by a browser or a proxy.
    c.header("cache-control", "no-store");
    return c.json({
      exportedAt: now.toISOString(),
      email: data.email,
      profile: await currentProfile(deps, userId),
      plans: data.plans.map((p) => planDetail(p, sessionsByPlan.get(p.id) ?? [])),
      activities: data.activities.map((a) => activityView(a, matchByActivity.get(a.id))),
      checkins: data.checkins,
      proposals: data.proposals,
    });
  });

  return app;
}
