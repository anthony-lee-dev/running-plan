import { useCallback, useEffect, useState } from "react";
import type { Api } from "./api/client";
import type { Activity, PlanDetail, Progress } from "./api/types";
import { pace } from "./format";
import { buckets, comparison, durationText, earliestShown, kilometres, localToday, planWeekLines, planWeekOf, type Period } from "./runTotals";

type Loaded = { runs: Activity[]; plan?: PlanDetail; progress?: Progress };

/**
 * Totals per week and month from the imported runs, and for a week how it stands against the plan (issue #137).
 * Everything is worked out here from the run summaries and the plan's own progress; nothing is estimated.
 */
export function ProgressView({ api, onSignedOut, today = localToday() }: { api: Api; onSignedOut: () => void; today?: string }) {
  const [loaded, setLoaded] = useState<Loaded | undefined>();
  const [error, setError] = useState<string | undefined>();
  const [period, setPeriod] = useState<Period>("week");

  const load = useCallback(async () => {
    setError(undefined);
    try {
      const runs = await api.listActivitiesSince(earliestShown(today));
      // The plan comparison is a bonus: a failure here (other than being signed out) leaves the totals standing alone.
      let plan: PlanDetail | undefined;
      let progress: Progress | undefined;
      try {
        const newest = (await api.listPlans())[0];
        plan = newest ? await api.getPlan(newest.id) : undefined;
        progress = plan ? await api.getProgress(plan.id, today) : undefined;
      } catch (e) {
        if ((e as { status?: number }).status === 401) throw e;
      }
      setLoaded({ runs, plan, progress });
    } catch (e) {
      if ((e as { status?: number }).status === 401) return onSignedOut();
      setError("We couldn't load your progress. Please try again.");
    }
  }, [api, onSignedOut, today]);
  useEffect(() => void load(), [load]);

  if (!loaded) {
    return error ? (
      <section className="card">
        <p role="alert" className="error">{error}</p>
        <button type="button" onClick={() => void load()}>Try again</button>
      </section>
    ) : (
      <p className="muted">Loading your progress…</p>
    );
  }

  const list = buckets(loaded.runs, today, period);
  const current = list[list.length - 1]!;
  const noun = period === "week" ? "week" : "month";
  const compared = comparison(list, period);
  const top = Math.max(...list.map((b) => b.distanceM), 0);
  const planWeek = period === "week" && loaded.plan ? planWeekOf(loaded.plan, loaded.progress, today) : undefined;

  return (
    <section className="card" aria-label="Your running">
      <h2>Your running</h2>
      <div role="group" aria-label="Period" className="actions">
        {(["week", "month"] as const).map((p) => (
          <button key={p} type="button" aria-pressed={period === p} className={period === p ? "active" : ""} onClick={() => setPeriod(p)}>
            {p === "week" ? "Week" : "Month"}
          </button>
        ))}
      </div>
      <h3>This {noun}</h3>
      <dl className="totals">
        <div><dt className="muted">Distance</dt><dd>{kilometres(current.distanceM)} km</dd></div>
        <div><dt className="muted">Time</dt><dd>{durationText(current.timeSec)}</dd></div>
        <div><dt className="muted">Runs</dt><dd>{current.runs}</dd></div>
        {current.paceSecPerKm !== undefined && <div><dt className="muted">Avg pace</dt><dd>{pace(current.paceSecPerKm)}</dd></div>}
      </dl>
      {current.runs === 0 ? <p className="muted">No runs yet this {noun}.</p> : compared && <p className="muted">{compared}</p>}
      <ol className="bars" aria-label={`Distance run per ${noun}`}>
        {list.map((b) => (
          <li key={b.first} aria-current={b.isCurrent ? "date" : undefined}>
            <span className="muted label">{b.label}</span>
            <span className="bar" role="img" aria-label={`${kilometres(b.distanceM)} km in ${b.runs} ${b.runs === 1 ? "run" : "runs"}`}>
              <span style={{ width: `${top > 0 ? Math.round((b.distanceM / top) * 100) : 0}%` }} />
            </span>
            <span className="value">{kilometres(b.distanceM)} km</span>
          </li>
        ))}
      </ol>
      {planWeek && (
        <section aria-label="Plan week" className="notice">
          <h3>{planWeek.title}</h3>
          {planWeekLines(planWeek).map((line) => <p key={line}>{line}</p>)}
          <p className="muted">Counts the runs matched to your sessions, so it can differ from this week's total.</p>
        </section>
      )}
    </section>
  );
}
