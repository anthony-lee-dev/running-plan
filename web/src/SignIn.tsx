import { useState, type FormEvent } from "react";
import { ApiError, type Api } from "./api/client";

function messageFor(error: unknown): string {
  if (error instanceof ApiError) {
    if (error.status === 429) return "Too many requests. Please wait a little and try again.";
    if (error.problem?.type === "invalid_code") return "That code is wrong or has expired. Check it or ask for a new one.";
    if (error.status === 400) return "Please check the email address and try again.";
  }
  return "Something went wrong. Please try again.";
}

export function SignIn({ api, onSignedIn }: { api: Api; onSignedIn: () => void }) {
  const [email, setEmail] = useState("");
  const [code, setCode] = useState("");
  const [step, setStep] = useState<"email" | "code">("email");
  const [error, setError] = useState<string>();
  const [busy, setBusy] = useState(false);

  async function submit(event: FormEvent) {
    event.preventDefault();
    setBusy(true);
    setError(undefined);
    try {
      if (step === "email") {
        await api.startSignIn(email.trim());
        setStep("code");
      } else {
        await api.verifySignIn(email.trim(), code.trim());
        onSignedIn();
      }
    } catch (e) {
      setError(messageFor(e));
    } finally {
      setBusy(false);
    }
  }

  return (
    <main className="card narrow">
      <h1>Running Planner</h1>
      <p className="muted">Adjust your plan from a bigger screen. Sign in with the email you use on your phone.</p>
      <form onSubmit={submit}>
        {step === "email" ? (
          <label>
            Email
            <input type="email" autoComplete="email" required value={email} onChange={(e) => setEmail(e.target.value)} />
          </label>
        ) : (
          <>
            <p className="muted">We sent a six digit code to {email}. It works for ten minutes.</p>
            <label>
              Code
              <input inputMode="numeric" autoComplete="one-time-code" pattern="[0-9]{6}" required value={code} onChange={(e) => setCode(e.target.value)} />
            </label>
          </>
        )}
        {error && <p role="alert" className="error">{error}</p>}
        <button className="primary" type="submit" disabled={busy}>
          {step === "email" ? "Send me a code" : "Sign in"}
        </button>
        {step === "code" && (
          <button type="button" className="text" onClick={() => { setStep("email"); setCode(""); setError(undefined); }}>
            Use a different email
          </button>
        )}
      </form>
    </main>
  );
}
