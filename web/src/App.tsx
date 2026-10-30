import { useCallback, useState } from "react";
import type { Api } from "./api/client";
import { PlanView } from "./PlanView";
import { SignIn } from "./SignIn";

type Tab = "plan" | "progress";

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
          {(["plan", "progress"] as const).map((t) => (
            <button key={t} aria-current={tab === t ? "page" : undefined} className={tab === t ? "active" : ""} onClick={() => setTab(t)}>
              {t === "plan" ? "Plan" : "Progress"}
            </button>
          ))}
        </nav>
        <button type="button" className="text" onClick={() => { api.signOut(); setSignedIn(false); }}>Sign out</button>
      </header>
      <main>
        {tab === "plan" ? (
          <PlanView api={api} onSignedOut={signedOut} />
        ) : (
          <section className="card">
            <h2>Progress</h2>
            <p className="muted">Progress is not available yet. It arrives once the server can calculate it; nothing here is estimated in the meantime.</p>
          </section>
        )}
      </main>
    </div>
  );
}
