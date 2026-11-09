import type { Activity, PlanDetail, Progress } from "./api/types";

// Totals per calendar week (Monday to Sunday) and month from the stored run summaries (issue #137). Same rules as the
// iPhone's RunTotals: bucket on the local date, count running workouts that are matched, in the inbox or extra, leave
// out ignored ones, and work pace out from the runs that have a distance.

export type Period = "week" | "month";
export const WEEKS_SHOWN = 8;
export const MONTHS_SHOWN = 6;
const MONTH_NAMES = ["Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"];

export interface Bucket {
  label: string;
  first: string;
  last: string;
  distanceM: number;
  timeSec: number;
  runs: number;
  /** Total time over total distance of the runs that have one; undefined when none does. */
  paceSecPerKm?: number;
  isCurrent: boolean;
}

const pad = (n: number, width = 2): string => String(n).padStart(width, "0");

/** Whole days since 1970-01-01 for a `YYYY-MM-DD` local date (no time zone involved). */
export function dayNumber(date: string): number {
  const [y, m, d] = date.split("-").map(Number);
  return Math.round(Date.UTC(y!, m! - 1, d!) / 86_400_000);
}

export function dateOf(day: number): string {
  const d = new Date(day * 86_400_000);
  return `${pad(d.getUTCFullYear(), 4)}-${pad(d.getUTCMonth() + 1)}-${pad(d.getUTCDate())}`;
}

/** The user's local date. Never `toISOString()`, which is the UTC date and wrong on an evening in the west. */
export function localToday(now: Date = new Date()): string {
  return `${pad(now.getFullYear(), 4)}-${pad(now.getMonth() + 1)}-${pad(now.getDate())}`;
}

const shortDate = (date: string): string => {
  const [, m, d] = date.split("-").map(Number);
  return `${MONTH_NAMES[m! - 1]} ${d}`;
};

function weekStarts(today: string): number[] {
  const day = dayNumber(today);
  const monday = day - ((((day + 3) % 7) + 7) % 7); // 1970-01-01 was a Thursday
  return Array.from({ length: WEEKS_SHOWN }, (_, i) => monday - 7 * (WEEKS_SHOWN - 1 - i));
}

function monthRanges(today: string): { label: string; first: string; last: string }[] {
  const [y, m] = today.split("-").map(Number);
  return Array.from({ length: MONTHS_SHOWN }, (_, i) => {
    const index = y! * 12 + (m! - 1) - (MONTHS_SHOWN - 1 - i);
    const year = Math.floor(index / 12);
    const month = (index % 12) + 1;
    const first = `${pad(year, 4)}-${pad(month)}-01`;
    const nextFirst = month === 12 ? `${pad(year + 1, 4)}-01-01` : `${pad(year, 4)}-${pad(month + 1)}-01`;
    return { label: MONTH_NAMES[month - 1]!, first, last: dateOf(dayNumber(nextFirst) - 1) };
  });
}

/** The oldest day any shown bucket starts on, so the page loads only the runs it needs. */
export function earliestShown(today: string): string {
  const weeks = dateOf(weekStarts(today)[0]!);
  const months = monthRanges(today)[0]!.first;
  return weeks < months ? weeks : months;
}

/** Oldest first; the last bucket holds today. */
export function buckets(activities: Activity[], today: string, period: Period): Bucket[] {
  const counted = activities.filter((a) => a.workoutType === "running" && a.disposition !== "ignored");
  const ranges =
    period === "week"
      ? weekStarts(today).map((start) => ({ label: shortDate(dateOf(start)), first: dateOf(start), last: dateOf(start + 6) }))
      : monthRanges(today);
  return ranges.map((range, index) => {
    const inside = counted.filter((a) => a.localDate >= range.first && a.localDate <= range.last);
    const withDistance = inside.filter((a) => (a.distanceM ?? 0) > 0);
    const distanceM = withDistance.reduce((sum, a) => sum + (a.distanceM ?? 0), 0);
    const paceTime = withDistance.reduce((sum, a) => sum + a.durationSec, 0);
    return {
      ...range,
      distanceM,
      timeSec: inside.reduce((sum, a) => sum + a.durationSec, 0),
      runs: inside.length,
      ...(distanceM > 0 ? { paceSecPerKm: Math.round(paceTime / (distanceM / 1000)) } : {}),
      isCurrent: index === ranges.length - 1,
    };
  });
}

/** Kilometres to one decimal, with no ".0": 10 km, 18.5 km. */
export const kilometres = (metres: number): string => {
  const km = Math.round(metres / 100) / 10;
  return Number.isInteger(km) ? String(km) : km.toFixed(1);
};

/** "45 min", "1 h 00 min": rounded to the minute. */
export function durationText(seconds: number): string {
  const minutes = Math.round(seconds / 60);
  return minutes < 60 ? `${minutes} min` : `${Math.floor(minutes / 60)} h ${pad(minutes % 60)} min`;
}

/** "2 km more than last week"; undefined when the period before had no run. */
export function comparison(list: Bucket[], period: Period): string | undefined {
  const current = list[list.length - 1];
  const previous = list[list.length - 2];
  if (!current || !previous || previous.runs === 0) return undefined;
  const noun = period === "week" ? "week" : "month";
  const difference = Math.round((current.distanceM - previous.distanceM) / 100) / 10;
  if (difference === 0) return `Same distance as last ${noun}`;
  return `${kilometres(Math.abs(difference) * 1000)} km ${difference > 0 ? "more" : "less"} than last ${noun}`;
}

export interface PlanWeek {
  plannedM: number;
  ranM: number;
  done: number;
  planned: number;
}

export const planWeekLines = (w: PlanWeek): string[] => [`${kilometres(w.ranM)} of ${kilometres(w.plannedM)} km planned`, `${w.done} of ${w.planned} sessions done`];

/** The plan week that holds `today`, against the plan; undefined before the plan starts, after it ends, or without a reply for it. */
export function planWeekOf(plan: PlanDetail, progress: Progress | undefined, today: string): ({ title: string } & PlanWeek) | undefined {
  if (!progress || progress.planId !== plan.id) return undefined;
  const index = Math.floor((dayNumber(today) - dayNumber(plan.startDate)) / 7);
  if (index < 0 || index >= plan.weekCount) return undefined;
  const week = progress.weeks.find((w) => w.index === index);
  if (!week) return undefined;
  const sessions = plan.sessions.filter((s) => !s.deletedAt && s.type !== "rest" && Math.floor((dayNumber(s.date) - dayNumber(plan.startDate)) / 7) === index);
  return {
    title: `Plan week ${index + 1}`,
    plannedM: week.plannedDistanceM,
    ranM: week.actualDistanceM,
    done: sessions.filter((s) => s.status === "done").length,
    planned: sessions.length,
  };
}
