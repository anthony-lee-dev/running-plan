import { render, screen, waitFor, within } from "@testing-library/react";
import userEvent from "@testing-library/user-event";
import { describe, expect, it, vi } from "vitest";
import { App } from "./App";
import { ApiError, type Api } from "./api/client";
import type { PlanDetail, PlanSummary, Session, SessionWriteResult } from "./api/types";

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
