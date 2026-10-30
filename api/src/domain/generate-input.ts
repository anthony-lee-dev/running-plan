// Validation of the `GenerateRequest` body (spec/openapi.yaml) for `POST /v1/plans/generate`. Strict: unknown fields
// are rejected at every level and every bound in the spec is checked, so the engine only ever sees well-formed answers.
// Every problem is reported with a JSON Pointer path. Pure: no I/O.
import type { GenerateInput } from "./engine";
import type { InterviewAnswers, Weekday } from "./interview";
import { WEEKDAYS } from "./interview";
import { PRESETS } from "./presets";
import type { FieldError } from "./profile";

type Result = { ok: true; value: GenerateInput } | { ok: false; errors: FieldError[] };
type Obj = Record<string, unknown>;

const DISTANCES: readonly string[] = ["5k", "10k", "half_marathon"];
const HISTORIES: readonly string[] = ["new_or_returning", "under_1_year", "1_to_3_years", "over_3_years"];
const DISPLAYS: readonly string[] = ["pace", "heart_rate", "effort"];
const EQUIPMENT: readonly string[] = ["bodyweight", "dumbbells"];

const isObject = (v: unknown): v is Obj => v !== null && typeof v === "object" && !Array.isArray(v);
const isInt = (v: unknown, min: number, max: number): v is number => Number.isInteger(v) && (v as number) >= min && (v as number) <= max;
const isWeekday = (v: unknown): v is Weekday => typeof v === "string" && (WEEKDAYS as readonly string[]).includes(v);
const isOneOf = (v: unknown, values: readonly string[]): v is string => typeof v === "string" && values.includes(v);

/** A real calendar date in 2000 to 2099, so plan dates stay four-digit years. */
function isLocalDate(v: unknown): v is string {
  if (typeof v !== "string" || !/^20\d{2}-\d{2}-\d{2}$/.test(v)) return false;
  const ms = Date.parse(`${v}T00:00:00Z`);
  return !Number.isNaN(ms) && new Date(ms).toISOString().slice(0, 10) === v;
}

function unknownKeys(value: Obj, allowed: readonly string[], base: string, errors: FieldError[]) {
  for (const key of Object.keys(value)) {
    if (!allowed.includes(key)) errors.push({ path: `${base}/${key}`, message: "Unknown field" });
  }
}

/** Checks `value[key]` when present; a failed check adds an error and leaves the field out. */
function optional<T>(value: Obj, key: string, base: string, errors: FieldError[], check: (v: unknown) => v is T, message: string, out: Obj) {
  if (!(key in value)) return;
  if (check(value[key])) out[key] = value[key];
  else errors.push({ path: `${base}/${key}`, message });
}

function parseGoal(raw: unknown, errors: FieldError[]): InterviewAnswers["goal"] | undefined {
  const base = "/answers/goal";
  if (!isObject(raw)) {
    errors.push({ path: base, message: "Send the goal with its distance" });
    return undefined;
  }
  unknownKeys(raw, ["distance", "date", "targetTimeSec"], base, errors);
  const out: Obj = {};
  if (isOneOf(raw.distance, DISTANCES)) out.distance = raw.distance;
  else errors.push({ path: `${base}/distance`, message: "Use 5k, 10k or half_marathon" });
  optional(raw, "date", base, errors, isLocalDate, "A date in 2000 to 2099, YYYY-MM-DD", out);
  optional(raw, "targetTimeSec", base, errors, (v): v is number => isInt(v, 600, 21600), "Whole seconds, 600 to 21600", out);
  return out as InterviewAnswers["goal"];
}

function parseRecentResult(raw: unknown, errors: FieldError[]): InterviewAnswers["recentResult"] | undefined {
  const base = "/answers/recentResult";
  if (!isObject(raw)) {
    errors.push({ path: base, message: "Send the distance and time of the run" });
    return undefined;
  }
  unknownKeys(raw, ["distanceM", "timeSec", "date"], base, errors);
  const out: Obj = {};
  if (isInt(raw.distanceM, 1000, 42195)) out.distanceM = raw.distanceM;
  else errors.push({ path: `${base}/distanceM`, message: "Whole metres, 1000 to 42195" });
  if (isInt(raw.timeSec, 120, 28800)) out.timeSec = raw.timeSec;
  else errors.push({ path: `${base}/timeSec`, message: "Whole seconds, 120 to 28800" });
  optional(raw, "date", base, errors, isLocalDate, "A date in 2000 to 2099, YYYY-MM-DD", out);
  return out as InterviewAnswers["recentResult"];
}

function parseUnavailableDays(raw: unknown, errors: FieldError[]): Weekday[] | undefined {
  const base = "/answers/unavailableDays";
  if (!Array.isArray(raw) || raw.length > 4) {
    errors.push({ path: base, message: "Up to four weekdays" });
    return undefined;
  }
  raw.forEach((d, i) => {
    if (!isWeekday(d)) errors.push({ path: `${base}/${i}`, message: "Use mon, tue, wed, thu, fri, sat or sun" });
  });
  if (new Set(raw).size !== raw.length) errors.push({ path: base, message: "Each weekday once" });
  return raw as Weekday[];
}

function parseStrength(raw: unknown, errors: FieldError[]): InterviewAnswers["strength"] | undefined {
  const base = "/answers/strength";
  if (!isObject(raw)) {
    errors.push({ path: base, message: "Send whether strength sessions are wanted" });
    return undefined;
  }
  unknownKeys(raw, ["enabled", "equipment"], base, errors);
  const out: Obj = {};
  if (typeof raw.enabled === "boolean") out.enabled = raw.enabled;
  else errors.push({ path: `${base}/enabled`, message: "true or false" });
  optional(raw, "equipment", base, errors, (v): v is string => isOneOf(v, EQUIPMENT), "Use bodyweight or dumbbells", out);
  return out as InterviewAnswers["strength"];
}

function parseHeartRate(raw: unknown, errors: FieldError[]): InterviewAnswers["heartRate"] | undefined {
  const base = "/answers/heartRate";
  if (!isObject(raw)) {
    errors.push({ path: base, message: "Send an object" });
    return undefined;
  }
  unknownKeys(raw, ["maxBpm", "zones"], base, errors);
  const out: NonNullable<InterviewAnswers["heartRate"]> = {};
  if ("maxBpm" in raw) {
    if (isInt(raw.maxBpm, 100, 230)) out.maxBpm = raw.maxBpm;
    else errors.push({ path: `${base}/maxBpm`, message: "Whole beats per minute, 100 to 230" });
  }
  if ("zones" in raw) {
    if (!Array.isArray(raw.zones) || raw.zones.length !== 5) errors.push({ path: `${base}/zones`, message: "Send exactly five zones" });
    else {
      out.zones = [];
      raw.zones.forEach((z: unknown, i: number) => {
        if (isObject(z) && isInt(z.minBpm, 40, 230) && isInt(z.maxBpm, 40, 230) && z.minBpm < z.maxBpm && Object.keys(z).length === 2) {
          out.zones!.push({ minBpm: z.minBpm, maxBpm: z.maxBpm });
        } else errors.push({ path: `${base}/zones/${i}`, message: "A zone needs minBpm below maxBpm, 40 to 230" });
      });
    }
  }
  return out;
}

const ANSWER_KEYS = ["goal", "recentResult", "weeklyDistanceM", "longestRunM", "runningHistory", "runsPerWeek", "unavailableDays", "longRunDay", "pain", "strength", "targetDisplay", "heartRate"];

function parseAnswers(raw: unknown, errors: FieldError[]): InterviewAnswers | undefined {
  const base = "/answers";
  if (!isObject(raw)) {
    errors.push({ path: base, message: "Send the interview answers" });
    return undefined;
  }
  unknownKeys(raw, ANSWER_KEYS, base, errors);
  const out: Obj = {};
  if (!("goal" in raw)) errors.push({ path: `${base}/goal`, message: "Send the goal with its distance" });
  else out.goal = parseGoal(raw.goal, errors);
  if ("recentResult" in raw) out.recentResult = parseRecentResult(raw.recentResult, errors);
  optional(raw, "weeklyDistanceM", base, errors, (v): v is number => isInt(v, 0, 200000), "Whole metres, 0 to 200000", out);
  optional(raw, "longestRunM", base, errors, (v): v is number => isInt(v, 0, 50000), "Whole metres, 0 to 50000", out);
  optional(raw, "runningHistory", base, errors, (v): v is string => isOneOf(v, HISTORIES), "Use new_or_returning, under_1_year, 1_to_3_years or over_3_years", out);
  optional(raw, "runsPerWeek", base, errors, (v): v is number => isInt(v, 3, 5), "3, 4 or 5", out);
  if ("unavailableDays" in raw) out.unavailableDays = parseUnavailableDays(raw.unavailableDays, errors);
  optional(raw, "longRunDay", base, errors, isWeekday, "Use mon, tue, wed, thu, fri, sat or sun", out);
  optional(raw, "pain", base, errors, (v): v is boolean => typeof v === "boolean", "true or false", out);
  if ("strength" in raw) out.strength = parseStrength(raw.strength, errors);
  optional(raw, "targetDisplay", base, errors, (v): v is string => isOneOf(v, DISPLAYS), "Use pace, heart_rate or effort", out);
  if ("heartRate" in raw) out.heartRate = parseHeartRate(raw.heartRate, errors);
  return out as unknown as InterviewAnswers;
}

/** Validates a generate request body. Reports every problem, not just the first. */
export function parseGenerateRequest(body: unknown): Result {
  if (!isObject(body)) return { ok: false, errors: [{ path: "/", message: "Send the interview answers and today's date" }] };
  const errors: FieldError[] = [];
  unknownKeys(body, ["answers", "today", "presetId"], "", errors);
  const answers = parseAnswers(body.answers, errors);
  if (!isLocalDate(body.today)) errors.push({ path: "/today", message: "Today's local date in 2000 to 2099, YYYY-MM-DD" });
  const hasPreset = "presetId" in body;
  // An own key only, so names like "toString" are not taken for a preset.
  if (hasPreset && !(typeof body.presetId === "string" && body.presetId.length <= 64 && Object.hasOwn(PRESETS, body.presetId))) {
    errors.push({ path: "/presetId", message: `Use one of ${Object.keys(PRESETS).join(", ")}` });
  }
  if (errors.length > 0 || !answers) return { ok: false, errors };
  return { ok: true, value: { answers, today: body.today as string, ...(hasPreset ? { presetId: body.presetId as string } : {}) } };
}
