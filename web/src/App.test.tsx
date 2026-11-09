import { render, screen, waitFor, within } from "@testing-library/react";
import userEvent from "@testing-library/user-event";
import { describe, expect, it, vi } from "vitest";
import { App } from "./App";
import { pace } from "./RunsView";
import { ApiError, type Api } from "./api/client";
import { planVsActual } from "./sessionMath";
import type { Activity, PlanDetail, PlanSummary, Session, SessionWriteResult } from "./api/types";

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

describe("progress and signing out", () => {
  it("says progress is not here yet instead of showing made-up numbers", async () => {
    render(<App api={fakeApi()} />);
    await userEvent.click(await screen.findByRole("button", { name: /progress/i }));
    expect(screen.getByText(/not available yet/i)).toBeInTheDocument();
  });

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
