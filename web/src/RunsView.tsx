import { useCallback, useEffect, useState } from "react";
import type { Api } from "./api/client";
import type { Activity, Session } from "./api/types";
import { planVsActual } from "./sessionMath";

export const pace = (secPerKm: number): string => {
  const whole = Math.round(secPerKm); // round first, so 359.6 s reads 6:00 and never 5:60
  return `${Math.floor(whole / 60)}:${String(whole % 60).padStart(2, "0")}/km`;
};

function clock(seconds: number): string {
  const h = Math.floor(seconds / 3600);
  const m = Math.floor((seconds % 3600) / 60);
  const s = seconds % 60;
  return h > 0 ? `${h}:${String(m).padStart(2, "0")}:${String(s).padStart(2, "0")}` : `${m}:${String(s).padStart(2, "0")}`;
}

/** The summary of one run. A stat the source did not record is left out, never shown as 0 or a dash. */
export function summaryOf(run: Activity): { label: string; value: string }[] {
  const stats = [{ label: "Time", value: clock(run.durationSec) }];
  if (run.distanceM !== undefined && run.distanceM > 0) {
    stats.unshift({ label: "Distance", value: `${(run.distanceM / 1000).toFixed(2)} km` });
    if (run.workoutType === "running") stats.push({ label: "Pace", value: pace(run.durationSec / (run.distanceM / 1000)) });
  }
  if (run.avgHeartRate !== undefined) stats.push({ label: "Avg heart rate", value: `${run.avgHeartRate} bpm` });
  if (run.maxHeartRate !== undefined) stats.push({ label: "Max heart rate", value: `${run.maxHeartRate} bpm` });
  if (run.elevationGainM !== undefined) stats.push({ label: "Elevation gain", value: `${run.elevationGainM} m` });
  return stats;
}

const limited = (run: Activity): boolean =>
  run.workoutType === "running" && (run.avgHeartRate === undefined || run.maxHeartRate === undefined || run.elevationGainM === undefined);

/** The session a matched run belongs to: undefined while loading, null when it is gone or the plan cannot be read. */
function useMatchedSession(api: Api, run: Activity, onSignedOut: () => void): Session | null | undefined {
  const sessionId = run.disposition === "matched" ? run.match?.sessionId : undefined;
  const [found, setFound] = useState<Session | null | undefined>(sessionId ? undefined : null);
  useEffect(() => {
    if (!sessionId) return setFound(null);
    let cancelled = false;
    setFound(undefined);
    (async () => {
      try {
        const newest = (await api.listPlans())[0];
        const plan = newest ? await api.getPlan(newest.id) : undefined;
        const session = plan?.sessions.find((s) => s.id === sessionId && !s.deletedAt) ?? null;
        if (!cancelled) setFound(session);
      } catch (e) {
        if ((e as { status?: number }).status === 401) return onSignedOut();
        if (!cancelled) setFound(null); // the summary stands on its own
      }
    })();
    return () => {
      cancelled = true;
    };
  }, [api, sessionId, onSignedOut]);
  return found;
}

function RunDetail({ api, run, onBack, onSignedOut }: { api: Api; run: Activity; onBack: () => void; onSignedOut: () => void }) {
  const session = useMatchedSession(api, run, onSignedOut);
  const compared = session ? planVsActual(session, run) : undefined;
  return (
    <section className="card" aria-label="Run details">
      <button type="button" className="text" onClick={onBack}>Back to runs</button>
      <h2>{run.localDate}</h2>
      <p className="muted">
        {run.sourceApp ?? "Apple Health"} · {run.disposition !== "matched" ? "Not part of a plan" : session ? `Matched · ${session.title ?? session.type}` : "Matched to a session"}
      </p>
      <dl>
        {summaryOf(run).map((s) => (
          <div key={s.label}>
            <dt className="muted">{s.label}</dt>
            <dd>{s.value}</dd>
          </div>
        ))}
      </dl>
      {compared && compared.lines.length > 0 && (
        <section aria-label="Plan vs actual">
          <h3>Plan vs actual</h3>
          <dl>
            {compared.lines.map((l) => (
              <div key={l.label}>
                <dt className="muted">{l.label}</dt>
                <dd>
                  <span>{l.planned}</span> → <span>{l.actual}</span>
                </dd>
              </div>
            ))}
          </dl>
          {compared.verdict && <p>{compared.verdict}</p>}
        </section>
      )}
      {run.disposition === "matched" && session === null && <p className="muted">Matched to a session no longer in your plan.</p>}
      {limited(run) && <p className="muted">Limited data from {run.sourceApp ?? "Apple Health"}: the stats it didn't record are left out.</p>}
      <p className="muted">Splits and heart-rate zones are in the iPhone app.</p>
    </section>
  );
}

/** Every imported run, newest first, each opening a summary. Splits, zones and routes stay on the phone. */
export function RunsView({ api, onSignedOut }: { api: Api; onSignedOut: () => void }) {
  const [runs, setRuns] = useState<Activity[] | undefined>();
  const [error, setError] = useState<string | undefined>();
  const [openId, setOpenId] = useState<string | undefined>();

  const load = useCallback(async () => {
    setError(undefined);
    try {
      setRuns(await api.listActivities());
    } catch (e) {
      if ((e as { status?: number }).status === 401) return onSignedOut();
      setError("We couldn't load your runs. Please try again.");
    }
  }, [api, onSignedOut]);
  useEffect(() => void load(), [load]);

  if (runs === undefined) {
    return error ? (
      <section className="card">
        <p role="alert" className="error">{error}</p>
        <button type="button" onClick={() => void load()}>Try again</button>
      </section>
    ) : (
      <p className="muted">Loading your runs…</p>
    );
  }
  if (runs.length === 0) {
    return (
      <section className="card">
        <h2>No runs yet</h2>
        <p className="muted">Import runs in the iPhone app and they will appear here.</p>
      </section>
    );
  }
  const open = runs.find((r) => r.id === openId);
  if (open) return <RunDetail api={api} run={open} onBack={() => setOpenId(undefined)} onSignedOut={onSignedOut} />;
  return (
    <section>
      <h2>Runs</h2>
      {runs.length >= 100 && <p className="muted">Showing your latest 100 runs.</p>}
      <ul className="sessions">
        {runs.map((r) => (
          <li key={r.id} className="session">
            <button type="button" className="text" aria-label={`Open run: ${r.localDate}`} onClick={() => setOpenId(r.id)}>
              <strong>{r.localDate}</strong>
              <span className="muted"> · {r.distanceM ? `${(r.distanceM / 1000).toFixed(1)} km · ` : ""}{clock(r.durationSec)}</span>
            </button>
            {r.disposition === "matched" && <span className="badge">Matched</span>}
          </li>
        ))}
      </ul>
    </section>
  );
}
