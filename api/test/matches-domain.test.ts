import { describe, expect, it } from "vitest";
import { planMatchChange, type MatchState } from "../src/domain/matches";

const NOW = "2026-10-29T09:00:00.000Z";
const S1 = "00000000-0000-4000-8000-000000000201";
const S2 = "00000000-0000-4000-8000-000000000202";
const A1 = "00000000-0000-4000-8000-000000000901";
const A2 = "00000000-0000-4000-8000-000000000902";
const P = "00000000-0000-4000-8000-000000000101";

const state = (over: Partial<MatchState> = {}): MatchState => ({
  sessions: [
    { id: S1, planId: P, status: "planned", revision: 1 },
    { id: S2, planId: P, status: "planned", revision: 1 },
  ],
  activities: [
    { id: A1, disposition: "inbox", revision: 1 },
    { id: A2, disposition: "inbox", revision: 1 },
  ],
  matches: [],
  ...over,
});

describe("planMatchChange", () => {
  it("confirming links the activity and marks the session done", () => {
    const fx = planMatchChange(state(), { kind: "put", sessionId: S1, activityId: A1, status: "confirmed" }, NOW);
    expect(fx).toEqual({
      removeMatches: [],
      putMatch: { sessionId: S1, activityId: A1, status: "confirmed", updatedAt: NOW },
      sessions: [{ id: S1, planId: P, status: "done", baseRevision: 1 }],
      activities: [{ id: A1, disposition: "matched", baseRevision: 1 }],
    });
  });

  it("a suggestion changes neither the session nor the inbox", () => {
    const fx = planMatchChange(state(), { kind: "put", sessionId: S1, activityId: A1, status: "suggested" }, NOW);
    expect(fx.sessions).toEqual([]);
    expect(fx.activities).toEqual([]);
    expect(fx.putMatch?.status).toBe("suggested");
  });

  it("matching an activity elsewhere moves it, and the session it left is planned again", () => {
    const s = state({
      sessions: [{ id: S1, planId: P, status: "done", revision: 2 }, { id: S2, planId: P, status: "planned", revision: 1 }],
      activities: [{ id: A1, disposition: "matched", revision: 2 }],
      matches: [{ sessionId: S1, activityId: A1, status: "confirmed", updatedAt: NOW }],
    });
    const fx = planMatchChange(s, { kind: "put", sessionId: S2, activityId: A1, status: "confirmed" }, NOW);
    expect(fx.removeMatches).toEqual([S1]);
    expect(fx.sessions).toEqual([
      { id: S1, planId: P, status: "planned", baseRevision: 2 },
      { id: S2, planId: P, status: "done", baseRevision: 1 },
    ]);
    expect(fx.activities).toEqual([]);
  });

  it("replacing a session's activity sends the old one back to the inbox", () => {
    const s = state({
      sessions: [{ id: S1, planId: P, status: "done", revision: 2 }],
      activities: [{ id: A1, disposition: "matched", revision: 2 }, { id: A2, disposition: "inbox", revision: 1 }],
      matches: [{ sessionId: S1, activityId: A1, status: "confirmed", updatedAt: NOW }],
    });
    const fx = planMatchChange(s, { kind: "put", sessionId: S1, activityId: A2, status: "confirmed" }, NOW);
    expect(fx.removeMatches).toEqual([S1]);
    expect(fx.sessions).toEqual([]);
    expect(fx.activities).toEqual([
      { id: A1, disposition: "inbox", baseRevision: 2 },
      { id: A2, disposition: "matched", baseRevision: 1 },
    ]);
  });

  it("turning a confirmed match back into a suggestion makes the session planned again", () => {
    const s = state({
      sessions: [{ id: S1, planId: P, status: "done", revision: 2 }],
      activities: [{ id: A1, disposition: "matched", revision: 2 }],
      matches: [{ sessionId: S1, activityId: A1, status: "confirmed", updatedAt: NOW }],
    });
    const fx = planMatchChange(s, { kind: "put", sessionId: S1, activityId: A1, status: "suggested" }, NOW);
    expect(fx.sessions).toEqual([{ id: S1, planId: P, status: "planned", baseRevision: 2 }]);
    expect(fx.activities).toEqual([{ id: A1, disposition: "inbox", baseRevision: 2 }]);
  });

  it("re-confirming the same match changes nothing but the match time", () => {
    const s = state({
      sessions: [{ id: S1, planId: P, status: "done", revision: 2 }],
      activities: [{ id: A1, disposition: "matched", revision: 2 }],
      matches: [{ sessionId: S1, activityId: A1, status: "confirmed", updatedAt: NOW }],
    });
    const fx = planMatchChange(s, { kind: "put", sessionId: S1, activityId: A1, status: "confirmed" }, NOW);
    expect(fx.sessions).toEqual([]);
    expect(fx.activities).toEqual([]);
  });

  it("unlinking returns the activity to the inbox and a done session to planned", () => {
    const s = state({
      sessions: [{ id: S1, planId: P, status: "done", revision: 2 }],
      activities: [{ id: A1, disposition: "matched", revision: 2 }],
      matches: [{ sessionId: S1, activityId: A1, status: "confirmed", updatedAt: NOW }],
    });
    expect(planMatchChange(s, { kind: "delete", sessionId: S1 }, NOW)).toEqual({
      removeMatches: [S1],
      sessions: [{ id: S1, planId: P, status: "planned", baseRevision: 2 }],
      activities: [{ id: A1, disposition: "inbox", baseRevision: 2 }],
    });
  });

  it("unlinking a suggestion leaves the session alone", () => {
    const s = state({ matches: [{ sessionId: S1, activityId: A1, status: "suggested", updatedAt: NOW }] });
    expect(planMatchChange(s, { kind: "delete", sessionId: S1 }, NOW)).toEqual({ removeMatches: [S1], sessions: [], activities: [] });
  });

  it("marking a matched activity extra unlinks it first", () => {
    const s = state({
      sessions: [{ id: S1, planId: P, status: "done", revision: 2 }],
      activities: [{ id: A1, disposition: "matched", revision: 2 }],
      matches: [{ sessionId: S1, activityId: A1, status: "confirmed", updatedAt: NOW }],
    });
    expect(planMatchChange(s, { kind: "disposition", activityId: A1, disposition: "extra" }, NOW)).toEqual({
      removeMatches: [S1],
      sessions: [{ id: S1, planId: P, status: "planned", baseRevision: 2 }],
      activities: [{ id: A1, disposition: "extra", baseRevision: 2 }],
    });
  });

  it("a session marked skipped by hand is not reset by unlinking", () => {
    const s = state({
      sessions: [{ id: S1, planId: P, status: "skipped", revision: 3 }],
      activities: [{ id: A1, disposition: "matched", revision: 2 }],
      matches: [{ sessionId: S1, activityId: A1, status: "confirmed", updatedAt: NOW }],
    });
    expect(planMatchChange(s, { kind: "delete", sessionId: S1 }, NOW).sessions).toEqual([]);
  });
});
