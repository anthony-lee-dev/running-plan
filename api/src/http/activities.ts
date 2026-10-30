// Imported activities (task 2.11): the native clients upload workout summaries from Apple Health; any signed-in
// client lists them. Matches, dispositions and suggested sessions come with task 2.12.
import { Hono } from "hono";
import { bodyLimit } from "hono/body-limit";
import { isLocalDate, parseActivityBatch, planImport, type StoredActivity } from "../domain/activities";
import type { Deps } from "../ports";
import { requireScope, type AuthVariables } from "./auth";
import { problem } from "./problem";

const MAX_BODY_BYTES = 262_144;
const DAY_MS = 86_400_000;

const shiftDate = (date: string, days: number) => new Date(Date.parse(`${date}T00:00:00Z`) + days * DAY_MS).toISOString().slice(0, 10);

/** The spec's Activity: the imported fields plus id, import time and disposition. Revision stays internal. */
const activityView = (a: StoredActivity) => {
  const { revision: _revision, updatedAt: _updatedAt, ...view } = a;
  return view;
};

type After = { localDate: string; startedAt: string; id: string };
const encodeCursor = (a: After) => btoa(JSON.stringify([a.localDate, a.startedAt, a.id])).replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/, "");
function decodeCursor(text: string): After | undefined {
  try {
    const value: unknown = JSON.parse(atob(text.replace(/-/g, "+").replace(/_/g, "/").padEnd(Math.ceil(text.length / 4) * 4, "=")));
    if (Array.isArray(value) && value.length === 3 && isLocalDate(value[0]) && value.every((v) => typeof v === "string" && v.length <= 128)) {
      return { localDate: value[0], startedAt: value[1] as string, id: value[2] as string };
    }
  } catch {
    // fall through
  }
  return undefined;
}

export function activityRoutes(deps: Deps) {
  const app = new Hono<{ Variables: AuthVariables }>();
  const batchPath = "/v1/activities:batch";

  app.post(
    batchPath,
    requireScope(deps, "activities:write"),
    bodyLimit({ maxSize: MAX_BODY_BYTES, onError: (c) => problem(c, 413, "payload_too_large", "That is too large") }),
    async (c) => {
      let body: unknown;
      try {
        body = JSON.parse(await c.req.text());
      } catch {
        return problem(c, 400, "bad_request", "Send JSON");
      }
      const parsed = parseActivityBatch(body);
      if (!parsed.ok) return problem(c, 400, "validation_failed", "Some fields are invalid", {}, { errors: parsed.errors });

      const userId = c.get("userId");
      const dates = parsed.value.map((a) => a.localDate).sort();
      // A day either side, so a record whose local date moved with a time zone still dedupes.
      const keys = parsed.value.map((a) => ({ source: a.source, externalId: a.externalId }));
      const existing = await deps.activities.candidates(userId, shiftDate(dates[0]!, -1), shiftDate(dates.at(-1)!, 1), keys);
      const plan = planImport(existing, parsed.value, deps.clock.now().toISOString(), () => deps.ids.uuid());
      await deps.activities.applyImport(userId, plan.creates, plan.updates);
      return c.json({ results: plan.results });
    },
  );

  app.get("/v1/activities", requireScope(deps, "app"), async (c) => {
    const bad = (message: string) => problem(c, 400, "bad_request", message);
    const from = c.req.query("from");
    const to = c.req.query("to");
    const inbox = c.req.query("inbox");
    const limitText = c.req.query("limit");
    const cursorText = c.req.query("cursor");
    if (from !== undefined && !isLocalDate(from)) return bad("from is a date, YYYY-MM-DD");
    if (to !== undefined && !isLocalDate(to)) return bad("to is a date, YYYY-MM-DD");
    if (inbox !== undefined && inbox !== "true" && inbox !== "false") return bad("inbox is true or false");
    const limit = limitText === undefined ? 50 : /^\d{1,3}$/.test(limitText) ? Number(limitText) : 0;
    if (limit < 1 || limit > 200) return bad("limit is 1 to 200");
    const after = cursorText === undefined ? undefined : decodeCursor(cursorText);
    if (cursorText !== undefined && !after) return bad("That cursor is not valid");

    const rows = await deps.activities.list(c.get("userId"), {
      ...(from !== undefined ? { from } : {}),
      ...(to !== undefined ? { to } : {}),
      inbox: inbox === "true",
      limit: limit + 1,
      ...(after ? { after } : {}),
    });
    const page = rows.slice(0, limit);
    const last = page.at(-1);
    return c.json({
      activities: page.map(activityView),
      ...(rows.length > limit && last ? { nextCursor: encodeCursor(last) } : {}),
    });
  });

  return app;
}
