import { useCallback, useEffect, useState } from "react";
import { ApiError, type Api } from "./api/client";
import type { PlanDetail, Session } from "./api/types";

const STATUS_LABEL: Record<Session["status"], string> = { planned: "Planned", done: "Done", skipped: "Skipped" };

type Step = NonNullable<Session["steps"]>[number];

const distanceOf = (goal: { type: string; value?: number }): number => (goal.type === "distance" ? (goal.value ?? 0) : 0);

function stepMetres(step: Step): number {
  if (step.kind === "repeat") return step.count * step.steps.reduce((sum, inner) => sum + distanceOf(inner.goal), 0);
  return step.kind === "exercise" ? 0 : distanceOf(step.goal);
}

function describe(session: Session): string {
  const metres = (session.steps ?? []).reduce((sum, step) => sum + stepMetres(step), 0);
  return metres > 0 ? `${(metres / 1000).toFixed(1)} km` : session.type;
}

/** Whole weeks since the plan started, so sessions group the way the phone shows them. */
function weekOf(plan: PlanDetail, date: string): number {
  const days = (Date.parse(`${date}T00:00:00Z`) - Date.parse(`${plan.startDate}T00:00:00Z`)) / 86_400_000;
  return Math.max(0, Math.floor(days / 7)); // a session dated before the start still belongs to week 1
}

function errorMessage(error: unknown): string {
  if (error instanceof ApiError) {
    if (error.status === 409) return "This session changed on another device. We've reloaded the plan, so please try again.";
    const first = error.problem?.errors?.[0];
    if (error.status === 400 && first) return `${first.message}.`;
  }
  return "That didn't save. Please try again.";
}

type Edit = { status: Session["status"] } | { date: string };

function SessionRow({ session, minDate, busy, onEdit }: { session: Session; minDate: string; busy: boolean; onEdit: (session: Session, body: Edit) => Promise<void> }) {
  const [date, setDate] = useState(session.date);
  useEffect(() => setDate(session.date), [session.date]);
  const about = `${session.title ?? session.type}, ${session.date}`; // so a screen reader knows which row a button is for
  return (
    <li className={`session ${session.status}`}>
      <div>
        <strong>{session.title ?? session.type}</strong>
        <span className="muted"> · {session.date} · {describe(session)}</span>
        {session.owner === "user" && <span className="badge">Yours</span>}
        <span className="badge">{STATUS_LABEL[session.status]}</span>
      </div>
      <div className="actions">
        {session.status === "done" ? (
          <button type="button" disabled={busy} aria-label={`Mark planned: ${about}`} onClick={() => onEdit(session, { status: "planned" })}>Mark planned</button>
        ) : (
          <button type="button" disabled={busy} aria-label={`Mark done: ${about}`} onClick={() => onEdit(session, { status: "done" })}>Mark done</button>
        )}
        {session.status !== "skipped" && <button type="button" disabled={busy} aria-label={`Skip: ${about}`} onClick={() => onEdit(session, { status: "skipped" })}>Skip</button>}
        <label>
          Move to
          <input type="date" min={minDate} value={date} aria-label={`Move to date: ${about}`} onChange={(e) => setDate(e.target.value)} />
        </label>
        <button type="button" disabled={busy || date === session.date || date === ""} aria-label={`Move: ${about}`} onClick={() => onEdit(session, { date })}>Move</button>
      </div>
    </li>
  );
}

export function PlanView({ api, onSignedOut }: { api: Api; onSignedOut: () => void }) {
  const [plan, setPlan] = useState<PlanDetail | null | undefined>(undefined);
  const [loadedAt, setLoadedAt] = useState<Date>();
  const [error, setError] = useState<string>();
  const [busyId, setBusyId] = useState<string>();

  /** `quiet` is a reload after a conflict: it must not replace the conflict message, whether it works or not. */
  const load = useCallback(async (quiet = false) => {
    try {
      const plans = await api.listPlans();
      const newest = plans[0]; // newest first, as the API lists them
      setPlan(newest ? await api.getPlan(newest.id) : null);
      setLoadedAt(new Date());
      if (!quiet) setError(undefined);
    } catch (e) {
      if (e instanceof ApiError && e.status === 401) onSignedOut();
      else if (!quiet) setError("We couldn't load your plan. Please try again.");
    }
  }, [api, onSignedOut]);

  useEffect(() => {
    void load();
  }, [load]);

  async function edit(session: Session, body: Edit) {
    if (busyId) return; // one edit at a time: a second click would carry the same revision and conflict with itself
    setBusyId(session.id);
    setError(undefined);
    try {
      const result = await api.updateSession(session, body);
      setPlan((current) => current && { ...current, contentRevision: result.planContentRevision, warnings: result.warnings, sessions: current.sessions.map((s) => (s.id === result.session.id ? result.session : s)) });
    } catch (e) {
      if (e instanceof ApiError && e.status === 401) return onSignedOut();
      setError(errorMessage(e));
      if (e instanceof ApiError && e.status === 409) await load(true);
    } finally {
      setBusyId(undefined);
    }
  }

  if (plan === undefined) {
    return error ? (
      <section className="card">
        <p role="alert" className="error">{error}</p>
        <button type="button" onClick={() => void load()}>Try again</button>
      </section>
    ) : (
      <p className="muted">Loading your plan…</p>
    );
  }
  if (plan === null) {
    return (
      <section className="card">
        <h2>No plan yet</h2>
        <p className="muted">Set a goal in the iPhone app and your plan will appear here.</p>
      </section>
    );
  }

  const weeks = new Map<number, Session[]>();
  for (const s of [...plan.sessions].sort((a, b) => (a.date < b.date ? -1 : a.date > b.date ? 1 : 0))) {
    const w = weekOf(plan, s.date);
    weeks.set(w, [...(weeks.get(w) ?? []), s]);
  }

  return (
    <section>
      <h2>{plan.goal.type === "half_marathon" ? "Half marathon" : plan.goal.type.toUpperCase()} plan{plan.goal.date ? ` for ${plan.goal.date}` : ""}</h2>
      <p className="muted">Loaded at {loadedAt?.toLocaleTimeString()}. Edits here sync to your phone. Moving or editing a session makes it yours, and the plan engine leaves it alone; marking it done or skipped does not.</p>
      {error && <p role="alert" className="error">{error}</p>}
      {plan.warnings.length > 0 && (
        <aside className="notice" aria-label="Plan warnings">
          <strong>Heads up</strong>
          <ul>{plan.warnings.map((w, i) => <li key={`${w.code}-${i}`}>{w.message}</li>)}</ul>
        </aside>
      )}
      {[...weeks.entries()].sort(([a], [b]) => a - b).map(([index, sessions]) => (
        <div key={index}>
          <h3>Week {index + 1}{plan.weeks.find((w) => w.index === index)?.phase ? ` · ${plan.weeks.find((w) => w.index === index)!.phase}` : ""}</h3>
          <ul className="sessions">{sessions.map((s) => <SessionRow key={s.id} session={s} minDate={plan.startDate} busy={busyId !== undefined} onEdit={edit} />)}</ul>
        </div>
      ))}
    </section>
  );
}
