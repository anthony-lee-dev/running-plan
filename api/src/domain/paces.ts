// Pace and target derivation (design §6.3). Pure and deterministic. Paces are seconds per km, shown as 6:30/km.
// The race-equivalence model is Riegel (open decision §12.2, chosen for backlog 2.9). The zone anchors below are
// starting values to review with a coach (backlog H.1).

export const RIEGEL_EXPONENT = 1.06;

export interface RecentResult {
  distanceM: number;
  timeSec: number;
  /** Local date of the run, YYYY-MM-DD. Absent means recent. */
  date?: string;
}

export interface PaceRange {
  /** The faster end. */
  minSecPerKm: number;
  maxSecPerKm: number;
}

export interface DerivedPaces {
  source: "race" | "estimated" | "manual" | "none";
  basedOn?: string;
  easy?: PaceRange;
  long?: PaceRange;
  tempo?: PaceRange;
  interval?: PaceRange;
}

export interface HeartRateRange {
  minBpm: number;
  maxBpm: number;
}

export interface HeartRateSettings {
  maxBpm?: number;
  /** Five zones, easiest first. */
  zones?: HeartRateRange[];
}

export type Zone = "easy" | "long" | "tempo" | "interval";
export type TargetKind = "pace" | "heart_rate" | "effort";

/** A result older than this many days is only an estimate of today's fitness. */
export const STALE_AFTER_DAYS = 42;

/** Pace anchors as multiples of the 5K-equivalent pace (easy, long), of the 10K pace (tempo) and 3K to 5K (interval). */
const EASY = [1.2, 1.35] as const;
const LONG = [1.15, 1.3] as const;
const TEMPO = [0.97, 1.03] as const;

const MIN_PACE = 120;
/** Faster than this, a result is a typo, not a run (the fastest ranges still need room above MIN_PACE). */
const MIN_RESULT_PACE = 150;
const MAX_PACE = 1200;

/** Share of maximum heart rate for each zone, used only when the user supplied a maximum. Unreviewed (backlog H.1). */
const HR_BANDS: Record<Zone, readonly [number, number]> = {
  easy: [0.6, 0.75],
  long: [0.6, 0.78],
  tempo: [0.82, 0.88],
  interval: [0.88, 0.95],
};
/** Which of the user's five zones (0-based) each kind of running maps to. */
const HR_ZONE_INDEX: Record<Zone, number> = { easy: 1, long: 1, tempo: 3, interval: 4 };

/** Riegel: the time a runner who ran `result` could run `distanceM`, in seconds. */
export function equivalentTimeSec(result: Pick<RecentResult, "distanceM" | "timeSec">, distanceM: number): number {
  if (result.distanceM === distanceM) return result.timeSec;
  return result.timeSec * (distanceM / result.distanceM) ** RIEGEL_EXPONENT;
}

function pacePerKm(result: RecentResult, distanceM: number): number {
  return equivalentTimeSec(result, distanceM) / (distanceM / 1000);
}

/** Whole seconds, with halves rounding up even when a multiplication leaves 379.49999999999994. */
const whole = (seconds: number): number => Math.round(Number(seconds.toFixed(6)));

function range(minPace: number, maxPace: number): PaceRange {
  const min = Math.min(Math.max(whole(minPace), MIN_PACE), MAX_PACE - 1);
  const max = Math.min(Math.max(whole(maxPace), min + 1), MAX_PACE);
  return { minSecPerKm: min, maxSecPerKm: max };
}

function clock(totalSec: number): string {
  const t = Math.round(totalSec);
  const h = Math.floor(t / 3600);
  const m = Math.floor((t % 3600) / 60);
  const s = t % 60;
  const ss = String(s).padStart(2, "0");
  return h > 0 ? `${h}:${String(m).padStart(2, "0")}:${ss}` : `${m}:${ss}`;
}

function distanceLabel(distanceM: number): string {
  if (distanceM === 5000) return "5K";
  if (distanceM === 10000) return "10K";
  if (distanceM === 21097 || distanceM === 21098) return "Half marathon";
  return `${Number((distanceM / 1000).toFixed(1))}K`;
}

function dayNumber(date: string): number {
  const ms = Date.parse(`${date}T00:00:00Z`);
  if (!/^\d{4}-\d{2}-\d{2}$/.test(date) || Number.isNaN(ms)) throw new RangeError(`not a calendar date: "${date}"`);
  return ms / 86_400_000;
}

/**
 * Pace ranges from a recent result. Without one, `{ source: "none" }`: callers use effort-based targets and prompt
 * for calibration after the first hard effort. A result older than six weeks still yields ranges, marked `estimated`.
 */
export function derivePaces(input: { recentResult?: RecentResult; today: string }): DerivedPaces {
  const result = input.recentResult;
  if (!result) return { source: "none" };
  if (!(result.distanceM >= 1000 && result.distanceM <= 42195) || !(result.timeSec >= 120 && result.timeSec <= 28800)) {
    throw new RangeError("recent result is outside 1 to 42.195 km and 2 minutes to 8 hours");
  }
  const impliedPace = result.timeSec / (result.distanceM / 1000);
  if (impliedPace < MIN_RESULT_PACE || impliedPace > MAX_PACE) {
    throw new RangeError(`recent result implies ${Math.round(impliedPace)} s per km, which is not a real run`);
  }

  const p5 = pacePerKm(result, 5000);
  const p10 = pacePerKm(result, 10000);
  const p3 = pacePerKm(result, 3000);

  const label = `${distanceLabel(result.distanceM)} in ${clock(result.timeSec)}`;
  const ageDays = result.date === undefined ? 0 : dayNumber(input.today) - dayNumber(result.date);
  if (ageDays < 0) throw new RangeError(`recent result is dated ${result.date}, after today (${input.today})`);
  const stale = ageDays > STALE_AFTER_DAYS;
  const basedOn = result.date ? `${label} on ${result.date}${stale ? ", more than 6 weeks ago" : ""}` : label;

  return {
    source: stale ? "estimated" : "race",
    basedOn,
    easy: range(p5 * EASY[0], p5 * EASY[1]),
    long: range(p5 * LONG[0], p5 * LONG[1]),
    tempo: range(p10 * TEMPO[0], p10 * TEMPO[1]),
    interval: range(p3, p5),
  };
}

/** A heart-rate range for a kind of running, only from what the user supplied; never inferred (§6.3). */
export function heartRateRange(settings: HeartRateSettings | undefined, zone: Zone): HeartRateRange | undefined {
  const zones = settings?.zones;
  if (zones && zones.length === 5) return zones[HR_ZONE_INDEX[zone]];
  const max = settings?.maxBpm;
  if (max === undefined) return undefined;
  const [low, high] = HR_BANDS[zone];
  return { minBpm: Math.round(max * low), maxBpm: Math.round(max * high) };
}

/**
 * What kind of target the plan can show. The user's display choice wins when we can honour it: pace needs paces,
 * heart rate needs data they gave us. Otherwise effort, which always works.
 */
export function resolveTargetKind(input: {
  display?: TargetKind;
  paces: DerivedPaces;
  heartRate?: HeartRateSettings;
}): TargetKind {
  const display = input.display ?? "pace";
  if (display === "pace" && input.paces.source !== "none") return "pace";
  if (display === "heart_rate" && (input.heartRate?.maxBpm !== undefined || input.heartRate?.zones?.length === 5)) {
    return "heart_rate";
  }
  return "effort";
}
