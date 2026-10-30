// Imported activities (design §8.3): validation of the upload batch and the dedupe that maps a re-sent or re-written
// record to the activity already stored. Garmin re-writes Health records with new ids, so besides the source id an
// activity also matches on type, start, duration and distance within a tolerance. Pure: no I/O.
import type { FieldError } from "./profile";

export type ActivitySource = "apple_health" | "manual";
export type WorkoutType = "running" | "strength" | "cycling" | "swimming" | "walking" | "other";
export type Disposition = "inbox" | "matched" | "extra" | "ignored";

export interface ActivityFields {
  source: ActivitySource;
  externalId: string;
  sourceApp?: string;
  workoutType: WorkoutType;
  /** RFC 3339 with the UTC offset at the start. */
  startedAt: string;
  localDate: string;
  durationSec: number;
  distanceM?: number;
  avgHeartRate?: number;
  maxHeartRate?: number;
  avgCadence?: number;
  elevationGainM?: number;
}

export interface StoredActivity extends ActivityFields {
  id: string;
  disposition: Disposition;
  importedAt: string;
  revision: number;
  updatedAt: string;
}

export interface ImportResult {
  externalId: string;
  status: "created" | "duplicate" | "updated";
  activityId: string;
}

// Tolerances for "the same workout written twice". Starting values; adjust if real device data says otherwise.
export const SAME_START_SEC = 120;
const SAME_DURATION = { sec: 60, share: 0.03 };
const SAME_DISTANCE = { m: 100, share: 0.03 };
export const MAX_BATCH = 200;

const OPTIONAL_KEYS = ["sourceApp", "distanceM", "avgHeartRate", "maxHeartRate", "avgCadence", "elevationGainM"] as const;
const FIELD_KEYS: readonly (keyof ActivityFields)[] = ["source", "externalId", "workoutType", "startedAt", "localDate", "durationSec", ...OPTIONAL_KEYS];

const within = (a: number, b: number, abs: number, share: number) => Math.abs(a - b) <= Math.max(abs, share * Math.max(a, b));

function sameWorkout(a: ActivityFields, b: ActivityFields): boolean {
  if (a.workoutType !== b.workoutType) return false;
  if (Math.abs(Date.parse(a.startedAt) - Date.parse(b.startedAt)) > SAME_START_SEC * 1000) return false;
  if (!within(a.durationSec, b.durationSec, SAME_DURATION.sec, SAME_DURATION.share)) return false;
  // A record without a distance (strength, or a re-write that dropped it) is compared on the rest.
  if (a.distanceM === undefined || b.distanceM === undefined) return true;
  return within(a.distanceM, b.distanceM, SAME_DISTANCE.m, SAME_DISTANCE.share);
}

const sameFields = (a: ActivityFields, b: ActivityFields) => FIELD_KEYS.every((k) => a[k] === b[k]);
const fieldsOf = (a: ActivityFields): ActivityFields => Object.fromEntries(FIELD_KEYS.filter((k) => a[k] !== undefined).map((k) => [k, a[k]])) as unknown as ActivityFields;

/**
 * What an upload does to the stored activities, in order: one result per input, plus the rows to insert and update.
 * `existing` must hold the user's activities around the batch's dates (a day either side covers time zones).
 */
export function planImport(existing: StoredActivity[], inputs: ActivityFields[], now: string, newId: () => string) {
  const known = new Map(existing.map((a) => [a.id, structuredClone(a)]));
  const created = new Set<string>();
  const updated = new Set<string>();
  const results: ImportResult[] = inputs.map((input) => {
    const all = [...known.values()];
    const exact = all.find((a) => a.source === input.source && a.externalId === input.externalId);
    const fuzzy = exact
      ? undefined
      : all
          .filter((a) => a.source === input.source && sameWorkout(a, input))
          .sort((a, b) => Math.abs(Date.parse(a.startedAt) - Date.parse(input.startedAt)) - Math.abs(Date.parse(b.startedAt) - Date.parse(input.startedAt)))[0];
    const hit = exact ?? fuzzy;
    if (!hit) {
      const activity: StoredActivity = { ...fieldsOf(input), id: newId(), disposition: "inbox", importedAt: now, revision: 1, updatedAt: now };
      known.set(activity.id, activity);
      created.add(activity.id);
      return { externalId: input.externalId, status: "created" as const, activityId: activity.id };
    }
    // An exact hit takes the newer values (a missing field never erases one). A re-write under another id only fills
    // in what the stored record lacks: it keeps its own id and values, so two copies of one run in Health settle
    // instead of swapping on every sync.
    const merged: ActivityFields = exact ? { ...fieldsOf(hit), ...fieldsOf(input) } : { ...fieldsOf(input), ...fieldsOf(hit) };
    if (sameFields(hit, merged)) return { externalId: input.externalId, status: exact ? ("duplicate" as const) : ("updated" as const), activityId: hit.id };
    const next: StoredActivity = {
      ...merged,
      id: hit.id,
      disposition: hit.disposition,
      importedAt: hit.importedAt,
      revision: created.has(hit.id) ? 1 : hit.revision + (updated.has(hit.id) ? 0 : 1),
      updatedAt: now,
    };
    known.set(hit.id, next);
    if (!created.has(hit.id)) updated.add(hit.id);
    return { externalId: input.externalId, status: "updated" as const, activityId: hit.id };
  });
  return {
    results,
    creates: [...created].map((id) => known.get(id)!),
    updates: [...updated].map((id) => known.get(id)!),
  };
}

// ---- Validation of ActivityBatchRequest (spec/openapi.yaml) ----

type Obj = Record<string, unknown>;
const isObject = (v: unknown): v is Obj => v !== null && typeof v === "object" && !Array.isArray(v);
const isInt = (v: unknown, min: number, max: number): v is number => Number.isInteger(v) && (v as number) >= min && (v as number) <= max;
const SOURCES: readonly string[] = ["apple_health", "manual"];
const TYPES: readonly string[] = ["running", "strength", "cycling", "swimming", "walking", "other"];
const DATE_TIME = /^(\d{4}-\d{2}-\d{2})T([01]\d|2[0-3]):[0-5]\d:[0-5]\d(\.\d{1,9})?(Z|[+-]\d{2}:\d{2})$/i;

export function isLocalDate(v: unknown): v is string {
  if (typeof v !== "string" || !/^20\d{2}-\d{2}-\d{2}$/.test(v)) return false;
  const ms = Date.parse(`${v}T00:00:00Z`);
  return !Number.isNaN(ms) && new Date(ms).toISOString().slice(0, 10) === v;
}

const INT_RANGES: Record<string, [number, number, string]> = {
  durationSec: [1, 86400, "Whole seconds, 1 to 86400"],
  distanceM: [0, 400000, "Whole metres, 0 to 400000"],
  avgHeartRate: [30, 250, "Beats per minute, 30 to 250"],
  maxHeartRate: [30, 250, "Beats per minute, 30 to 250"],
  avgCadence: [0, 300, "Steps per minute, 0 to 300"],
  elevationGainM: [0, 10000, "Whole metres, 0 to 10000"],
};

function parseActivity(raw: unknown, base: string, errors: FieldError[]): ActivityFields | undefined {
  if (!isObject(raw)) {
    errors.push({ path: base, message: "Send an activity" });
    return undefined;
  }
  const before = errors.length;
  for (const key of Object.keys(raw)) {
    if (!(FIELD_KEYS as readonly string[]).includes(key)) errors.push({ path: `${base}/${key}`, message: "Unknown field" });
  }
  if (!(typeof raw.source === "string" && SOURCES.includes(raw.source))) errors.push({ path: `${base}/source`, message: "Use apple_health or manual" });
  if (!(typeof raw.externalId === "string" && raw.externalId.length >= 1 && raw.externalId.length <= 128)) errors.push({ path: `${base}/externalId`, message: "The source record id, 1 to 128 characters" });
  if ("sourceApp" in raw && !(typeof raw.sourceApp === "string" && raw.sourceApp.length <= 64)) errors.push({ path: `${base}/sourceApp`, message: "Up to 64 characters" });
  if (!(typeof raw.workoutType === "string" && TYPES.includes(raw.workoutType))) errors.push({ path: `${base}/workoutType`, message: `Use ${TYPES.join(", ")}` });
  const start = typeof raw.startedAt === "string" ? DATE_TIME.exec(raw.startedAt) : null;
  // The date part is checked as a calendar date: Date.parse would roll 30 February over to March.
  if (!(start && isLocalDate(start[1]) && !Number.isNaN(Date.parse(raw.startedAt as string)))) {
    errors.push({ path: `${base}/startedAt`, message: "A date and time with its UTC offset, like 2026-10-28T07:00:00-04:00" });
  }
  if (!isLocalDate(raw.localDate)) errors.push({ path: `${base}/localDate`, message: "The local date it started, YYYY-MM-DD" });
  for (const [key, [min, max, message]] of Object.entries(INT_RANGES)) {
    if ((key === "durationSec" || key in raw) && !isInt(raw[key], min, max)) errors.push({ path: `${base}/${key}`, message });
  }
  return errors.length === before ? fieldsOf(raw as unknown as ActivityFields) : undefined;
}

/** Validates an upload. Reports every problem, not just the first. */
export function parseActivityBatch(body: unknown): { ok: true; value: ActivityFields[] } | { ok: false; errors: FieldError[] } {
  if (!isObject(body)) return { ok: false, errors: [{ path: "/", message: "Send the activities" }] };
  const errors: FieldError[] = [];
  for (const key of Object.keys(body)) if (key !== "activities") errors.push({ path: `/${key}`, message: "Unknown field" });
  const list = body.activities;
  if (!Array.isArray(list) || list.length < 1 || list.length > MAX_BATCH) {
    errors.push({ path: "/activities", message: `Send 1 to ${MAX_BATCH} activities` });
    return { ok: false, errors };
  }
  const value = list.map((a, i) => parseActivity(a, `/activities/${i}`, errors));
  return errors.length > 0 ? { ok: false, errors } : { ok: true, value: value as ActivityFields[] };
}
