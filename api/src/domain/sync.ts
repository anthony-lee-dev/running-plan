// The offline edit queue (design §8.2): reading a sync request, the cursor, and the per-request query budget. Pure.
import type { SyncCursor, SyncPosition } from "../ports";
import { parseCheckInCreate, type CheckInFields } from "./checkins";
import { parsePlanCreate, parsePlanUpdate, type PlanInput } from "./plan-input";
import type { FieldError } from "./profile";

/** Workers Free allows 50 D1 queries per request (a batch counts as one). */
export const QUERY_LIMIT = 50;
/**
 * Kept back for what every call does besides the operations: the token check (1), remembering the applied operations
 * (1), marking stale proposals (1), the pull (5) and a spare.
 */
export const FIXED_QUERIES = 9;
/** Idempotency keys looked up per query; D1 allows 100 bound values in one. */
export const KEY_LOOKUP_CHUNK = 50;
/** Rows per table in one pull. */
export const PULL_LIMITS = { plans: 25, sessions: 100, checkins: 100, proposals: 25 };

export type SyncKind = "plan.create" | "plan.update" | "plan.delete" | "session.create" | "session.update" | "session.delete" | "checkin.create";

/**
 * Worst-case D1 queries one operation may run, counted from the stores (the Workers test measures real calls against
 * these): a plan read is 3 queries, a plan write a batch plus a re-read, a conflict re-reads the server version.
 */
export const OP_COST: Record<SyncKind, number> = {
  "plan.create": 8, // exists check, batch, then up to 5 chunks of the session-id clash check, plus the race re-read
  "plan.update": 8, // read 3, write batch 1, failure check 1, re-read of the server version 3
  "plan.delete": 5,
  "session.create": 8,
  "session.update": 6,
  "session.delete": 4,
  "checkin.create": 2,
};
/**
 * A check-in with the pain flag also raises an urgent proposal (task 2.14): review setting 1, session 2, plan 3,
 * matches, check-ins and used keys 3, the write 1.
 */
export const PAIN_CHECKIN_COST = OP_COST["checkin.create"] + 10;
/** The worst-case queries of one operation. */
export const opCost = (op: SyncOp): number => (op.kind === "checkin.create" && op.data.pain === true ? PAIN_CHECKIN_COST : OP_COST[op.kind]);

interface OpBase {
  idempotencyKey: string;
  id: string;
}
export type SyncOp = OpBase &
  (
    | { kind: "plan.create"; data: PlanInput }
    | { kind: "plan.update"; baseRevision: number; data: Record<string, unknown> }
    | { kind: "plan.delete"; baseRevision: number }
    | { kind: "session.create"; planId: string; data: Record<string, unknown> }
    | { kind: "session.update"; baseRevision: number; data: Record<string, unknown> }
    | { kind: "session.delete"; baseRevision: number }
    | { kind: "checkin.create"; sessionId: string; data: CheckInFields }
  );

export interface SyncRequestInput {
  cursor: SyncCursor;
  operations: SyncOp[];
}

const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;
const MAX_OPERATIONS = 200;
const isObject = (v: unknown): v is Record<string, unknown> => v !== null && typeof v === "object" && !Array.isArray(v);

const FIELDS: Record<SyncKind, readonly string[]> = {
  "plan.create": ["data"],
  "plan.update": ["baseRevision", "data"],
  "plan.delete": ["baseRevision"],
  "session.create": ["planId", "data"],
  "session.update": ["baseRevision", "data"],
  "session.delete": ["baseRevision"],
  "checkin.create": ["sessionId", "data"],
};
const SESSION_UPDATE_KEYS = ["date", "type", "title", "key", "status", "steps", "custom", "notes", "clear"];
const SESSION_CREATE_KEYS = ["date", "type", "title", "key", "status", "owner", "steps", "custom", "notes"];

const b64 = (text: string) => btoa(text).replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/, "");
const unb64 = (text: string) => atob(text.replace(/-/g, "+").replace(/_/g, "/").padEnd(Math.ceil(text.length / 4) * 4, "="));

const wire = (p: SyncPosition | undefined) => (p ? { t: p.updatedAt, i: p.id } : undefined);
export const encodeCursor = (cursor: SyncCursor): string =>
  b64(JSON.stringify({ p: wire(cursor.plans), s: wire(cursor.sessions), c: wire(cursor.checkins), q: wire(cursor.proposals) }));

const position = (v: unknown): SyncPosition | undefined | null => {
  if (v === undefined) return undefined;
  if (!isObject(v) || typeof v.t !== "string" || typeof v.i !== "string" || v.t.length > 40 || v.i.length > 40) return null;
  return { updatedAt: v.t, id: v.i };
};

/** Undefined for a cursor this server did not make. */
export function decodeCursor(text: string): SyncCursor | undefined {
  try {
    const v: unknown = JSON.parse(unb64(text));
    if (!isObject(v)) return undefined;
    // A cursor made before proposals joined the pull has no `q`: proposals are then read from the start.
    const [plans, sessions, checkins, proposals] = [position(v.p), position(v.s), position(v.c), position(v.q)];
    if (plans === null || sessions === null || checkins === null || proposals === null) return undefined;
    return { ...(plans ? { plans } : {}), ...(sessions ? { sessions } : {}), ...(checkins ? { checkins } : {}), ...(proposals ? { proposals } : {}) };
  } catch {
    return undefined;
  }
}

/**
 * Checks the whole request against the spec's shape. A request the spec forbids is rejected as a whole (a 400);
 * what only the stored data can decide (a date outside the plan, a missing entity) is left to each operation.
 */
export function parseSyncRequest(body: unknown): { ok: true; value: SyncRequestInput } | { ok: false; errors: FieldError[] } {
  const errors: FieldError[] = [];
  if (!isObject(body)) return { ok: false, errors: [{ path: "/", message: "Send the sync request" }] };
  for (const key of Object.keys(body)) if (key !== "cursor" && key !== "operations") errors.push({ path: `/${key}`, message: "Unknown field" });
  let cursor: SyncCursor = {};
  if ("cursor" in body) {
    const decoded = typeof body.cursor === "string" && body.cursor.length <= 512 ? decodeCursor(body.cursor) : undefined;
    if (decoded) cursor = decoded;
    else errors.push({ path: "/cursor", message: "That cursor is not valid" });
  }
  const raw = body.operations;
  if (!Array.isArray(raw) || raw.length > MAX_OPERATIONS) {
    errors.push({ path: "/operations", message: `Send a list of at most ${MAX_OPERATIONS} operations` });
    return { ok: false, errors };
  }
  const operations: SyncOp[] = [];
  raw.forEach((item, i) => {
    const at = `/operations/${i}`;
    if (!isObject(item) || typeof item.kind !== "string" || !(item.kind in FIELDS)) {
      errors.push({ path: `${at}/kind`, message: "Use plan.create, plan.update, plan.delete, session.create, session.update, session.delete or checkin.create" });
      return;
    }
    const kind = item.kind as SyncKind;
    for (const key of Object.keys(item)) if (!["idempotencyKey", "kind", "id", ...FIELDS[kind]].includes(key)) errors.push({ path: `${at}/${key}`, message: "Unknown field" });
    for (const key of ["idempotencyKey", "id", ...FIELDS[kind].filter((f) => f === "planId" || f === "sessionId")]) {
      if (!(typeof item[key] === "string" && UUID.test(item[key]))) errors.push({ path: `${at}/${key}`, message: "A UUID" });
    }
    if (FIELDS[kind].includes("baseRevision") && !(Number.isInteger(item.baseRevision) && (item.baseRevision as number) >= 1)) {
      errors.push({ path: `${at}/baseRevision`, message: "The revision you edited, 1 or more" });
    }
    if (FIELDS[kind].includes("data") && !isObject(item.data)) errors.push({ path: `${at}/data`, message: "Send the data" });
    if (errors.length > 0) return;

    const common = { idempotencyKey: item.idempotencyKey as string, id: item.id as string };
    const data = item.data as Record<string, unknown> | undefined;
    const sub = (e: FieldError[]) => e.map((x) => ({ path: `${at}/data${x.path === "/" ? "" : x.path}`, message: x.message }));
    switch (kind) {
      case "plan.create": {
        const parsed = parsePlanCreate(data);
        if (!parsed.ok) errors.push(...sub(parsed.errors));
        else if (parsed.value.id !== common.id) errors.push({ path: `${at}/data/id`, message: "Must match the operation's id" });
        else operations.push({ ...common, kind, data: parsed.value });
        break;
      }
      case "plan.update": {
        // The week count is the plan's, known only when it is read; the shape is checked against the largest plan.
        const parsed = parsePlanUpdate(data, 52);
        if (!parsed.ok) errors.push(...sub(parsed.errors));
        else operations.push({ ...common, kind, baseRevision: item.baseRevision as number, data: data! });
        break;
      }
      case "plan.delete":
      case "session.delete":
        operations.push({ ...common, kind, baseRevision: item.baseRevision as number });
        break;
      case "session.create": {
        const unknown = Object.keys(data!).filter((k) => !SESSION_CREATE_KEYS.includes(k));
        if (unknown.length > 0) errors.push(...unknown.map((k) => ({ path: `${at}/data/${k}`, message: "Unknown field" })));
        else operations.push({ ...common, kind, planId: item.planId as string, data: data! });
        break;
      }
      case "session.update": {
        const unknown = Object.keys(data!).filter((k) => !SESSION_UPDATE_KEYS.includes(k));
        if (unknown.length > 0 || Object.keys(data!).length === 0) errors.push(...(unknown.length ? unknown.map((k) => ({ path: `${at}/data/${k}`, message: "Unknown field" })) : [{ path: `${at}/data`, message: "Send at least one field to change" }]));
        else operations.push({ ...common, kind, baseRevision: item.baseRevision as number, data: data! });
        break;
      }
      case "checkin.create": {
        if ("id" in data!) {
          errors.push({ path: `${at}/data/id`, message: "Unknown field" });
          break;
        }
        const parsed = parseCheckInCreate({ ...data, id: common.id });
        if (!parsed.ok) errors.push(...sub(parsed.errors));
        else {
          const { id: _id, ...fields } = parsed.value;
          operations.push({ ...common, kind, sessionId: item.sessionId as string, data: fields });
        }
        break;
      }
    }
  });
  const keys = operations.map((o) => o.idempotencyKey);
  if (errors.length === 0 && new Set(keys).size !== keys.length) errors.push({ path: "/operations", message: "Each idempotency key once per request" });
  return errors.length > 0 ? { ok: false, errors } : { ok: true, value: { cursor, operations } };
}
