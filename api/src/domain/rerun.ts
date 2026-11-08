// Re-running the interview mid-plan (design §6.6, decision 19): the engine plans again from the new answers, but only
// the weeks after the current one change. Past weeks, the current week, sessions the user owns and sessions already
// done or skipped stay exactly as they are. The result is a proposal, never an edit. Pure: ids come from the caller.
import { generatePlan, NoPlanFitsError } from "./engine";
import type { InterviewAnswers } from "./interview";
import type { Goal, SessionContent, Week } from "./plan-input";
import type { ProposalChangeRecord, ProposalPlanChanges } from "./proposal-model";
import type { StoredPlan, StoredSession } from "../ports";

export const MAX_PLAN_WEEKS = 52;
/** The spec's `Proposal.changes` limit. */
export const MAX_PROPOSAL_CHANGES = 400;

const DAY_MS = 86_400_000;
const dayOf = (date: string): number => Date.parse(`${date}T00:00:00Z`) / DAY_MS;
const dateOf = (day: number): string => new Date(day * DAY_MS).toISOString().slice(0, 10);

export interface RerunInput {
  plan: StoredPlan;
  /** The plan's live sessions. */
  sessions: StoredSession[];
  answers: InterviewAnswers;
  /** The user's local date. */
  today: string;
  /** Makes the id a created session will get. */
  newId: () => string;
  generate?: typeof generatePlan;
}

export type RerunResult =
  | { ok: true; reason: string; changes: ProposalChangeRecord[]; planChanges: ProposalPlanChanges }
  | { ok: false; reason: "no_future_weeks" | "no_plan_fits" | "too_many_changes" };

const contentOf = (s: StoredSession): SessionContent => {
  const { id: _id, planId: _plan, revision: _rev, updatedAt: _at, deletedAt: _del, ...content } = structuredClone(s);
  return content;
};
const byDate = (a: { date: string; id: string }, b: { date: string; id: string }) => (a.date === b.date ? (a.id < b.id ? -1 : 1) : a.date < b.date ? -1 : 1);

export function proposeRerun(input: RerunInput): RerunResult {
  const { plan, answers } = input;
  const start = dayOf(plan.startDate);
  const today = dayOf(input.today);

  // Weeks run from the plan's start date in blocks of seven days. The current week is kept: the first week that may
  // change is the first one starting after today (or week 0 when the plan has not begun).
  const firstFutureWeek = today < start ? 0 : Math.floor((today - start) / 7) + 1;
  if (firstFutureWeek >= plan.weekCount) return { ok: false, reason: "no_future_weeks" };
  const boundaryDay = start + firstFutureWeek * 7;
  const boundary = dateOf(boundaryDay);

  // The engine plans from the boundary, so its first week never starts before it.
  let draft;
  try {
    draft = (input.generate ?? generatePlan)({ answers, today: boundary });
  } catch (error) {
    if (error instanceof NoPlanFitsError) return { ok: false, reason: "no_plan_fits" };
    throw error;
  }

  const live = input.sessions.filter((s) => s.deletedAt === null);
  const replaceable = (s: StoredSession) => s.date >= boundary && s.owner === "system" && s.status === "planned";
  const kept = live.filter((s) => s.date >= boundary && !replaceable(s));

  // The plan keeps its start date, so its length is what reaches the new last day (and every session that stays).
  const draftEnd = dayOf(draft.startDate) + draft.weekCount * 7 - 1;
  const lastKept = kept.reduce((last, s) => Math.max(last, dayOf(s.date)), start);
  const weekCount = Math.min(MAX_PLAN_WEEKS, Math.max(firstFutureWeek, Math.ceil((draftEnd - start + 1) / 7), Math.ceil((lastKept - start + 1) / 7)));
  const planEnd = dateOf(start + weekCount * 7 - 1);

  const removed = live.filter(replaceable).sort(byDate);
  const changes: ProposalChangeRecord[] = removed.map((s) => ({ op: "delete", sessionId: s.id, before: contentOf(s), userOwned: false }));
  for (const d of draft.sessions) {
    if (d.date < boundary || d.date > planEnd) continue;
    const { notes, ...rest } = d;
    changes.push({ op: "create", sessionId: input.newId(), after: { ...structuredClone(rest), ...(notes !== undefined ? { notes } : {}) } as SessionContent, userOwned: false });
  }
  if (changes.length > MAX_PROPOSAL_CHANGES) return { ok: false, reason: "too_many_changes" };
  // By date, a drop before the session that replaces it, so a short preview shows both sides (the spec sets no order).
  const dateOfChange = (c: ProposalChangeRecord) => (c.op === "delete" ? c.before.date : c.after.date);
  changes.sort((a, b) => (dateOfChange(a) < dateOfChange(b) ? -1 : dateOfChange(a) > dateOfChange(b) ? 1 : a.op === b.op ? 0 : a.op === "delete" ? -1 : 1));

  // Each week from the boundary on takes the phase of the draft week that starts in it; notes the user wrote stay.
  const phases = new Map<number, Week["phase"]>();
  for (const w of draft.weeks) phases.set(Math.floor((dayOf(draft.startDate) + w.index * 7 - start) / 7), w.phase);
  const notes = new Map(plan.weeks.map((w) => [w.index, w.notes]));
  const weeks: Week[] = [];
  for (let index = firstFutureWeek; index < weekCount; index++) {
    const phase = phases.get(index);
    const note = notes.get(index);
    weeks.push({ index, ...(phase ? { phase } : {}), ...(note !== undefined ? { notes: note } : {}) });
  }

  const goal: Goal = { type: draft.goal.type, ...(draft.goal.date ? { date: draft.goal.date } : {}), ...(draft.goal.targetTimeSec !== undefined ? { targetTimeSec: draft.goal.targetTimeSec } : {}) };
  if (plan.goal.label !== undefined && plan.goal.type === goal.type) goal.label = plan.goal.label;

  const firstWeekNumber = firstFutureWeek + 1; // weeks count from 1, as the goal line's total does
  const rebuilt = firstWeekNumber >= weekCount ? `week ${weekCount}` : `weeks ${firstWeekNumber} to ${weekCount}`;
  return {
    ok: true,
    reason: `Your new answers rebuild ${rebuilt}. Past weeks and sessions you made yourself stay as they are.`,
    changes,
    // The interview is kept as answered (the plan stores it as plain JSON).
    planChanges: { goal, weekCount, weeks, engine: { ...draft.engine, interview: draft.engine.interview as unknown as Record<string, unknown> } },
  };
}
