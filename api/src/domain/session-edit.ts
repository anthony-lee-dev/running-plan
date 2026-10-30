// Applying a validated session edit to a session (backlog 2.5). Pure.
import type { SessionContent, SessionType, SessionUpdateInput } from "./plan-input";

const classOf = (type: SessionType): "custom" | "strength" | "run" => (type === "custom" ? "custom" : type === "strength" ? "strength" : "run");

/**
 * The session's content after an edit. Any edit by the user hands the session to the user, so the engine never
 * changes it again, unless the edit only changes the status (marking it done or skipped).
 */
export function applySessionUpdate(current: SessionContent, update: SessionUpdateInput, onlyStatus: boolean): SessionContent {
  const next: SessionContent = structuredClone(current);
  if (update.date !== undefined) next.date = update.date;
  if (update.type !== undefined) next.type = update.type;
  if (update.title !== undefined) next.title = update.title;
  if (update.key !== undefined) next.key = update.key;
  if (update.status !== undefined) next.status = update.status;
  if (update.notes !== undefined) next.notes = update.notes;
  if (update.custom !== undefined) next.custom = structuredClone(update.custom);
  if (update.steps !== undefined) next.steps = structuredClone(update.steps);
  else if (classOf(next.type) !== classOf(current.type)) next.steps = []; // old steps do not fit the new kind of session
  if (next.type !== "custom") delete next.custom;
  for (const field of update.clear ?? []) delete next[field];
  if (!onlyStatus) next.owner = "user";
  return next;
}
