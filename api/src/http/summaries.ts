// Written summaries of a run (issue #132). `GET .../summary` returns the stored AI paragraph or the template, and never
// calls a model or writes. The facts are worked out here from the user's own data (no free text); `nextStep` is written
// by the server on every read from the plan, never by a model.
import { Hono } from "hono";
import { isLocalDate } from "../domain/activities";
import { canonicalHash } from "../domain/plan-hash";
import { buildRunFacts, RECENT_DAYS, type RunFacts } from "../domain/run-facts";
import { nextStepLine, PAIN_GUIDANCE, PROMPT_VERSION, templateParagraph } from "../domain/run-summary-text";
import type { Deps, StoredSummary, SummaryReason } from "../ports";
import { requireScope, type AuthVariables } from "./auth";
import { problem } from "./problem";

const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;
const DAY_MS = 86_400_000;
const shiftDate = (date: string, days: number) => new Date(Date.parse(`${date}T00:00:00Z`) + days * DAY_MS).toISOString().slice(0, 10);

export interface SummaryContext {
  facts: RunFacts;
  factsHash: string;
  /** The line under the paragraph: the fixed pain guidance, the next planned session, or nothing. */
  nextStep: string | undefined;
}

/**
 * Everything a summary is built from, read in about six queries: the run, the user's recent runs, its match, the matched
 * session with its after-run check-ins, and the plan's sessions. Undefined when the user has no such running activity
 * (another user's, missing, not a run, or ignored).
 */
export async function loadSummaryContext(deps: Deps, userId: string, activityId: string, today: string): Promise<SummaryContext | undefined> {
  const run = UUID.test(activityId) ? await deps.activities.get(userId, activityId) : undefined;
  if (!run || run.workoutType !== "running" || run.disposition === "ignored") return undefined;

  const [others, matches] = await Promise.all([
    deps.activities.list(userId, { from: shiftDate(run.localDate, -RECENT_DAYS), to: run.localDate, limit: 200 }),
    deps.matches.forActivities(userId, [run.id]),
  ]);
  const match = matches.find((m) => m.status === "confirmed");
  const matched = match ? await deps.plans.getSession(userId, match.sessionId) : undefined;
  const checkIns = matched ? await deps.checkIns.forSession(userId, matched.session.id) : [];
  const after = checkIns.filter((c) => c.when === "after");
  const latest = after.at(-1);
  // Any after-run pain flag counts, not only the latest one: the guidance is safety information.
  const pain = after.some((c) => c.pain === true);

  const facts = buildRunFacts({
    run,
    others: others.filter((o) => o.workoutType === "running"),
    ...(matched ? { session: { type: matched.session.type, steps: matched.session.steps } } : {}),
    ...(latest ? { checkIn: { feel: latest.feel, ...(latest.effortFelt !== undefined ? { effortFelt: latest.effortFelt } : {}), pain } } : {}),
  });
  const factsHash = await canonicalHash(facts);

  let nextStep: string | undefined;
  if (pain) nextStep = PAIN_GUIDANCE;
  else {
    const planId = matched?.plan.id ?? (await deps.plans.listPlans(userId, 1))[0]?.id;
    const plan = planId ? await deps.plans.getPlan(userId, planId) : undefined;
    nextStep = plan ? nextStepLine(plan.sessions, today) : undefined;
  }
  return { facts, factsHash, nextStep };
}

export interface SummaryView {
  text: string;
  nextStep?: string;
  source: "ai" | "template";
  reason?: "not_generated" | "disabled" | "over_limit" | "check_failed" | "ai_unavailable";
  canGenerate: boolean;
  pain: boolean;
  generatedAt?: string;
}

export function summaryView(ctx: SummaryContext, parts: { text: string; source: "ai" | "template"; reason?: SummaryView["reason"]; canGenerate: boolean; generatedAt?: string }): SummaryView {
  return {
    text: parts.text,
    ...(ctx.nextStep ? { nextStep: ctx.nextStep } : {}),
    source: parts.source,
    ...(parts.reason ? { reason: parts.reason } : {}),
    canGenerate: parts.canGenerate,
    pain: ctx.facts.pain,
    ...(parts.generatedAt ? { generatedAt: parts.generatedAt } : {}),
  };
}

/** The stored summary when it was written from these very facts and this prompt version. */
export const currentStored = (stored: StoredSummary | undefined, ctx: SummaryContext): StoredSummary | undefined =>
  stored && stored.factsHash === ctx.factsHash && stored.promptVersion === PROMPT_VERSION ? stored : undefined;

export function summaryRoutes(deps: Deps) {
  const app = new Hono<{ Variables: AuthVariables }>();

  app.get("/v1/activities/:activityId/summary", requireScope(deps, "app"), async (c) => {
    const today = c.req.query("today");
    if (!isLocalDate(today)) return problem(c, 400, "bad_request", "today is the local date, YYYY-MM-DD");
    const userId = c.get("userId");
    const ctx = await loadSummaryContext(deps, userId, c.req.param("activityId"), today);
    if (!ctx) return problem(c, 404, "not_found", "Not found");

    const template = templateParagraph(ctx.facts);
    const profile = await deps.profiles.get(userId);
    if (profile && !profile.aiSummaries) return c.json(summaryView(ctx, { text: template, source: "template", reason: "disabled", canGenerate: false }));

    const stored = currentStored(await deps.summaries.get(userId, c.req.param("activityId")), ctx);
    if (stored?.source === "ai") return c.json(summaryView(ctx, { text: stored.text, source: "ai", canGenerate: false, generatedAt: stored.createdAt }));
    if (stored?.reason) return c.json(summaryView(ctx, { text: template, source: "template", reason: stored.reason satisfies SummaryReason, canGenerate: false }));
    return c.json(summaryView(ctx, { text: template, source: "template", reason: "not_generated", canGenerate: true }));
  });

  return app;
}
