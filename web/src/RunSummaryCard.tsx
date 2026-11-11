import { useCallback, useEffect, useRef, useState } from "react";
import type { Api } from "./api/client";
import type { Activity, Profile, RunSummary } from "./api/types";
import { localToday } from "./runTotals";

/**
 * The written summary of a run (issue #132). Shows what the server has at once (stored AI text, or the template), asks for the AI
 * text once when the server says it can, and swaps it in. Any failure leaves what is already shown: the card never errors at the
 * user. No refresh button: the text changes only when the run's data does.
 */
export function RunSummaryCard({ api, run, onSignedOut }: { api: Api; run: Activity; onSignedOut: () => void }) {
  const [summary, setSummary] = useState<RunSummary | undefined>();
  const [profile, setProfile] = useState<Profile | undefined>();
  const [switching, setSwitching] = useState(false);
  const asked = useRef<string | undefined>(undefined);
  const [reload, setReload] = useState(0);

  useEffect(() => {
    let cancelled = false;
    const quiet = (e: unknown) => {
      if ((e as { status?: number }).status === 401) onSignedOut();
    };
    (async () => {
      try {
        const today = localToday();
        const first = await api.getRunSummary(run.id, today);
        if (cancelled) return;
        setSummary(first);
        // One ask per run and reload, even if the card re-renders.
        const key = `${run.id}:${reload}`;
        if (first.canGenerate && asked.current !== key) {
          asked.current = key;
          try {
            const written = await api.generateRunSummary(run.id, today);
            if (!cancelled) setSummary(written);
          } catch (e) {
            quiet(e); // a 429 or a failure keeps the template that is already shown
          }
        }
      } catch (e) {
        quiet(e);
      }
    })();
    api.getProfile().then((p) => !cancelled && setProfile(p)).catch(quiet);
    return () => {
      cancelled = true;
    };
  }, [api, run.id, reload, onSignedOut]);

  const setAi = useCallback(
    async (on: boolean) => {
      if (!profile) return;
      setSwitching(true);
      try {
        setProfile(await api.setAiSummaries(on, profile.revision));
        setReload((n) => n + 1);
      } catch (e) {
        if ((e as { status?: number }).status === 401) onSignedOut();
        else if ((e as { status?: number }).status === 409) setReload((n) => n + 1); // the profile moved: reload it and let the user retry
      } finally {
        setSwitching(false);
      }
    },
    [api, profile, onSignedOut],
  );

  if (!summary) return null;
  const aiOn = profile?.aiSummaries !== false;
  return (
    <section aria-label="Run summary">
      <h3>Summary</h3>
      <p aria-live="polite">{summary.text}</p>
      {summary.nextStep && (summary.pain ? <p className="notice">{summary.nextStep}</p> : <p className="muted">{summary.nextStep}</p>)}
      {summary.source === "ai" && <p className="muted">Generated summary</p>}
      {profile && (
        <button type="button" className="text" disabled={switching} onClick={() => void setAi(!aiOn)}>
          {aiOn ? "Turn off AI run summaries" : "Turn on AI run summaries"}
        </button>
      )}
    </section>
  );
}
