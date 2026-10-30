// Validation of plan and session request bodies against spec/openapi.yaml (PlanCreate, SessionCreate,
// SessionUpdate, PlanUpdate). Every problem is reported, with a JSON Pointer path. Pure: no I/O.
import type { FieldError } from "./profile";

export type { FieldError };

export type SessionType = "easy" | "long" | "intervals" | "tempo" | "strength" | "rest" | "custom";
export type Effort = "easy" | "moderate" | "hard";

export interface StepGoal {
  type: "time" | "distance" | "open";
  value?: number;
}
export type StepTarget =
  | { type: "pace"; range: { minSecPerKm: number; maxSecPerKm: number } }
  | { type: "heart_rate"; range: { minBpm: number; maxBpm: number } }
  | { type: "effort"; effort: Effort }
  | { type: "none" };
export interface RunStep {
  kind: "warmup" | "work" | "recovery" | "cooldown";
  goal: StepGoal;
  target?: StepTarget;
  note?: string;
}
export interface RepeatStep {
  kind: "repeat";
  count: number;
  steps: RunStep[];
}
export interface ExerciseStep {
  kind: "exercise";
  exerciseId: string;
  sets: number;
  reps?: number;
  durationSec?: number;
  restSec?: number;
  effort?: Effort;
  loadNote?: string;
}
export type Step = RunStep | RepeatStep | ExerciseStep;

export interface CustomDetails {
  activityLabel?: string;
  goal?: StepGoal;
  effort?: Effort;
}

export interface SessionContent {
  date: string;
  type: SessionType;
  title?: string;
  key?: boolean;
  status: "planned" | "done" | "skipped";
  owner: "system" | "user";
  steps: Step[];
  custom?: CustomDetails;
  notes?: string;
}
export interface SessionInput extends SessionContent {
  id: string;
}

export interface Goal {
  type: "5k" | "10k" | "half_marathon" | "custom" | "none";
  label?: string;
  date?: string;
  targetTimeSec?: number;
}
export interface Week {
  index: number;
  phase?: "base" | "build" | "peak" | "taper";
  notes?: string;
}
export interface EngineInfo {
  presetId: string;
  version: string;
  /** The answers the plan was generated from; kept as sent (the interview schema is validated by the generate endpoint). */
  interview?: Record<string, unknown>;
}
export interface PlanFieldsInput {
  goal: Goal;
  startDate: string;
  weekCount: number;
  source: "blank" | "rules" | "ai";
  engine?: EngineInfo;
  adaptive: boolean;
  weeks: Week[];
}
export interface PlanInput extends PlanFieldsInput {
  id: string;
  sessions: SessionInput[];
}
export interface PlanUpdateInput {
  goal?: Goal;
  adaptive?: boolean;
  weeks?: Week[];
}
export interface SessionUpdateInput {
  date?: string;
  type?: SessionType;
  title?: string;
  key?: boolean;
  status?: "planned" | "done" | "skipped";
  steps?: Step[];
  custom?: CustomDetails;
  notes?: string;
  clear?: ("title" | "notes" | "custom")[];
}

export interface PlanSpan {
  startDate: string;
  weekCount: number;
}

type Result<T> = { ok: true; value: T } | { ok: false; errors: FieldError[] };

const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;
const SESSION_TYPES: readonly string[] = ["easy", "long", "intervals", "tempo", "strength", "rest", "custom"];
const EFFORTS: readonly string[] = ["easy", "moderate", "hard"];
const STATUSES: readonly string[] = ["planned", "done", "skipped"];
const OWNERS: readonly string[] = ["system", "user"];
const GOAL_TYPES: readonly string[] = ["5k", "10k", "half_marathon", "custom", "none"];
const SOURCES: readonly string[] = ["blank", "rules", "ai"];
const PHASES: readonly string[] = ["base", "build", "peak", "taper"];
const RUN_KINDS: readonly string[] = ["warmup", "work", "recovery", "cooldown"];
const MAX_INTERVIEW_JSON = 4000;

const isObject = (v: unknown): v is Record<string, unknown> => v !== null && typeof v === "object" && !Array.isArray(v);
const isInt = (v: unknown, min: number, max: number): v is number => Number.isInteger(v) && (v as number) >= min && (v as number) <= max;
const isText = (v: unknown, max: number): v is string => typeof v === "string" && v.length <= max;

/** Whole days since 1970-01-01 for a real YYYY-MM-DD, else undefined. */
export function dayNumber(date: unknown): number | undefined {
  if (typeof date !== "string" || !/^\d{4}-\d{2}-\d{2}$/.test(date)) return undefined;
  const ms = Date.parse(`${date}T00:00:00Z`);
  return Number.isNaN(ms) || new Date(ms).toISOString().slice(0, 10) !== date ? undefined : ms / 86_400_000;
}

function unknownKeys(value: Record<string, unknown>, allowed: readonly string[], base: string, errors: FieldError[]) {
  for (const key of Object.keys(value)) if (!allowed.includes(key)) errors.push({ path: `${base}/${key}`, message: "Unknown field" });
}

function parseGoalValue(goal: unknown, path: string, errors: FieldError[]): StepGoal | undefined {
  if (!isObject(goal)) {
    errors.push({ path, message: "Send a goal" });
    return undefined;
  }
  unknownKeys(goal, ["type", "value"], path, errors);
  const type = goal.type;
  if (type !== "time" && type !== "distance" && type !== "open") {
    errors.push({ path: `${path}/type`, message: "Use time, distance or open" });
    return undefined;
  }
  if (type === "open") {
    if ("value" in goal) errors.push({ path: `${path}/value`, message: "An open goal has no value" });
    return { type };
  }
  if (!isInt(goal.value, 1, 200_000)) {
    errors.push({ path: `${path}/value`, message: "Seconds or metres, 1 to 200000" });
    return undefined;
  }
  return { type, value: goal.value };
}

function parseTarget(target: unknown, path: string, errors: FieldError[]): StepTarget | undefined {
  const bad = (message: string) => {
    errors.push({ path, message });
    return undefined;
  };
  if (!isObject(target)) return bad("Send a target");
  switch (target.type) {
    case "none":
      return Object.keys(target).length === 1 ? { type: "none" } : bad("A none target has no other fields");
    case "effort":
      return Object.keys(target).length === 2 && typeof target.effort === "string" && EFFORTS.includes(target.effort)
        ? { type: "effort", effort: target.effort as Effort }
        : bad("Use effort easy, moderate or hard");
    case "pace": {
      const r = target.range;
      return Object.keys(target).length === 2 && isObject(r) && Object.keys(r).length === 2 && isInt(r.minSecPerKm, 120, 1200) && isInt(r.maxSecPerKm, 120, 1200) && r.minSecPerKm <= r.maxSecPerKm
        ? { type: "pace", range: { minSecPerKm: r.minSecPerKm, maxSecPerKm: r.maxSecPerKm } }
        : bad("A pace range needs whole seconds per km, 120 to 1200, fastest first");
    }
    case "heart_rate": {
      const r = target.range;
      return Object.keys(target).length === 2 && isObject(r) && Object.keys(r).length === 2 && isInt(r.minBpm, 40, 230) && isInt(r.maxBpm, 40, 230) && r.minBpm <= r.maxBpm
        ? { type: "heart_rate", range: { minBpm: r.minBpm, maxBpm: r.maxBpm } }
        : bad("A heart rate range needs beats per minute, 40 to 230, lowest first");
    }
    default:
      return bad("Use pace, heart_rate, effort or none");
  }
}

function parseRunStep(raw: Record<string, unknown>, path: string, errors: FieldError[]): RunStep | undefined {
  unknownKeys(raw, ["kind", "goal", "target", "note"], path, errors);
  const before = errors.length;
  const goal = parseGoalValue(raw.goal, `${path}/goal`, errors);
  const target = "target" in raw ? parseTarget(raw.target, `${path}/target`, errors) : undefined;
  if ("note" in raw && !isText(raw.note, 200)) errors.push({ path: `${path}/note`, message: "At most 200 characters" });
  if (errors.length > before || !goal) return undefined;
  return { kind: raw.kind as RunStep["kind"], goal, ...(target ? { target } : {}), ...(typeof raw.note === "string" ? { note: raw.note } : {}) };
}

function parseSteps(raw: unknown, type: SessionType, path: string, errors: FieldError[]): Step[] {
  if (!Array.isArray(raw)) {
    errors.push({ path, message: "Send a list of steps" });
    return [];
  }
  if (raw.length > 50) {
    errors.push({ path, message: "At most 50 steps" });
    return [];
  }
  if (type === "custom" && raw.length > 0) {
    errors.push({ path, message: "A custom session has no steps" });
    return [];
  }
  const steps: Step[] = [];
  raw.forEach((item: unknown, i) => {
    const at = `${path}/${i}`;
    if (!isObject(item)) return void errors.push({ path: at, message: "Send a step" });
    const kind = item.kind;
    if (kind === "exercise") {
      if (type !== "strength") return void errors.push({ path: `${at}/kind`, message: "Exercise steps belong in a strength session" });
      unknownKeys(item, ["kind", "exerciseId", "sets", "reps", "durationSec", "restSec", "effort", "loadNote"], at, errors);
      const before = errors.length;
      if (!isText(item.exerciseId, 64) || item.exerciseId === "") errors.push({ path: `${at}/exerciseId`, message: "An exercise id, up to 64 characters" });
      if (!isInt(item.sets, 1, 10)) errors.push({ path: `${at}/sets`, message: "1 to 10 sets" });
      if ("reps" in item && !isInt(item.reps, 1, 100)) errors.push({ path: `${at}/reps`, message: "1 to 100 reps" });
      if ("durationSec" in item && !isInt(item.durationSec, 5, 600)) errors.push({ path: `${at}/durationSec`, message: "5 to 600 seconds" });
      if ("restSec" in item && !isInt(item.restSec, 0, 600)) errors.push({ path: `${at}/restSec`, message: "0 to 600 seconds" });
      if ("effort" in item && !(typeof item.effort === "string" && EFFORTS.includes(item.effort))) errors.push({ path: `${at}/effort`, message: "Use easy, moderate or hard" });
      if ("loadNote" in item && !isText(item.loadNote, 100)) errors.push({ path: `${at}/loadNote`, message: "At most 100 characters" });
      if (errors.length === before) steps.push(item as unknown as ExerciseStep);
      return;
    }
    if (type === "strength") return void errors.push({ path: `${at}/kind`, message: "A strength session has exercise steps only" });
    if (kind === "repeat") {
      unknownKeys(item, ["kind", "count", "steps"], at, errors);
      const before = errors.length;
      if (!isInt(item.count, 2, 30)) errors.push({ path: `${at}/count`, message: "2 to 30 repeats" });
      const inner = item.steps;
      const children: RunStep[] = [];
      if (!Array.isArray(inner) || inner.length < 1 || inner.length > 10) {
        errors.push({ path: `${at}/steps`, message: "1 to 10 steps in a repeat" });
      } else {
        inner.forEach((child: unknown, j) => {
          const childAt = `${at}/steps/${j}`;
          if (!isObject(child) || typeof child.kind !== "string" || !RUN_KINDS.includes(child.kind)) {
            return void errors.push({ path: `${childAt}/kind`, message: "Repeats hold warmup, work, recovery or cooldown steps (no nesting)" });
          }
          const parsed = parseRunStep(child, childAt, errors);
          if (parsed) children.push(parsed);
        });
      }
      if (errors.length === before) steps.push({ kind: "repeat", count: item.count as number, steps: children });
      return;
    }
    if (typeof kind !== "string" || !RUN_KINDS.includes(kind)) return void errors.push({ path: `${at}/kind`, message: "Use warmup, work, recovery, cooldown, repeat or exercise" });
    const parsed = parseRunStep(item, at, errors);
    if (parsed) steps.push(parsed);
  });
  return steps;
}

function parseCustom(raw: unknown, path: string, errors: FieldError[]): CustomDetails | undefined {
  if (!isObject(raw)) return void errors.push({ path, message: "Send an object" });
  unknownKeys(raw, ["activityLabel", "goal", "effort"], path, errors);
  const out: CustomDetails = {};
  if ("activityLabel" in raw) {
    if (isText(raw.activityLabel, 40)) out.activityLabel = raw.activityLabel;
    else errors.push({ path: `${path}/activityLabel`, message: "At most 40 characters" });
  }
  if ("goal" in raw) {
    const goal = parseGoalValue(raw.goal, `${path}/goal`, errors);
    if (goal) out.goal = goal;
  }
  if ("effort" in raw) {
    if (typeof raw.effort === "string" && EFFORTS.includes(raw.effort)) out.effort = raw.effort as Effort;
    else errors.push({ path: `${path}/effort`, message: "Use easy, moderate or hard" });
  }
  return out;
}

function inSpan(date: unknown, span: PlanSpan | undefined): boolean {
  const day = dayNumber(date);
  const start = dayNumber(span?.startDate);
  if (day === undefined) return false;
  if (!span || start === undefined) return true;
  return day >= start && day < start + span.weekCount * 7;
}

/** Fields shared by SessionCreate and the plan's embedded sessions. */
function parseSessionFields(body: Record<string, unknown>, span: PlanSpan | undefined, base: string, errors: FieldError[]): SessionContent | undefined {
  const before = errors.length;
  if (!inSpan(body.date, span)) errors.push({ path: `${base}/date`, message: dayNumber(body.date) === undefined ? "A calendar date, YYYY-MM-DD" : "The date is outside the plan" });
  const type = body.type;
  if (typeof type !== "string" || !SESSION_TYPES.includes(type)) {
    errors.push({ path: `${base}/type`, message: "Use easy, long, intervals, tempo, strength, rest or custom" });
    return undefined;
  }
  if ("title" in body && !isText(body.title, 80)) errors.push({ path: `${base}/title`, message: "At most 80 characters" });
  if ("key" in body && typeof body.key !== "boolean") errors.push({ path: `${base}/key`, message: "true or false" });
  if ("status" in body && !(typeof body.status === "string" && STATUSES.includes(body.status))) errors.push({ path: `${base}/status`, message: "Use planned, done or skipped" });
  if ("owner" in body && !(typeof body.owner === "string" && OWNERS.includes(body.owner))) errors.push({ path: `${base}/owner`, message: "Use system or user" });
  if ("notes" in body && !isText(body.notes, 2000)) errors.push({ path: `${base}/notes`, message: "At most 2000 characters" });
  const steps = "steps" in body ? parseSteps(body.steps, type as SessionType, `${base}/steps`, errors) : [];
  let custom: CustomDetails | undefined;
  if ("custom" in body) {
    if (type !== "custom") errors.push({ path: `${base}/custom`, message: "Custom details belong to a custom session" });
    else custom = parseCustom(body.custom, `${base}/custom`, errors);
  }
  if (errors.length > before) return undefined;
  return {
    date: body.date as string,
    type: type as SessionType,
    ...(typeof body.title === "string" ? { title: body.title } : {}),
    ...(typeof body.key === "boolean" ? { key: body.key } : {}),
    status: (body.status as SessionContent["status"]) ?? "planned",
    owner: (body.owner as SessionContent["owner"]) ?? "system",
    steps,
    ...(custom ? { custom } : {}),
    ...(typeof body.notes === "string" ? { notes: body.notes } : {}),
  };
}

const SESSION_KEYS = ["id", "date", "type", "title", "key", "status", "owner", "steps", "custom", "notes"];

export function parseSessionCreate(body: unknown, span: PlanSpan): Result<SessionInput> {
  const errors: FieldError[] = [];
  if (!isObject(body)) return { ok: false, errors: [{ path: "/", message: "Send a session" }] };
  unknownKeys(body, SESSION_KEYS, "", errors);
  if (typeof body.id !== "string" || !UUID.test(body.id)) errors.push({ path: "/id", message: "A client-generated UUID" });
  const content = parseSessionFields(body, span, "", errors);
  return errors.length > 0 || !content ? { ok: false, errors } : { ok: true, value: { id: body.id as string, ...content } };
}

export function parseGoal(raw: unknown, path: string, errors: FieldError[]): Goal | undefined {
  if (!isObject(raw)) return void errors.push({ path, message: "Send a goal" });
  unknownKeys(raw, ["type", "label", "date", "targetTimeSec"], path, errors);
  const before = errors.length;
  if (typeof raw.type !== "string" || !GOAL_TYPES.includes(raw.type)) errors.push({ path: `${path}/type`, message: "Use 5k, 10k, half_marathon, custom or none" });
  if ("label" in raw && !isText(raw.label, 80)) errors.push({ path: `${path}/label`, message: "At most 80 characters" });
  if ("date" in raw && dayNumber(raw.date) === undefined) errors.push({ path: `${path}/date`, message: "A calendar date, YYYY-MM-DD" });
  if ("targetTimeSec" in raw && !isInt(raw.targetTimeSec, 60, 86_400)) errors.push({ path: `${path}/targetTimeSec`, message: "60 to 86400 seconds" });
  if (errors.length > before) return undefined;
  return {
    type: raw.type as Goal["type"],
    ...(typeof raw.label === "string" ? { label: raw.label } : {}),
    ...(typeof raw.date === "string" ? { date: raw.date } : {}),
    ...(typeof raw.targetTimeSec === "number" ? { targetTimeSec: raw.targetTimeSec } : {}),
  };
}

function parseWeeks(raw: unknown, weekCount: number | undefined, path: string, errors: FieldError[]): Week[] {
  if (!Array.isArray(raw) || raw.length > 52) {
    errors.push({ path, message: "A list of at most 52 weeks" });
    return [];
  }
  const weeks: Week[] = [];
  const seen = new Set<number>();
  raw.forEach((item: unknown, i) => {
    const at = `${path}/${i}`;
    if (!isObject(item)) return void errors.push({ path: at, message: "Send a week" });
    unknownKeys(item, ["index", "phase", "notes"], at, errors);
    const before = errors.length;
    if (!isInt(item.index, 0, 51) || (weekCount !== undefined && item.index >= weekCount)) errors.push({ path: `${at}/index`, message: "A week inside the plan" });
    else if (seen.has(item.index)) errors.push({ path: `${at}/index`, message: "Each week once" });
    else seen.add(item.index);
    if ("phase" in item && !(typeof item.phase === "string" && PHASES.includes(item.phase))) errors.push({ path: `${at}/phase`, message: "Use base, build, peak or taper" });
    if ("notes" in item && !isText(item.notes, 1000)) errors.push({ path: `${at}/notes`, message: "At most 1000 characters" });
    if (errors.length === before) weeks.push({ index: item.index as number, ...(typeof item.phase === "string" ? { phase: item.phase as Week["phase"] } : {}), ...(typeof item.notes === "string" ? { notes: item.notes } : {}) });
  });
  return weeks;
}

export function parsePlanCreate(body: unknown): Result<PlanInput> {
  const errors: FieldError[] = [];
  if (!isObject(body)) return { ok: false, errors: [{ path: "/", message: "Send a plan" }] };
  unknownKeys(body, ["id", "goal", "startDate", "weekCount", "source", "engine", "adaptive", "weeks", "sessions"], "", errors);
  if (typeof body.id !== "string" || !UUID.test(body.id)) errors.push({ path: "/id", message: "A client-generated UUID" });
  const goal = parseGoal(body.goal, "/goal", errors);
  if (dayNumber(body.startDate) === undefined) errors.push({ path: "/startDate", message: "A calendar date, YYYY-MM-DD" });
  const weekCountOk = isInt(body.weekCount, 1, 52);
  if (!weekCountOk) errors.push({ path: "/weekCount", message: "1 to 52 weeks" });
  const sourceOk = typeof body.source === "string" && SOURCES.includes(body.source);
  if (!sourceOk) errors.push({ path: "/source", message: "Use blank, rules or ai" });
  if (typeof body.adaptive !== "boolean") errors.push({ path: "/adaptive", message: "true or false" });

  let engine: EngineInfo | undefined;
  if (sourceOk) {
    if (body.source === "blank") {
      if (body.engine !== undefined) errors.push({ path: "/engine", message: "A blank plan has no engine" });
    } else if (!isObject(body.engine)) {
      errors.push({ path: "/engine", message: "A generated plan records its engine" });
    } else {
      unknownKeys(body.engine, ["presetId", "version", "interview"], "/engine", errors);
      const e = body.engine;
      if (!isText(e.presetId, 64) || e.presetId === "") errors.push({ path: "/engine/presetId", message: "A preset id, up to 64 characters" });
      if (!isText(e.version, 32) || e.version === "") errors.push({ path: "/engine/version", message: "A version, up to 32 characters" });
      if ("interview" in e && (!isObject(e.interview) || JSON.stringify(e.interview).length > MAX_INTERVIEW_JSON)) {
        errors.push({ path: "/engine/interview", message: "The interview answers as an object" });
      }
      if (errors.every((x) => !x.path.startsWith("/engine"))) {
        engine = { presetId: e.presetId as string, version: e.version as string, ...(isObject(e.interview) ? { interview: e.interview } : {}) };
      }
    }
  }

  const weekCount = weekCountOk ? (body.weekCount as number) : undefined;
  const weeks = parseWeeks(body.weeks, weekCount, "/weeks", errors);

  const sessions: SessionInput[] = [];
  if (!Array.isArray(body.sessions)) errors.push({ path: "/sessions", message: "A list of sessions" });
  else if (body.sessions.length > 400) errors.push({ path: "/sessions", message: "At most 400 sessions" });
  else {
    const span = weekCount !== undefined && dayNumber(body.startDate) !== undefined ? { startDate: body.startDate as string, weekCount } : undefined;
    const ids = new Set<string>();
    body.sessions.forEach((item: unknown, i) => {
      const at = `/sessions/${i}`;
      if (!isObject(item)) return void errors.push({ path: at, message: "Send a session" });
      unknownKeys(item, SESSION_KEYS, at, errors);
      const before = errors.length;
      if (typeof item.id !== "string" || !UUID.test(item.id)) errors.push({ path: `${at}/id`, message: "A client-generated UUID" });
      else if (ids.has(item.id)) errors.push({ path: `${at}/id`, message: "Each session id once" });
      else ids.add(item.id);
      const content = parseSessionFields(item, span, at, errors);
      if (errors.length === before && content) sessions.push({ id: item.id as string, ...content });
    });
  }

  if (errors.length > 0 || !goal) return { ok: false, errors };
  return {
    ok: true,
    value: {
      id: body.id as string,
      goal,
      startDate: body.startDate as string,
      weekCount: body.weekCount as number,
      source: body.source as PlanInput["source"],
      ...(engine ? { engine } : {}),
      adaptive: body.adaptive as boolean,
      weeks,
      sessions,
    },
  };
}

export function parsePlanUpdate(body: unknown, weekCount: number): Result<PlanUpdateInput> {
  const errors: FieldError[] = [];
  if (!isObject(body) || Object.keys(body).length === 0) return { ok: false, errors: [{ path: "/", message: "Send at least one field to change" }] };
  unknownKeys(body, ["goal", "adaptive", "weeks"], "", errors);
  const value: PlanUpdateInput = {};
  if ("goal" in body) {
    const goal = parseGoal(body.goal, "/goal", errors);
    if (goal) value.goal = goal;
  }
  if ("adaptive" in body) {
    if (typeof body.adaptive === "boolean") value.adaptive = body.adaptive;
    else errors.push({ path: "/adaptive", message: "true or false" });
  }
  if ("weeks" in body) value.weeks = parseWeeks(body.weeks, weekCount, "/weeks", errors);
  return errors.length > 0 ? { ok: false, errors } : { ok: true, value };
}

export function parseSessionUpdate(
  body: unknown,
  span: PlanSpan,
  currentType: SessionType,
): { ok: true; value: SessionUpdateInput; onlyStatus: boolean } | { ok: false; errors: FieldError[] } {
  const errors: FieldError[] = [];
  if (!isObject(body) || Object.keys(body).length === 0) return { ok: false, errors: [{ path: "/", message: "Send at least one field to change" }] };
  unknownKeys(body, ["date", "type", "title", "key", "status", "steps", "custom", "notes", "clear"], "", errors);
  const value: SessionUpdateInput = {};
  if ("date" in body) {
    if (inSpan(body.date, span)) value.date = body.date as string;
    else errors.push({ path: "/date", message: dayNumber(body.date) === undefined ? "A calendar date, YYYY-MM-DD" : "The date is outside the plan" });
  }
  let type = currentType;
  if ("type" in body) {
    if (typeof body.type === "string" && SESSION_TYPES.includes(body.type)) type = value.type = body.type as SessionType;
    else errors.push({ path: "/type", message: "Use easy, long, intervals, tempo, strength, rest or custom" });
  }
  if ("title" in body) {
    if (isText(body.title, 80)) value.title = body.title;
    else errors.push({ path: "/title", message: "At most 80 characters" });
  }
  if ("key" in body) {
    if (typeof body.key === "boolean") value.key = body.key;
    else errors.push({ path: "/key", message: "true or false" });
  }
  if ("status" in body) {
    if (typeof body.status === "string" && STATUSES.includes(body.status)) value.status = body.status as SessionUpdateInput["status"];
    else errors.push({ path: "/status", message: "Use planned, done or skipped" });
  }
  if ("notes" in body) {
    if (isText(body.notes, 2000)) value.notes = body.notes;
    else errors.push({ path: "/notes", message: "At most 2000 characters" });
  }
  if ("steps" in body) value.steps = parseSteps(body.steps, type, "/steps", errors);
  if ("custom" in body) {
    if (type !== "custom") errors.push({ path: "/custom", message: "Custom details belong to a custom session" });
    else {
      const custom = parseCustom(body.custom, "/custom", errors);
      if (custom) value.custom = custom;
    }
  }
  if ("clear" in body) {
    const clear = body.clear;
    const allowed = ["title", "notes", "custom"];
    if (!Array.isArray(clear)) errors.push({ path: "/clear", message: "A list of fields" });
    else {
      clear.forEach((f: unknown, i) => {
        if (typeof f !== "string" || !allowed.includes(f)) errors.push({ path: `/clear/${i}`, message: "Use title, notes or custom" });
      });
      if (new Set(clear).size !== clear.length) errors.push({ path: "/clear", message: "Each field once" });
      else if (clear.some((f) => typeof f === "string" && f in value)) errors.push({ path: "/clear", message: "A field cannot be both set and cleared" });
      else if (clear.every((f) => typeof f === "string" && allowed.includes(f))) value.clear = clear as SessionUpdateInput["clear"];
    }
  }
  if (errors.length > 0) return { ok: false, errors };
  const keys = Object.keys(body);
  return { ok: true, value, onlyStatus: keys.length === 1 && keys[0] === "status" };
}
