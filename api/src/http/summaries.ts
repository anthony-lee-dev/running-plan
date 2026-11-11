// Written summaries of a run (issue #132). `GET .../summary` returns the stored AI paragraph or the template, and never
// calls a model or writes. The facts are worked out here from the user's own data (no free text); `nextStep` is written
// by the server on every read from the plan, never by a model.
import { Hono } from "hono";
import { isLocalDate } from "../domain/activities";
import { canonicalHash } from "../domain/plan-hash";
import { buildPrompt, parseNarration } from "../domain/run-summary-prompt";
import { checkParagraph } from "../domain/summary-check";
import { buildRunFacts, RECENT_DAYS, type RunFacts } from "../domain/run-facts";
import { nextStepLine, PAIN_GUIDANCE, PROMPT_VERSION, templateParagraph } from "../domain/run-summary-text";
import { NarratorError, type Deps, type StoredSummary, type SummaryReason } from "../ports";
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
 * Everything a summary is built from, read in about a dozen D1 round trips: the run, the user's recent runs, its match, the matched
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
  // The run's own data and whether and which way it compares: importing one more similar run does not write the paragraph again.
  const { vsRecent, ...own } = facts;
  const factsHash = await canonicalHash({ ...own, vs: vsRecent ? { pace: vsRecent.pace.dir, hr: vsRecent.hr?.dir ?? null } : null });

  let nextStep: string | undefined;
  if (pain) nextStep = PAIN_GUIDANCE;
  else {
    // The matched session's plan, else the plan that covers today (a future or finished plan names no "next" session).
    const covering = async () => (await deps.plans.listPlans(userId, 10)).find((p) => p.startDate <= today && today <= shiftDate(p.startDate, p.weekCount * 7 - 1));
    const planId = matched?.plan.id ?? (await covering())?.id;
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

const HOUR = 3600;
const DAY = 86_400;
/** Per account: 30 generations an hour and 60 a day. A cached summary or a refusal before the model costs none of it. */
const PER_USER_HOUR = 30;
const PER_USER_DAY = 60;
/** The model is asked once, and once more when its text fails the checks. */
const ATTEMPTS = 2;
/** How long a quota error pauses all model calls. */
const QUOTA_MARKER = "summary:quota";
const QUOTA_PAUSE = 900;

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
    if ((profile && !profile.aiSummaries) || !deps.summaryConfig.aiEnabled) return c.json(summaryView(ctx, { text: template, source: "template", reason: "disabled", canGenerate: false }));

    const stored = currentStored(await deps.summaries.get(userId, c.req.param("activityId")), ctx);
    if (stored?.source === "ai") return c.json(summaryView(ctx, { text: stored.text, source: "ai", canGenerate: false, generatedAt: stored.createdAt }));
    if (stored?.reason) return c.json(summaryView(ctx, { text: template, source: "template", reason: stored.reason satisfies SummaryReason, canGenerate: false }));
    return c.json(summaryView(ctx, { text: template, source: "template", reason: "not_generated", canGenerate: true }));
  });

  app.post("/v1/activities/:activityId/summary:generate", requireScope(deps, "app"), async (c) => {
    const today = c.req.query("today");
    if (!isLocalDate(today)) return problem(c, 400, "bad_request", "today is the local date, YYYY-MM-DD");
    const userId = c.get("userId");
    const activityId = c.req.param("activityId");
    const ctx = await loadSummaryContext(deps, userId, activityId, today);
    if (!ctx) return problem(c, 404, "not_found", "Not found");

    const template = templateParagraph(ctx.facts);
    const asTemplate = (reason: NonNullable<SummaryView["reason"]>) => c.json(summaryView(ctx, { text: template, source: "template", reason, canGenerate: false }));

    const profile = await deps.profiles.get(userId);
    if ((profile && !profile.aiSummaries) || !deps.summaryConfig.aiEnabled) return asTemplate("disabled");

    const stored = currentStored(await deps.summaries.get(userId, activityId), ctx);
    if (stored?.source === "ai") return c.json(summaryView(ctx, { text: stored.text, source: "ai", canGenerate: false, generatedAt: stored.createdAt }));
    if (stored?.reason) return asTemplate(stored.reason);
    if (!deps.narrator) return asTemplate("ai_unavailable");

    // After the model reported its allowance used up, nothing calls it again for a while: on Workers Free every further call
    // would only fail until 00:00 UTC. The marker is a counter in the rate limiter, set by a quota error below.
    const now = deps.clock.now();
    if ((await deps.rateLimiter.peek(QUOTA_MARKER, QUOTA_PAUSE, now)) > 0) return asTemplate("over_limit");

    // Per-account limits come first and answer 429; they count only a request that would reach the model.
    for (const [key, limit, window] of [
      [`summary:user:${userId}:hour`, PER_USER_HOUR, HOUR],
      [`summary:user:${userId}:day`, PER_USER_DAY, DAY],
    ] as const) {
      const hit = await deps.rateLimiter.hit(key, limit, window, now);
      if (!hit.allowed) return problem(c, 429, "rate_limited", "Too many summaries. Try again later.", { "Retry-After": String(hit.retryAfterSec) });
    }

    const prompt = buildPrompt(ctx.facts);
    let failure: "check_failed" | undefined;
    for (let attempt = 0; attempt < ATTEMPTS; attempt++) {
      // One count per model call, in a fixed one-day window (UTC midnight, like the Workers AI allowance), across all accounts.
      const global = await deps.rateLimiter.hit("summary:global:day", deps.summaryConfig.dailyCallCap, DAY, now);
      if (!global.allowed) return asTemplate("over_limit");
      let raw: unknown;
      try {
        raw = await deps.narrator.narrate(prompt);
      } catch (error) {
        const kind = error instanceof NarratorError ? error.kind : "unavailable";
        // Reason codes only: neither the facts nor the model's text are ever logged.
        console.warn(`run summary: narrator ${kind}`);
        if (kind === "quota") await deps.rateLimiter.hit(QUOTA_MARKER, 1, QUOTA_PAUSE, now);
        return asTemplate(kind === "quota" ? "over_limit" : "ai_unavailable");
      }
      const paragraph = parseNarration(raw);
      const checked = paragraph === undefined ? ({ ok: false, reason: "malformed" } as const) : checkParagraph(paragraph, ctx.facts);
      if (paragraph !== undefined && checked.ok) {
        const text = paragraph.trim();
        const createdAt = now.toISOString();
        await deps.summaries.put(userId, { activityId, factsHash: ctx.factsHash, promptVersion: PROMPT_VERSION, model: deps.narrator.model, source: "ai", text, createdAt });
        return c.json(summaryView(ctx, { text, source: "ai", canGenerate: false, generatedAt: createdAt }));
      }
      console.warn(`run summary: check failed (${checked.ok ? "unknown" : checked.reason})`);
      failure = "check_failed";
    }
    // Remember the failure for this data, so reopening the run does not spend two more model calls on it.
    await deps.summaries.put(userId, { activityId, factsHash: ctx.factsHash, promptVersion: PROMPT_VERSION, model: deps.narrator.model, source: "template", reason: failure ?? "check_failed", text: template, createdAt: now.toISOString() });
    return asTemplate("check_failed");
  });

  return app;
}
