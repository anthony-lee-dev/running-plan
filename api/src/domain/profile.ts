// The user's profile (design §5, §6.6a): how targets are shown, manual paces, heart rate the user gave us,
// scheduling preferences and the review cadence. Pure: validation and merging, no I/O.

export type TargetDisplay = "pace" | "heart_rate" | "effort";
export type Weekday = "mon" | "tue" | "wed" | "thu" | "fri" | "sat" | "sun";
export type ReviewFrequency = "weekly" | "weekly_plus_urgent" | "after_import" | "off";

export interface PaceRange {
  minSecPerKm: number;
  maxSecPerKm: number;
}
export interface HeartRateRange {
  minBpm: number;
  maxBpm: number;
}

export interface StoredPaces {
  source: "race" | "estimated" | "manual" | "none";
  basedOn?: string;
  easy?: PaceRange;
  long?: PaceRange;
  tempo?: PaceRange;
  interval?: PaceRange;
}

export interface ProfileFields {
  targetDisplay: TargetDisplay;
  paces: StoredPaces;
  heartRate: { maxBpm?: number; zones?: HeartRateRange[] };
  scheduling: { longRunDay?: Weekday; restDay?: Weekday; unavailableDays?: Weekday[] };
  review: { frequency: ReviewFrequency; day?: Weekday };
}

export interface Profile extends ProfileFields {
  revision: number;
  updatedAt: string;
}

/** What a user has before they change anything. Its revision is 1. */
export const DEFAULT_PROFILE: ProfileFields = {
  targetDisplay: "pace",
  paces: { source: "none" },
  heartRate: {},
  scheduling: {},
  review: { frequency: "weekly_plus_urgent" },
};

/** A validated PATCH body: only the sections the user sent. */
export interface ProfileUpdate {
  targetDisplay?: TargetDisplay;
  paces?: Partial<Record<PaceZone, PaceRange>>;
  heartRate?: ProfileFields["heartRate"];
  scheduling?: ProfileFields["scheduling"];
  review?: ProfileFields["review"];
}

export interface FieldError {
  path: string;
  message: string;
}

const DISPLAYS: readonly string[] = ["pace", "heart_rate", "effort"];
const FREQUENCIES: readonly string[] = ["weekly", "weekly_plus_urgent", "after_import", "off"];
const WEEKDAYS: readonly string[] = ["mon", "tue", "wed", "thu", "fri", "sat", "sun"];
export const PACE_ZONES = ["easy", "long", "tempo", "interval"] as const;
type PaceZone = (typeof PACE_ZONES)[number];

const isObject = (v: unknown): v is Record<string, unknown> => v !== null && typeof v === "object" && !Array.isArray(v);
const isInt = (v: unknown, min: number, max: number): v is number => Number.isInteger(v) && (v as number) >= min && (v as number) <= max;
const isWeekday = (v: unknown): v is Weekday => typeof v === "string" && WEEKDAYS.includes(v);

function unknownKeys(value: Record<string, unknown>, allowed: readonly string[], base: string, errors: FieldError[]) {
  for (const key of Object.keys(value)) {
    if (!allowed.includes(key)) errors.push({ path: `${base}/${key}`, message: "Unknown field" });
  }
}

/** Validates a PATCH body. Reports every problem, not just the first. */
export function parseProfileUpdate(
  body: unknown,
): { ok: true; value: ProfileUpdate } | { ok: false; errors: FieldError[] } {
  const errors: FieldError[] = [];
  if (!isObject(body) || Object.keys(body).length === 0) {
    return { ok: false, errors: [{ path: "/", message: "Send at least one field to change" }] };
  }
  unknownKeys(body, ["targetDisplay", "paces", "heartRate", "scheduling", "review"], "", errors);
  const value: ProfileUpdate = {};

  if ("targetDisplay" in body) {
    if (typeof body.targetDisplay === "string" && DISPLAYS.includes(body.targetDisplay)) {
      value.targetDisplay = body.targetDisplay as TargetDisplay;
    } else errors.push({ path: "/targetDisplay", message: "Use pace, heart_rate or effort" });
  }

  if ("paces" in body) {
    if (!isObject(body.paces)) errors.push({ path: "/paces", message: "Send an object of pace ranges" });
    else {
      unknownKeys(body.paces, PACE_ZONES, "/paces", errors);
      const paces: Partial<Record<PaceZone, PaceRange>> = {};
      for (const zone of PACE_ZONES) {
        if (!(zone in body.paces)) continue;
        const r = body.paces[zone];
        if (isObject(r) && isInt(r.minSecPerKm, 120, 1200) && isInt(r.maxSecPerKm, 120, 1200) && r.minSecPerKm < r.maxSecPerKm && Object.keys(r).length === 2) {
          paces[zone] = { minSecPerKm: r.minSecPerKm, maxSecPerKm: r.maxSecPerKm };
        } else errors.push({ path: `/paces/${zone}`, message: "A pace range needs whole seconds per km, 120 to 1200, fastest first" });
      }
      value.paces = paces;
    }
  }

  if ("heartRate" in body) {
    const hr = body.heartRate;
    if (!isObject(hr)) errors.push({ path: "/heartRate", message: "Send an object" });
    else {
      unknownKeys(hr, ["maxBpm", "zones"], "/heartRate", errors);
      const out: ProfileFields["heartRate"] = {};
      if ("maxBpm" in hr) {
        if (isInt(hr.maxBpm, 100, 230)) out.maxBpm = hr.maxBpm;
        else errors.push({ path: "/heartRate/maxBpm", message: "Whole beats per minute, 100 to 230" });
      }
      if ("zones" in hr) {
        if (!Array.isArray(hr.zones) || hr.zones.length !== 5) {
          errors.push({ path: "/heartRate/zones", message: "Send exactly five zones" });
        } else {
          const zones: HeartRateRange[] = [];
          hr.zones.forEach((z: unknown, i: number) => {
            if (isObject(z) && isInt(z.minBpm, 40, 230) && isInt(z.maxBpm, 40, 230) && z.minBpm < z.maxBpm && Object.keys(z).length === 2) {
              zones.push({ minBpm: z.minBpm, maxBpm: z.maxBpm });
            } else errors.push({ path: `/heartRate/zones/${i}`, message: "A zone needs minBpm below maxBpm, 40 to 230" });
          });
          out.zones = zones;
        }
      }
      value.heartRate = out;
    }
  }

  if ("scheduling" in body) {
    const sc = body.scheduling;
    if (!isObject(sc)) errors.push({ path: "/scheduling", message: "Send an object" });
    else {
      unknownKeys(sc, ["longRunDay", "restDay", "unavailableDays"], "/scheduling", errors);
      const out: ProfileFields["scheduling"] = {};
      for (const key of ["longRunDay", "restDay"] as const) {
        if (!(key in sc)) continue;
        if (isWeekday(sc[key])) out[key] = sc[key];
        else errors.push({ path: `/scheduling/${key}`, message: "Use mon to sun" });
      }
      if ("unavailableDays" in sc) {
        const days = sc.unavailableDays;
        if (!Array.isArray(days) || days.length > 6 || !days.every(isWeekday) || new Set(days).size !== days.length) {
          errors.push({ path: "/scheduling/unavailableDays", message: "At most six different days, mon to sun" });
        } else out.unavailableDays = days as Weekday[];
      }
      if (out.longRunDay && out.unavailableDays?.includes(out.longRunDay)) {
        errors.push({ path: "/scheduling/longRunDay", message: "The long run day cannot be an unavailable day" });
      }
      value.scheduling = out;
    }
  }

  if ("review" in body) {
    const rv = body.review;
    if (!isObject(rv)) errors.push({ path: "/review", message: "Send an object" });
    else {
      unknownKeys(rv, ["frequency", "day"], "/review", errors);
      const out: Partial<ProfileFields["review"]> = {};
      if (typeof rv.frequency === "string" && FREQUENCIES.includes(rv.frequency)) out.frequency = rv.frequency as ReviewFrequency;
      else errors.push({ path: "/review/frequency", message: "Use weekly, weekly_plus_urgent, after_import or off" });
      if ("day" in rv) {
        if (isWeekday(rv.day)) out.day = rv.day;
        else errors.push({ path: "/review/day", message: "Use mon to sun" });
      }
      value.review = out as ProfileFields["review"];
    }
  }

  return errors.length > 0 ? { ok: false, errors } : { ok: true, value };
}

/**
 * The profile after an update. `heartRate`, `scheduling` and `review` are replaced whole, so leaving a field out of
 * a section you send clears it (the spec has no other way to clear one); `paces` merge by zone. Sections left out
 * of the request stay as they are.
 */
export function applyProfileUpdate(current: ProfileFields, update: ProfileUpdate): ProfileFields {
  const next: ProfileFields = structuredClone(current);
  if (update.targetDisplay) next.targetDisplay = update.targetDisplay;
  if (update.heartRate) next.heartRate = structuredClone(update.heartRate);
  if (update.scheduling) next.scheduling = structuredClone(update.scheduling);
  if (update.review) next.review = structuredClone(update.review);
  if (update.paces && Object.keys(update.paces).length > 0) {
    // Typed in by the user, so it is no longer derived from a race: drop the provenance.
    const { basedOn: _basedOn, ...rest } = next.paces;
    next.paces = { ...rest, ...structuredClone(update.paces), source: "manual" };
  }
  return next;
}
