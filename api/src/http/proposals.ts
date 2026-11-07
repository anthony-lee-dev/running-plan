// Proposals (task 2.14, design §6.6): generate, list, accept, dismiss. Proposals never apply themselves; the rules are
// in domain/proposals.ts (adjustments) and domain/rerun.ts (an interview re-run), the writes in `ProposalStore`.
import { Hono, type Context } from "hono";
import { isLocalDate } from "../domain/activities";
import { parseGenerateRequest } from "../domain/generate-input";
import { DEFAULT_PROFILE, type ReviewFrequency } from "../domain/profile";
import type { StoredProposal, ProposalStatus } from "../domain/proposal-model";
import { proposeAdjustments, type PlanInput } from "../domain/proposals";
import { proposeRerun } from "../domain/rerun";
import { ENGINE_VERSION } from "../domain/engine";
import type { Deps, StoredCheckIn } from "../ports";
import { requireScope, type AuthVariables } from "./auth";
import { planDetail } from "./plans";
import { problem } from "./problem";

const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;
const MAX_BODY_BYTES = 16_384;
const STATUSES: readonly string[] = ["pending", "accepted", "dismissed", "stale"];
const ATTEMPTS = 3;

/** The spec's `Proposal`. The engine's key and the revision stay internal. */
export const proposalView = (p: StoredProposal) => ({
  id: p.id,
  planId: p.planId,
  baseContentRevision: p.baseContentRevision,
  kind: p.kind,
  creator: p.creator,
  reason: p.reason,
  urgent: p.urgent,
  changes: p.changes,
  ...(p.planChanges ? { planChanges: p.planChanges } : {}),
  status: p.status,
  createdAt: p.createdAt,
  updatedAt: p.updatedAt,
  deletedAt: p.deletedAt,
  resolvedAt: p.resolvedAt,
});

const reviewFrequency = async (deps: Deps, userId: string): Promise<ReviewFrequency> => (await deps.profiles.get(userId))?.review.frequency ?? DEFAULT_PROFILE.review.frequency;

/**
 * Runs the adjustment rules over a plan and stores what is new. `generate` follows the review setting (Off makes no
 * proposals); `urgent` is the pain flag's trigger, which only applies to Weekly plus urgent and stores only the urgent
 * proposals. A draft whose key is already pending, accepted or dismissed is not made again. Undefined when the plan is
 * not found. The plan can move while the rules run; the store then writes nothing and this reads again, `attempts` times.
 */
export async function raiseAdjustments(
  deps: Deps,
  userId: string,
  planId: string,
  today: string,
  options: { mode: "generate" | "urgent"; frequency: ReviewFrequency; attempts: number },
): Promise<StoredProposal[] | undefined> {
  if (options.frequency === "off" || (options.mode === "urgent" && options.frequency !== "weekly_plus_urgent")) {
    return (await deps.plans.getPlan(userId, planId)) ? [] : undefined;
  }
  for (let attempt = 1; attempt <= options.attempts; attempt++) {
    const got = await deps.plans.getPlan(userId, planId);
    if (!got) return undefined;
    const [matches, checkIns, used] = await Promise.all([deps.matches.forPlan(userId, planId), deps.proposals.checkInsForPlan(userId, planId), deps.proposals.usedKeys(userId, planId)]);
    const plan: PlanInput = { adaptive: got.plan.adaptive, source: got.plan.source, sessions: got.sessions as PlanInput["sessions"] };
    const drafts = proposeAdjustments({ plan, checkIns, matches, today }).filter((d) => !used.includes(d.key) && (options.mode === "generate" || d.urgent));
    if (drafts.length === 0) return [];
    const now = deps.clock.now().toISOString();
    const stored: StoredProposal[] = drafts.map((d) => ({
      id: deps.ids.uuid(),
      planId,
      baseContentRevision: got.plan.contentRevision,
      kind: d.kind,
      creator: d.creator,
      reason: d.reason,
      urgent: d.urgent,
      changes: d.changes as unknown as StoredProposal["changes"],
      status: "pending",
      createdAt: now,
      updatedAt: now,
      deletedAt: null,
      resolvedAt: null,
      revision: 1,
      key: d.key,
    }));
    if (await deps.proposals.create(userId, stored)) return stored;
  }
  return [];
}

/**
 * A check-in with the pain flag raises an urgent proposal at once, when the review setting is Weekly plus urgent
 * (design §6.6a). Check-ins carry no date, so "today" is the later of the session's date and the server's UTC date: a
 * user ahead of UTC checking in on the day still counts the session's own day. Best effort: the check-in is already
 * saved, so a failure here is logged (no data) and the next generate finds the same pain flag. One attempt only.
 */
export async function raiseForPain(deps: Deps, userId: string, checkIn: StoredCheckIn): Promise<void> {
  if (checkIn.pain !== true) return;
  try {
    const frequency = await reviewFrequency(deps, userId);
    if (frequency !== "weekly_plus_urgent") return;
    const got = await deps.plans.getSession(userId, checkIn.sessionId);
    if (!got) return;
    const utc = deps.clock.now().toISOString().slice(0, 10);
    await raiseAdjustments(deps, userId, got.plan.id, got.session.date > utc ? got.session.date : utc, { mode: "urgent", frequency, attempts: 1 });
  } catch (error) {
    console.error(`pain proposal failed: ${(error as Error).name}: ${(error as Error).message}`);
  }
}

/** Parses an action path segment like `<uuid>:accept`. */
const actionOf = (target: string | undefined): { id: string; action: "accept" | "dismiss" } | undefined => {
  const m = /^([0-9a-f-]{36}):(accept|dismiss)$/i.exec(target ?? "");
  return m && UUID.test(m[1]!) ? { id: m[1]!, action: m[2] as "accept" | "dismiss" } : undefined;
};

export function proposalRoutes(deps: Deps) {
  const app = new Hono<{ Variables: AuthVariables }>();
  const auth = requireScope(deps, "app");
  const notFound = (c: Context) => problem(c, 404, "not_found", "Not found");
  const conflict = (c: Context, status: ProposalStatus) =>
    status === "stale"
      ? problem(c, 409, "stale_proposal", "The plan changed since this was suggested")
      : problem(c, 409, "proposal_not_pending", `This proposal was already ${status}`);
  const invalid = (c: Context, message: string, errors?: unknown) =>
    errors ? problem(c, 400, "validation_failed", "Some fields are invalid", {}, { errors }) : problem(c, 400, "bad_request", message);

  async function readJson(c: Context, allowEmpty: boolean): Promise<{ body: Record<string, unknown> } | { response: Response }> {
    if (Number(c.req.header("content-length") ?? 0) > MAX_BODY_BYTES) return { response: problem(c, 413, "payload_too_large", "That is too large") };
    const text = await c.req.text();
    if (new TextEncoder().encode(text).length > MAX_BODY_BYTES) return { response: problem(c, 413, "payload_too_large", "That is too large") };
    if (allowEmpty && text.trim() === "") return { body: {} };
    try {
      const value: unknown = JSON.parse(text);
      if (value !== null && typeof value === "object" && !Array.isArray(value)) return { body: value as Record<string, unknown> };
    } catch {
      // fall through
    }
    return { response: invalid(c, "Send a JSON object") };
  }

  app.post("/v1/plans/:planId/proposals:generate", auth, async (c) => {
    const planId = c.req.param("planId");
    const userId = c.get("userId");
    const read = await readJson(c, false);
    if ("response" in read) return read.response;
    const body = read.body;
    const errors = Object.keys(body).filter((k) => k !== "today" && k !== "interview").map((k) => ({ path: `/${k}`, message: "Unknown field" }));
    let answers;
    let today = body.today;
    if ("interview" in body) {
      const parsed = parseGenerateRequest({ answers: body.interview, today: body.today });
      if (!parsed.ok) errors.push(...parsed.errors.map((e) => ({ path: e.path.replace(/^\/answers/, "/interview"), message: e.message })));
      else {
        answers = parsed.value.answers;
        today = parsed.value.today;
      }
    } else if (!isLocalDate(today)) errors.push({ path: "/today", message: "Today's local date, YYYY-MM-DD" });
    if (errors.length > 0) return invalid(c, "", errors);
    if (!UUID.test(planId)) return notFound(c);
    const todayDate = today as string;

    if (!answers) {
      const frequency = await reviewFrequency(deps, userId);
      const made = await raiseAdjustments(deps, userId, planId, todayDate, { mode: "generate", frequency, attempts: ATTEMPTS });
      return made ? c.json({ proposals: made.map(proposalView) }) : notFound(c);
    }

    // An interview re-run is always made when asked, whatever the review setting.
    for (let attempt = 1; attempt <= ATTEMPTS; attempt++) {
      const got = await deps.plans.getPlan(userId, planId);
      if (!got) return notFound(c);
      const rerun = proposeRerun({ plan: got.plan, sessions: got.sessions, answers, today: todayDate, newId: () => deps.ids.uuid() });
      if (!rerun.ok) {
        const message = {
          no_future_weeks: "This plan has no weeks left to change",
          no_plan_fits: "No plan fits these answers",
          too_many_changes: "This plan is too large to rebuild in one go",
        }[rerun.reason];
        return problem(c, 400, rerun.reason, message);
      }
      const now = deps.clock.now().toISOString();
      const proposal: StoredProposal = {
        id: deps.ids.uuid(),
        planId,
        baseContentRevision: got.plan.contentRevision,
        kind: "interview_rerun",
        creator: { type: "rules", version: ENGINE_VERSION },
        reason: rerun.reason,
        urgent: false,
        changes: rerun.changes,
        planChanges: rerun.planChanges,
        status: "pending",
        createdAt: now,
        updatedAt: now,
        deletedAt: null,
        resolvedAt: null,
        revision: 1,
      };
      if (await deps.proposals.create(userId, [proposal])) return c.json({ proposals: [proposalView(proposal)] });
    }
    return problem(c, 409, "plan_changed", "The plan changed while we worked; try again");
  });

  app.get("/v1/plans/:planId/proposals", auth, async (c) => {
    const status = c.req.query("status") ?? "pending";
    if (!STATUSES.includes(status)) return invalid(c, "status is pending, accepted, dismissed or stale");
    const planId = c.req.param("planId");
    const userId = c.get("userId");
    const got = UUID.test(planId) ? await deps.plans.getPlan(userId, planId) : undefined;
    if (!got) return notFound(c);
    const proposals = await deps.proposals.list(userId, planId, status as ProposalStatus);
    return c.json({ proposals: proposals.map(proposalView) });
  });

  // `<uuid>:accept` and `<uuid>:dismiss` share one path segment; anything else under /v1/proposals is a 404 before the
  // token is looked at, as for every unknown path.
  const known = async (c: Context, next: () => Promise<void>) => (actionOf(c.req.param("target")) ? next() : notFound(c));

  app.post("/v1/proposals/:target", known, auth, async (c) => {
    const { id, action } = actionOf(c.req.param("target"))!;
    const userId = c.get("userId");
    const now = deps.clock.now().toISOString();

    if (action === "dismiss") {
      const result = await deps.proposals.dismiss(userId, id, now);
      if (result.ok) return c.json(proposalView(result.proposal));
      return result.reason === "not_found" ? notFound(c) : conflict(c, result.status);
    }

    const read = await readJson(c, true);
    if ("response" in read) return read.response;
    const keys = Object.keys(read.body);
    if (keys.some((k) => k !== "includeUserOwned") || ("includeUserOwned" in read.body && typeof read.body.includeUserOwned !== "boolean")) {
      return invalid(c, "Send includeUserOwned as true or false, or nothing");
    }
    const result = await deps.proposals.accept(userId, id, read.body.includeUserOwned === true, now);
    if (!result.ok) return result.reason === "not_found" ? notFound(c) : conflict(c, result.status);
    const got = await deps.plans.getPlan(userId, result.planId);
    return got ? c.json(planDetail(got.plan, got.sessions)) : notFound(c);
  });

  return app;
}
