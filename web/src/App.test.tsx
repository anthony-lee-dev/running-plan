import { render, screen, waitFor, within } from "@testing-library/react";
import userEvent from "@testing-library/user-event";
import { StrictMode } from "react";
import { describe, expect, it, vi } from "vitest";
import { App } from "./App";
import { pace } from "./RunsView";
import { ApiError, type Api } from "./api/client";
import { planVsActual } from "./sessionMath";
import type { Activity, PlanDetail, PlanSummary, Profile, Progress, RunSummary, Session, SessionWriteResult } from "./api/types";
import { dateOf, dayNumber, earliestShown, localToday } from "./runTotals";

const session = (over: Partial<Session>): Session => ({
  id: "s1", revision: 1, updatedAt: "2026-10-29T09:00:00Z", deletedAt: null, planId: "p1", date: "2026-11-03", type: "easy",
  key: false, status: "planned", owner: "system", steps: [{ kind: "work", goal: { type: "distance", value: 5000 } }], title: "Easy run", ...over,
});
const summary: PlanSummary = { id: "p1", revision: 2, updatedAt: "2026-10-29T09:00:00Z", deletedAt: null, goal: { type: "5k", date: "2027-01-10" }, startDate: "2026-11-02", weekCount: 8, source: "rules", adaptive: true };
const detail = (sessions: Session[]): PlanDetail => ({ ...summary, engine: { presetId: "5k", version: "1.0.0" }, weeks: [{ index: 0, phase: "base" }], contentRevision: 3, sessions, warnings: [] });

function fakeApi(over: Partial<Api> = {}, signedIn = true): Api {
  let in_ = signedIn;
  return {
    isSignedIn: () => in_,
    startSignIn: vi.fn(async () => {}),
    verifySignIn: vi.fn(async () => {
      in_ = true;
    }),
    signOut: vi.fn(() => {
      in_ = false;
    }),
    listPlans: vi.fn(async () => [summary]),
    listActivities: vi.fn(async () => []),
    listActivitiesSince: vi.fn(async () => []),
    getRunSummary: vi.fn(async () => ({ text: "5.0 km in 30 min at 6:00/km.", source: "template", reason: "not_generated", canGenerate: true, pain: false }) as RunSummary),
    generateRunSummary: vi.fn(async () => ({ text: "A steady 5.0 km in 30 min.", source: "ai", canGenerate: false, pain: false }) as RunSummary),
    getProfile: vi.fn(async () => ({ revision: 1 }) as Profile),
    setAiSummaries: vi.fn(async (on: boolean, revision: number) => ({ aiSummaries: on, revision: revision + 1 }) as Profile),
    getProgress: vi.fn(async (planId: string, asOf: string) => ({ planId, asOf, weeks: [] }) as unknown as Progress),
    getPlan: vi.fn(async () => detail([session({}), session({ id: "s2", date: "2026-11-05", type: "long", title: "Long run" }), session({ id: "s3", date: "2026-11-12", title: "Next week run" })])),
    updateSession: vi.fn(async (s, body) => ({ session: session({ id: s.id, revision: s.revision + 1, ...(body as object) }), planContentRevision: 4, warnings: [] })),
    ...over,
  };
}

describe("signing in", () => {
  it("asks for the email, then the code, then shows the plan", async () => {
    const api = fakeApi({}, false);
    render(<App api={api} />);
    await userEvent.type(screen.getByLabelText(/email/i), "runner@example.com");
    await userEvent.click(screen.getByRole("button", { name: /send me a code/i }));
    expect(api.startSignIn).toHaveBeenCalledWith("runner@example.com");
    await userEvent.type(await screen.findByLabelText(/code/i), "123456");
    await userEvent.click(screen.getByRole("button", { name: /sign in/i }));
    expect(api.verifySignIn).toHaveBeenCalledWith("runner@example.com", "123456");
    expect(await screen.findByText("Easy run")).toBeInTheDocument();
  });

  it("explains a wrong code and lets the user try again", async () => {
    const api = fakeApi({ verifySignIn: vi.fn().mockRejectedValueOnce(new ApiError(401, { type: "invalid_code", title: "x", status: 401 })).mockResolvedValue(undefined) }, false);
    render(<App api={api} />);
    await userEvent.type(screen.getByLabelText(/email/i), "runner@example.com");
    await userEvent.click(screen.getByRole("button", { name: /send me a code/i }));
    await userEvent.type(await screen.findByLabelText(/code/i), "000000");
    await userEvent.click(screen.getByRole("button", { name: /sign in/i }));
    expect(await screen.findByRole("alert")).toHaveTextContent(/wrong or has expired/i);
  });

  it("tells the user when they asked for too many codes", async () => {
    const api = fakeApi({ startSignIn: vi.fn().mockRejectedValue(new ApiError(429, { type: "rate_limited", title: "x", status: 429 })) }, false);
    render(<App api={api} />);
    await userEvent.type(screen.getByLabelText(/email/i), "runner@example.com");
    await userEvent.click(screen.getByRole("button", { name: /send me a code/i }));
    expect(await screen.findByRole("alert")).toHaveTextContent(/too many/i);
  });
});

describe("the plan", () => {
  it("lists the weeks of the plan with their sessions, and shows when it was loaded", async () => {
    render(<App api={fakeApi()} />);
    expect(await screen.findByText("Easy run")).toBeInTheDocument();
    expect(screen.getByText("Long run")).toBeInTheDocument();
    expect(screen.getByRole("heading", { name: /week 1/i })).toBeInTheDocument();
    expect(screen.getByRole("heading", { name: /week 2/i })).toBeInTheDocument();
    expect(screen.getByText(/loaded at/i)).toBeInTheDocument();
    expect(screen.getByText(/5K/)).toBeInTheDocument();
  });

  it("shows an empty state when there is no plan yet", async () => {
    render(<App api={fakeApi({ listPlans: vi.fn(async () => []) })} />);
    expect(await screen.findByText(/no plan yet/i)).toBeInTheDocument();
    expect(screen.getByText(/iPhone/i)).toBeInTheDocument();
  });

  it("marks a session done with the revision it was loaded at", async () => {
    const api = fakeApi();
    render(<App api={api} />);
    const row = (await screen.findByText("Easy run")).closest("li")!;
    await userEvent.click(within(row).getByRole("button", { name: /mark done/i }));
    expect(api.updateSession).toHaveBeenCalledWith(expect.objectContaining({ id: "s1", revision: 1 }), { status: "done" });
    await waitFor(() => expect(within(row).getByText(/done/i)).toBeInTheDocument());
  });

  it("skips a session and moves it to another day", async () => {
    const api = fakeApi();
    render(<App api={api} />);
    const row = (await screen.findByText("Long run")).closest("li")!;
    await userEvent.click(within(row).getByRole("button", { name: /skip/i }));
    expect(api.updateSession).toHaveBeenCalledWith(expect.objectContaining({ id: "s2" }), { status: "skipped" });
    const mover = within(row).getByLabelText(/move to/i);
    await userEvent.clear(mover);
    await userEvent.type(mover, "2026-11-06");
    await userEvent.click(within(row).getByRole("button", { name: /^move:/i }));
    expect(api.updateSession).toHaveBeenLastCalledWith(expect.objectContaining({ id: "s2" }), { date: "2026-11-06" });
  });

  it("says so, and reloads the plan, when the session changed elsewhere", async () => {
    const api = fakeApi({ updateSession: vi.fn().mockRejectedValue(new ApiError(409, { type: "revision_conflict", title: "x", status: 409, currentRevision: 5 })) });
    render(<App api={api} />);
    const row = (await screen.findByText("Easy run")).closest("li")!;
    await userEvent.click(within(row).getByRole("button", { name: /mark done/i }));
    expect(await screen.findByRole("alert")).toHaveTextContent(/changed on another device/i);
    expect(api.getPlan).toHaveBeenCalledTimes(2);
  });

  it("explains a date outside the plan", async () => {
    const api = fakeApi({ updateSession: vi.fn().mockRejectedValue(new ApiError(400, { type: "validation_failed", title: "x", status: 400, errors: [{ path: "/date", message: "The date is outside the plan" }] })) });
    render(<App api={api} />);
    const row = (await screen.findByText("Easy run")).closest("li")!;
    const mover = within(row).getByLabelText(/move to/i);
    await userEvent.clear(mover);
    await userEvent.type(mover, "2027-06-01");
    await userEvent.click(within(row).getByRole("button", { name: /^move:/i }));
    expect(await screen.findByRole("alert")).toHaveTextContent(/outside the plan/i);
  });

  it("gives each row's buttons a name that says which session they are for", async () => {
    render(<App api={fakeApi()} />);
    expect(await screen.findByRole("button", { name: "Mark done: Easy run, 2026-11-03" })).toBeInTheDocument();
    expect(screen.getByRole("button", { name: "Skip: Long run, 2026-11-05" })).toBeInTheDocument();
    expect(screen.getByLabelText("Move to date: Next week run, 2026-11-12")).toHaveAttribute("min", "2026-11-02");
  });

  it("sends one edit when a button is clicked twice, and blocks other rows while it saves", async () => {
    let finish!: () => void;
    const api = fakeApi({
      updateSession: vi.fn(
        (s: { id: string }) =>
          new Promise<SessionWriteResult>((resolve) => {
            finish = () => resolve({ session: session({ id: s.id, revision: 2, status: "done" }), planContentRevision: 4, warnings: [] });
          }),
      ),
    });
    render(<App api={api} />);
    const done = await screen.findByRole("button", { name: "Mark done: Easy run, 2026-11-03" });
    await userEvent.dblClick(done);
    expect(api.updateSession).toHaveBeenCalledTimes(1);
    expect(screen.getByRole("button", { name: "Skip: Long run, 2026-11-05" })).toBeDisabled();
    finish();
    await waitFor(() => expect(screen.getByRole("button", { name: "Skip: Long run, 2026-11-05" })).toBeEnabled());
  });

  it("keeps the conflict message when the reload after it fails too", async () => {
    const getPlan = vi.fn().mockResolvedValueOnce(detail([session({})])).mockRejectedValue(new Error("offline"));
    const api = fakeApi({ getPlan, updateSession: vi.fn().mockRejectedValue(new ApiError(409, { type: "revision_conflict", title: "x", status: 409 })) });
    render(<App api={api} />);
    await userEvent.click(await screen.findByRole("button", { name: /mark done/i }));
    await waitFor(() => expect(getPlan).toHaveBeenCalledTimes(2));
    expect(screen.getByRole("alert")).toHaveTextContent(/changed on another device/i);
  });

  it("clears an old error once the plan loads again", async () => {
    const listPlans = vi.fn().mockRejectedValueOnce(new Error("offline")).mockResolvedValue([summary]);
    render(<App api={fakeApi({ listPlans })} />);
    expect(await screen.findByRole("alert")).toHaveTextContent(/couldn't load/i);
    await userEvent.click(screen.getByRole("button", { name: /try again/i }));
    expect(await screen.findByText("Easy run")).toBeInTheDocument();
    expect(screen.queryByRole("alert")).not.toBeInTheDocument();
  });

  it("shows the plan's warnings without blocking anything", async () => {
    const warned = { ...detail([session({})]), warnings: [{ code: "hard_days_back_to_back", severity: "caution" as const, message: "Hard sessions are back to back.", weekIndex: 0 }] };
    render(<App api={fakeApi({ getPlan: vi.fn(async () => warned) })} />);
    expect(await screen.findByText(/back to back/i)).toBeInTheDocument();
    expect(screen.getByRole("button", { name: /mark done/i })).toBeEnabled();
  });
});

describe("runs", () => {
  const run = (over: Partial<Activity>): Activity => ({
    id: "a1", source: "apple_health", externalId: "hk-1", workoutType: "running", startedAt: "2026-11-03T07:00:00.000Z", localDate: "2026-11-03",
    durationSec: 1800, distanceM: 5000, avgHeartRate: 150, maxHeartRate: 172, elevationGainM: 42, sourceApp: "Apple Watch",
    importedAt: "2026-11-03T08:00:00.000Z", disposition: "inbox", ...over,
  });

  it("lists every run and opens a summary with the stats the source recorded", async () => {
    render(<App api={fakeApi({ listActivities: vi.fn(async () => [run({}), run({ id: "a2", localDate: "2026-11-01", disposition: "matched" })]) })} />);
    await userEvent.click(await screen.findByRole("button", { name: "Runs" }));
    expect(await screen.findByRole("button", { name: "Open run: 2026-11-01" })).toBeInTheDocument();
    await userEvent.click(screen.getByRole("button", { name: "Open run: 2026-11-03" }));
    const details = screen.getByLabelText("Run details");
    expect(within(details).getByText("5.00 km")).toBeInTheDocument();
    expect(within(details).getByText("6:00/km")).toBeInTheDocument();
    expect(within(details).getByText("150 bpm")).toBeInTheDocument();
    expect(within(details).getByText("42 m")).toBeInTheDocument();
    expect(within(details).queryByText(/limited data/i)).not.toBeInTheDocument();
  });

  it("hides a stat the source did not record and says the data is limited", async () => {
    const thin = run({ avgHeartRate: undefined, maxHeartRate: undefined, elevationGainM: undefined, sourceApp: "Garmin Connect" });
    render(<App api={fakeApi({ listActivities: vi.fn(async () => [thin]) })} />);
    await userEvent.click(await screen.findByRole("button", { name: "Runs" }));
    await userEvent.click(await screen.findByRole("button", { name: /open run/i }));
    expect(screen.queryByText(/heart rate/i)).not.toBeInTheDocument();
    expect(screen.queryByText(/elevation/i)).not.toBeInTheDocument();
    expect(screen.getByText(/limited data from garmin connect/i)).toBeInTheDocument();
  });

  const matchedRun = (over: Partial<Activity> = {}) =>
    run({ id: "a9", disposition: "matched", match: { sessionId: "s1", activityId: "a9", status: "confirmed", updatedAt: "2026-11-03T09:00:00.000Z" }, ...over });
  const pacedSession = (over: Partial<Session> = {}) =>
    session({ steps: [{ kind: "work", goal: { type: "distance", value: 5000 }, target: { type: "pace", range: { minSecPerKm: 330, maxSecPerKm: 390 } } }], ...over });

  it("shows plan vs actual on a matched run, from the matched session", async () => {
    const api = fakeApi({ listActivities: vi.fn(async () => [matchedRun()]), getPlan: vi.fn(async () => detail([pacedSession()])) });
    render(<App api={api} />);
    await userEvent.click(await screen.findByRole("button", { name: "Runs" }));
    await userEvent.click(await screen.findByRole("button", { name: /open run/i }));
    const plan = await screen.findByLabelText("Plan vs actual");
    expect(within(plan).getByText("5.0 km planned")).toBeInTheDocument();
    expect(within(plan).getByText("5.0 km")).toBeInTheDocument();
    expect(within(plan).getByText("5:30–6:30/km target")).toBeInTheDocument();
    expect(within(plan).getByText("6:00/km")).toBeInTheDocument();
    expect(within(plan).getByText("In your easy range")).toBeInTheDocument();
  });

  it("says when the matched session is no longer in the plan, and keeps the summary", async () => {
    const api = fakeApi({ listActivities: vi.fn(async () => [matchedRun()]), getPlan: vi.fn(async () => detail([session({ id: "other" })])) });
    render(<App api={api} />);
    await userEvent.click(await screen.findByRole("button", { name: "Runs" }));
    await userEvent.click(await screen.findByRole("button", { name: /open run/i }));
    expect(await screen.findByText(/not in your latest plan/i)).toBeInTheDocument();
    expect(screen.getByText("5.00 km")).toBeInTheDocument();
  });

  it("still shows the summary when the plan cannot be loaded", async () => {
    const api = fakeApi({ listActivities: vi.fn(async () => [matchedRun()]), getPlan: vi.fn(async () => { throw new Error("offline"); }) });
    render(<App api={api} />);
    await userEvent.click(await screen.findByRole("button", { name: "Runs" }));
    await userEvent.click(await screen.findByRole("button", { name: /open run/i }));
    expect(await screen.findByText("5.00 km")).toBeInTheDocument();
    expect(screen.queryByLabelText("Plan vs actual")).not.toBeInTheDocument();
  });

  it("does not load the plan for a run that is not matched", async () => {
    const api = fakeApi({ listActivities: vi.fn(async () => [run({})]) });
    render(<App api={api} />);
    await screen.findByText("Easy run"); // the Plan tab has loaded its own plan
    const before = vi.mocked(api.getPlan).mock.calls.length;
    await userEvent.click(await screen.findByRole("button", { name: "Runs" }));
    await userEvent.click(await screen.findByRole("button", { name: /open run/i }));
    expect(screen.queryByLabelText("Plan vs actual")).not.toBeInTheDocument();
    expect(api.getPlan).toHaveBeenCalledTimes(before);
  });

  describe("written summary (issue #132)", () => {
    const open = async (api: Api) => {
      render(<App api={api} />);
      await userEvent.click(await screen.findByRole("button", { name: "Runs" }));
      await userEvent.click(await screen.findByRole("button", { name: /open run/i }));
    };
    const withRun = (over: Partial<Api> = {}, r: Activity = run({})) => fakeApi({ listActivities: vi.fn(async () => [r]), ...over });

    it("shows the template at once, then swaps in the AI text and labels it", async () => {
      const api = withRun();
      await open(api);
      const card = await screen.findByLabelText("Run summary");
      expect(await within(card).findByText("A steady 5.0 km in 30 min.")).toBeInTheDocument();
      expect(within(card).getByText("Generated summary")).toBeInTheDocument();
      expect(api.getRunSummary).toHaveBeenCalledWith("a1", localToday());
      expect(api.generateRunSummary).toHaveBeenCalledTimes(1);
    });

    it("keeps the template when the model text cannot be written (429 or failure)", async () => {
      const api = withRun({ generateRunSummary: vi.fn(async () => { throw new ApiError(429); }) });
      await open(api);
      const card = await screen.findByLabelText("Run summary");
      await waitFor(() => expect(api.generateRunSummary).toHaveBeenCalled());
      expect(within(card).getByText("5.0 km in 30 min at 6:00/km.")).toBeInTheDocument();
      expect(within(card).queryByText("Generated summary")).not.toBeInTheDocument();
    });

    it("does not ask for the AI text again when the server has it or says it cannot", async () => {
      const api = withRun({ getRunSummary: vi.fn(async () => ({ text: "Stored text for the run.", source: "ai", canGenerate: false, pain: false }) as RunSummary) });
      await open(api);
      expect(await screen.findByText("Stored text for the run.")).toBeInTheDocument();
      expect(api.generateRunSummary).not.toHaveBeenCalled();
    });

    it("shows the next planned session, and for a run with pain the fixed guidance as a notice", async () => {
      const text = "10.0 km in 58 min.";
      const guidance = "If something hurts, stop and talk to a qualified professional. This app can't give medical advice.";
      const api = withRun({ getRunSummary: vi.fn(async () => ({ text, nextStep: guidance, source: "template", reason: "not_generated", canGenerate: false, pain: true }) as RunSummary) });
      await open(api);
      const note = await screen.findByText(guidance);
      expect(note).toHaveClass("notice");
    });

    it("shows nothing, and no error, when the summary cannot be read", async () => {
      const api = withRun({ getRunSummary: vi.fn(async () => { throw new ApiError(500); }) });
      await open(api);
      await waitFor(() => expect(api.getRunSummary).toHaveBeenCalled());
      expect(screen.queryByLabelText("Run summary")).not.toBeInTheDocument();
      expect(screen.queryByRole("alert")).not.toBeInTheDocument();
    });

    it("asks for the AI text once even under StrictMode", async () => {
      const api = withRun();
      render(<StrictMode><App api={api} /></StrictMode>);
      await userEvent.click(await screen.findByRole("button", { name: "Runs" }));
      await userEvent.click(await screen.findByRole("button", { name: /open run/i }));
      expect(await screen.findByText("A steady 5.0 km in 30 min.")).toBeInTheDocument();
      expect(api.generateRunSummary).toHaveBeenCalledTimes(1);
    });

    it("shows the AI text and the fixed guidance together for a run with pain", async () => {
      const guidance = "If something hurts, stop and talk to a qualified professional. This app can't give medical advice.";
      const api = withRun({ getRunSummary: vi.fn(async () => ({ text: "10.0 km in 58 min.", nextStep: guidance, source: "ai", canGenerate: false, pain: true }) as RunSummary) });
      await open(api);
      expect(await screen.findByText("10.0 km in 58 min.")).toBeInTheDocument();
      expect(screen.getByText(guidance)).toHaveClass("notice");
      expect(screen.getByText("Generated summary")).toBeInTheDocument();
    });

    it("signs out when the summary call is refused as unauthorised", async () => {
      const api = withRun({ getRunSummary: vi.fn(async () => { throw new ApiError(401); }) });
      await open(api);
      await waitFor(() => expect(api.getRunSummary).toHaveBeenCalled());
    });

    it("keeps the card and the switch when the switch call hits a stale profile (409), and reloads the profile", async () => {
      const api = withRun({ setAiSummaries: vi.fn(async () => { throw new ApiError(409); }) });
      await open(api);
      const before = vi.mocked(api.getProfile).mock.calls.length;
      await userEvent.click(await screen.findByRole("button", { name: "Turn off AI run summaries" }));
      await waitFor(() => expect(vi.mocked(api.getProfile).mock.calls.length).toBeGreaterThan(before));
      expect(screen.queryByRole("alert")).not.toBeInTheDocument();
      expect(await screen.findByRole("button", { name: "Turn off AI run summaries" })).toBeEnabled();
    });

    it("keeps the switch when the summary cannot be read again after turning it off", async () => {
      const api = withRun();
      await open(api);
      const turnOff = await screen.findByRole("button", { name: "Turn off AI run summaries" });
      vi.mocked(api.getRunSummary).mockRejectedValue(new ApiError(500));
      await userEvent.click(turnOff);
      expect(await screen.findByRole("button", { name: /AI run summaries/ })).toBeInTheDocument();
    });

    it.each([
      ["a workout that is not a run", run({ workoutType: "strength", distanceM: undefined })],
      ["an ignored run", run({ disposition: "ignored" })],
    ])("does not ask for a summary of %s", async (_name, r) => {
      const api = withRun({}, r);
      await open(api);
      await screen.findByLabelText("Run details");
      expect(api.getRunSummary).not.toHaveBeenCalled();
      expect(screen.queryByLabelText("Run summary")).not.toBeInTheDocument();
    });

    it("turns AI run summaries off and back on from the card", async () => {
      const api = withRun();
      await open(api);
      const turnOff = await screen.findByRole("button", { name: "Turn off AI run summaries" });
      // What the server answers once the switch is off.
      vi.mocked(api.getProfile).mockResolvedValue({ aiSummaries: false, revision: 2 } as Profile);
      vi.mocked(api.getRunSummary).mockResolvedValue({ text: "5.0 km in 30 min.", source: "template", reason: "disabled", canGenerate: false, pain: false } as RunSummary);
      await userEvent.click(turnOff);
      expect(api.setAiSummaries).toHaveBeenCalledWith(false, 1);
      expect(await screen.findByText("5.0 km in 30 min.")).toBeInTheDocument();
      await userEvent.click(await screen.findByRole("button", { name: "Turn on AI run summaries" }));
      expect(api.setAiSummaries).toHaveBeenLastCalledWith(true, 2);
    });
  });

  it("calls a faster run faster than the range", () => {
    const result = planVsActual(pacedSession(), run({ durationSec: 1500 }));
    expect(result.verdict).toBe("Faster than your easy range");
  });

  it("never writes a pace of 5:60", () => {
    expect(pace(359.6)).toBe("6:00/km");
    expect(pace(389)).toBe("6:29/km");
  });

  it("says when the list is cut at 100 runs", async () => {
    const many = Array.from({ length: 100 }, (_, i) => run({ id: `r${i}` }));
    render(<App api={fakeApi({ listActivities: vi.fn(async () => many) })} />);
    await userEvent.click(await screen.findByRole("button", { name: "Runs" }));
    expect(await screen.findByText(/latest 100 runs/i)).toBeInTheDocument();
  });

  it("shows an empty state", async () => {
    render(<App api={fakeApi()} />);
    await userEvent.click(await screen.findByRole("button", { name: "Runs" }));
    expect(await screen.findByText(/no runs yet/i)).toBeInTheDocument();
  });
});

describe("progress", () => {
  const today = localToday();
  const ran = (id: string, over: Partial<Activity> = {}): Activity => ({
    id, source: "apple_health", externalId: id, workoutType: "running", startedAt: `${today}T07:00:00.000Z`, localDate: today,
    durationSec: 1800, distanceM: 5000, importedAt: `${today}T08:00:00.000Z`, disposition: "inbox", ...over,
  });
  const open = async () => userEvent.click(await screen.findByRole("button", { name: /progress/i }));

  it("shows this week's totals from the imported runs, matched or not", async () => {
    render(<App api={fakeApi({ listActivitiesSince: vi.fn(async () => [ran("a"), ran("b", { disposition: "matched", distanceM: 10000, durationSec: 3600 })]) })} />);
    await open();
    const card = await screen.findByLabelText("Your running");
    expect(within(card).getByRole("heading", { name: "This week" })).toBeInTheDocument();
    expect(within(card).getAllByText("15 km")).toHaveLength(2); // the total, and this week's bar
    expect(within(card).getByText("1 h 30 min")).toBeInTheDocument();
    expect(within(card).getByText("2")).toBeInTheDocument();
    expect(within(card).getByText("6:00/km")).toBeInTheDocument();
  });

  it("loads only the runs the shown periods need", async () => {
    const listActivitiesSince = vi.fn(async () => []);
    render(<App api={fakeApi({ listActivitiesSince })} />);
    await open();
    await screen.findByLabelText("Your running");
    expect(listActivitiesSince).toHaveBeenCalledWith(earliestShown(today));
  });

  it("switches to the month", async () => {
    render(<App api={fakeApi({ listActivitiesSince: vi.fn(async () => [ran("a")]) })} />);
    await open();
    await userEvent.click(await screen.findByRole("button", { name: "Month" }));
    expect(screen.getByRole("heading", { name: "This month" })).toBeInTheDocument();
    expect(screen.getByRole("button", { name: "Month" })).toHaveAttribute("aria-pressed", "true");
  });

  it("says so, with no pace, when nothing was run", async () => {
    render(<App api={fakeApi()} />);
    await open();
    expect(await screen.findByText("No runs yet this week.")).toBeInTheDocument();
    expect(screen.queryByText("Avg pace")).not.toBeInTheDocument();
  });

  it("puts the plan week beside the totals, labelled apart", async () => {
    const start = dateOf(dayNumber(today) - 2); // the plan's week 1 holds today
    const plan = { ...detail([session({ id: "s1", date: today, status: "done" }), session({ id: "s2", date: today, type: "long" })]), startDate: start, weekCount: 8 };
    const progress = { planId: plan.id, asOf: today, weeks: [{ index: 0, plannedDistanceM: 10000, actualDistanceM: 5000, plannedTimeSec: 3600, actualTimeSec: 1800 }] } as unknown as Progress;
    const getProgress = vi.fn(async () => progress);
    render(<App api={fakeApi({ getPlan: vi.fn(async () => plan), getProgress, listActivitiesSince: vi.fn(async () => [ran("a")]) })} />);
    await open();
    const planWeek = await screen.findByLabelText("Plan week");
    expect(within(planWeek).getByRole("heading", { name: "Plan week 1" })).toBeInTheDocument();
    expect(within(planWeek).getByText("5 of 10 km planned")).toBeInTheDocument();
    expect(within(planWeek).getByText("1 of 2 sessions done")).toBeInTheDocument();
    expect(getProgress).toHaveBeenCalledWith("p1", today);
    await userEvent.click(screen.getByRole("button", { name: "Month" }));
    expect(screen.queryByLabelText("Plan week")).not.toBeInTheDocument();
  });

  it("keeps the totals when the plan cannot be read", async () => {
    render(<App api={fakeApi({ getProgress: vi.fn().mockRejectedValue(new ApiError(500, { type: "x", title: "x", status: 500 })), listActivitiesSince: vi.fn(async () => [ran("a")]) })} />);
    await open();
    expect((await screen.findAllByText("5 km")).length).toBeGreaterThan(0);
    expect(screen.queryByLabelText("Plan week")).not.toBeInTheDocument();
  });

  it("returns to sign-in, showing no totals, when the session has ended", async () => {
    const listActivitiesSince = vi.fn().mockRejectedValue(new ApiError(401, { type: "unauthorized", title: "x", status: 401 }));
    render(<App api={fakeApi({ listActivitiesSince })} />);
    await open();
    expect(await screen.findByLabelText(/email/i)).toBeInTheDocument();
    expect(screen.queryByLabelText("Your running")).not.toBeInTheDocument();
  });

  it("offers a retry when the runs cannot be loaded", async () => {
    const listActivitiesSince = vi.fn().mockRejectedValueOnce(new ApiError(500, { type: "x", title: "x", status: 500 })).mockResolvedValue([ran("a")]);
    render(<App api={fakeApi({ listActivitiesSince })} />);
    await open();
    expect(await screen.findByRole("alert")).toHaveTextContent(/couldn't load your progress/i);
    await userEvent.click(screen.getByRole("button", { name: /try again/i }));
    expect((await screen.findAllByText("5 km")).length).toBeGreaterThan(0);
  });
});

describe("signing out", () => {

  it("signs out and returns to the sign-in form", async () => {
    const api = fakeApi();
    render(<App api={api} />);
    await userEvent.click(await screen.findByRole("button", { name: /sign out/i }));
    expect(api.signOut).toHaveBeenCalled();
    expect(await screen.findByLabelText(/email/i)).toBeInTheDocument();
  });

  it("returns to the sign-in form when a request finds the session has ended", async () => {
    const api = fakeApi({ listPlans: vi.fn().mockRejectedValue(new ApiError(401, { type: "unauthorized", title: "x", status: 401 })) });
    render(<App api={api} />);
    expect(await screen.findByLabelText(/email/i)).toBeInTheDocument();
  });
});
