import { useCallback, useState } from "react";
import type { Api } from "./api/client";
import { PlanView } from "./PlanView";
import { ProgressView } from "./ProgressView";
import { RunsView } from "./RunsView";
import { SignIn } from "./SignIn";

type Tab = "plan" | "runs" | "progress";
const LABEL: Record<Tab, string> = { plan: "Plan", runs: "Runs", progress: "Progress" };

export function App({ api }: { api: Api }) {
  const [signedIn, setSignedIn] = useState(api.isSignedIn());
  const [tab, setTab] = useState<Tab>("plan");
  const signedOut = useCallback(() => setSignedIn(false), []);

  if (!signedIn) return <SignIn api={api} onSignedIn={() => setSignedIn(true)} />;

  return (
    <div className="app">
      <header>
        <h1>Running Planner</h1>
        <nav aria-label="Sections">
          {(["plan", "runs", "progress"] as const).map((t) => (
            <button key={t} aria-current={tab === t ? "page" : undefined} className={tab === t ? "active" : ""} onClick={() => setTab(t)}>
              {LABEL[t]}
            </button>
          ))}
        </nav>
        <button type="button" className="text" onClick={() => { api.signOut(); setSignedIn(false); }}>Sign out</button>
      </header>
      <main>
        {tab === "plan" ? (
          <PlanView api={api} onSignedOut={signedOut} />
        ) : tab === "runs" ? (
          <RunsView api={api} onSignedOut={signedOut} />
        ) : (
          <ProgressView api={api} onSignedOut={signedOut} />
        )}
      </main>
    </div>
  );
}
