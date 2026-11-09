import type { Activity, Session } from "./api/types";

export type Step = NonNullable<Session["steps"]>[number];

const distanceOf = (goal: { type: string; value?: number }): number => (goal.type === "distance" ? (goal.value ?? 0) : 0);

export function stepMetres(step: Step): number {
  if (step.kind === "repeat") return step.count * step.steps.reduce((sum, inner) => sum + distanceOf(inner.goal), 0);
  return step.kind === "exercise" ? 0 : distanceOf(step.goal);
}

/** Planned distance of a session in metres, 0 when its steps hold no distance. */
export const plannedMetres = (session: Session): number => (session.steps ?? []).reduce((sum, step) => sum + stepMetres(step), 0);

const mmss = (sec: number): string => {
  const whole = Math.round(sec);
  return `${Math.floor(whole / 60)}:${String(whole % 60).padStart(2, "0")}`;
};

/** The one pace range of a steady run: every work step shares it. Null when the session has repeats or no pace target. */
function steadyRange(session: Session): { min: number; max: number } | null {
  const ranges: { min: number; max: number }[] = [];
  for (const step of session.steps ?? []) {
    if (step.kind === "repeat") return null;
    if (step.kind === "work" && step.target?.type === "pace") ranges.push({ min: step.target.range.minSecPerKm, max: step.target.range.maxSecPerKm });
  }
  const first = ranges[0];
  return first && ranges.every((r) => r.min === first.min && r.max === first.max) ? first : null;
}

export type PlanLine = { label: string; planned: string; actual: string };
export type PlanVsActual = { lines: PlanLine[]; verdict?: string };

/** Plan vs actual for a matched run, in the words the iPhone uses. Distance, and pace for a steady easy or long run. */
export function planVsActual(session: Session, run: Activity): PlanVsActual {
  const lines: PlanLine[] = [];
  let verdict: string | undefined;
  const isRun = session.type === "easy" || session.type === "long" || session.type === "tempo" || session.type === "intervals";
  const planned = plannedMetres(session);
  const actual = run.distanceM ?? 0;
  if (isRun && planned > 0 && actual > 0) {
    lines.push({ label: "Distance", planned: `${(planned / 1000).toFixed(1)} km planned`, actual: `${(actual / 1000).toFixed(1)} km` });
  }
  const range = session.type === "easy" || session.type === "long" ? steadyRange(session) : null;
  if (range && actual > 0) {
    const paceSec = Math.round(run.durationSec / (actual / 1000));
    const name = session.type === "long" ? "long-run range" : "easy range";
    verdict = paceSec < range.min ? `Faster than your ${name}` : paceSec > range.max ? `Slower than your ${name}` : `In your ${name}`;
    lines.push({ label: "Pace", planned: `${mmss(range.min)}–${mmss(range.max)}/km target`, actual: `${mmss(paceSec)}/km` });
  }
  return { lines, verdict };
}
