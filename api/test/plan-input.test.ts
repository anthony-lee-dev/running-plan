import { describe, expect, it } from "vitest";
import { canonicalHash } from "../src/domain/plan-hash";
import { parsePlanCreate, parsePlanUpdate, parseSessionCreate, parseSessionUpdate, type SessionType } from "../src/domain/plan-input";

const P = "00000000-0000-4000-8000-0000000000a1";
const S = "00000000-0000-4000-8000-0000000000b1";

const session = (over: Record<string, unknown> = {}) => ({
  id: S,
  date: "2026-11-03",
  type: "easy",
  steps: [{ kind: "work", goal: { type: "distance", value: 5000 }, target: { type: "effort", effort: "easy" } }],
  ...over,
});
const plan = (over: Record<string, unknown> = {}) => ({
  id: P,
  goal: { type: "5k", date: "2027-01-10" },
  startDate: "2026-11-02",
  weekCount: 10,
  source: "rules",
  engine: { presetId: "5k", version: "1.0.0" },
  adaptive: true,
  weeks: [{ index: 0, phase: "base" }],
  sessions: [session()],
  ...over,
});

const pathsOf = (r: { ok: boolean; errors?: { path: string }[] }) => (r.ok ? [] : r.errors!.map((e) => e.path).sort());

describe("parsePlanCreate", () => {
  it("accepts a rules plan and fills session defaults", () => {
    const r = parsePlanCreate(plan());
    expect(r.ok).toBe(true);
    if (r.ok) expect(r.value.sessions[0]).toMatchObject({ status: "planned", owner: "system" });
  });

  it("accepts a blank plan with no engine and no sessions", () => {
    expect(parsePlanCreate(plan({ source: "blank", engine: undefined, adaptive: false, sessions: [], weeks: [] })).ok).toBe(true);
  });

  it.each([
    ["no id", plan({ id: undefined }), ["/id"]],
    ["a bad id", plan({ id: "nope" }), ["/id"]],
    ["an unknown field", plan({ extra: 1 }), ["/extra"]],
    ["a bad goal type", plan({ goal: { type: "marathon" } }), ["/goal/type"]],
    ["a goal target time below 60 s", plan({ goal: { type: "5k", targetTimeSec: 30 } }), ["/goal/targetTimeSec"]],
    ["a bad start date", plan({ startDate: "2026-13-01" }), ["/startDate"]],
    ["53 weeks", plan({ weekCount: 53 }), ["/weekCount"]],
    ["0 weeks", plan({ weekCount: 0 }), ["/weekCount"]],
    ["a bad source", plan({ source: "magic" }), ["/source"]],
    ["a rules plan with no engine", plan({ engine: undefined }), ["/engine"]],
    ["a blank plan with an engine", plan({ source: "blank" }), ["/engine"]],
    ["adaptive not a boolean", plan({ adaptive: "yes" }), ["/adaptive"]],
    ["a week index at or past the week count", plan({ weekCount: 2, weeks: [{ index: 2 }] }), ["/weeks/0/index"]],
    ["a repeated week index", plan({ weeks: [{ index: 0 }, { index: 0 }] }), ["/weeks/1/index"]],
    ["a bad phase", plan({ weeks: [{ index: 0, phase: "rest" }] }), ["/weeks/0/phase"]],
    ["too many sessions", plan({ sessions: Array.from({ length: 401 }, (_, i) => session({ id: `00000000-0000-4000-8000-${String(i).padStart(12, "0")}` })) }), ["/sessions"]],
    ["a session outside the plan", plan({ sessions: [session({ date: "2026-10-01" })] }), ["/sessions/0/date"]],
    ["a repeated session id", plan({ sessions: [session(), session()] }), ["/sessions/1/id"]],
    ["an invalid session", plan({ sessions: [session({ type: "sprint" })] }), ["/sessions/0/type"]],
  ])("rejects %s", (_name, body, paths) => {
    expect(pathsOf(parsePlanCreate(body))).toEqual(paths);
  });

  it("reports every problem at once", () => {
    expect(pathsOf(parsePlanCreate(plan({ weekCount: 99, source: "x" })))).toEqual(["/source", "/weekCount"]);
  });

  it("rejects a body that is not an object", () => {
    expect(parsePlanCreate([]).ok).toBe(false);
    expect(parsePlanCreate(null).ok).toBe(false);
  });
});

describe("parseSessionCreate", () => {
  const span = { startDate: "2026-11-02", weekCount: 4 };
  const ok = (body: unknown) => parseSessionCreate(body, span);

  it("accepts easy, strength and custom sessions", () => {
    expect(ok(session()).ok).toBe(true);
    expect(ok(session({ type: "strength", steps: [{ kind: "exercise", exerciseId: "goblet-squat", sets: 3, reps: 10, restSec: 60, effort: "moderate", loadNote: "12 kg" }] })).ok).toBe(true);
    expect(ok(session({ type: "custom", steps: [], custom: { activityLabel: "cycling", goal: { type: "time", value: 3600 }, effort: "hard" } })).ok).toBe(true);
  });

  it("accepts a repeat group", () => {
    const steps = [
      { kind: "warmup", goal: { type: "time", value: 600 } },
      { kind: "repeat", count: 4, steps: [{ kind: "work", goal: { type: "distance", value: 400 }, target: { type: "pace", range: { minSecPerKm: 240, maxSecPerKm: 260 } } }, { kind: "recovery", goal: { type: "time", value: 90 } }] },
      { kind: "cooldown", goal: { type: "open" } },
    ];
    expect(ok(session({ type: "intervals", steps })).ok).toBe(true);
  });

  it.each([
    ["a time goal with no value", { steps: [{ kind: "work", goal: { type: "time" } }] }, ["/steps/0/goal/value"]],
    ["an open goal with a value", { steps: [{ kind: "work", goal: { type: "open", value: 5 } }] }, ["/steps/0/goal/value"]],
    ["a goal value of 0", { steps: [{ kind: "work", goal: { type: "distance", value: 0 } }] }, ["/steps/0/goal/value"]],
    ["a goal value over 200000", { steps: [{ kind: "work", goal: { type: "distance", value: 200001 } }] }, ["/steps/0/goal/value"]],
    ["an unknown step kind", { steps: [{ kind: "sprint", goal: { type: "open" } }] }, ["/steps/0/kind"]],
    ["an unknown step field", { steps: [{ kind: "work", goal: { type: "open" }, extra: 1 }] }, ["/steps/0/extra"]],
    ["a pace range that is backwards", { steps: [{ kind: "work", goal: { type: "open" }, target: { type: "pace", range: { minSecPerKm: 400, maxSecPerKm: 300 } } }] }, ["/steps/0/target"]],
    ["a heart rate target out of range", { steps: [{ kind: "work", goal: { type: "open" }, target: { type: "heart_rate", range: { minBpm: 20, maxBpm: 150 } } }] }, ["/steps/0/target"]],
    ["a repeat of 1", { steps: [{ kind: "repeat", count: 1, steps: [{ kind: "work", goal: { type: "open" } }] }] }, ["/steps/0/count"]],
    ["a nested repeat", { steps: [{ kind: "repeat", count: 2, steps: [{ kind: "repeat", count: 2, steps: [] }] }] }, ["/steps/0/steps/0/kind"]],
    ["an empty repeat", { steps: [{ kind: "repeat", count: 2, steps: [] }] }, ["/steps/0/steps"]],
    ["51 steps", { steps: Array.from({ length: 51 }, () => ({ kind: "work", goal: { type: "open" } })) }, ["/steps"]],
    ["an exercise step in a run session", { steps: [{ kind: "exercise", exerciseId: "plank", sets: 2 }] }, ["/steps/0/kind"]],
    ["a run step in a strength session", { type: "strength", steps: [{ kind: "work", goal: { type: "open" } }] }, ["/steps/0/kind"]],
    ["too many sets", { type: "strength", steps: [{ kind: "exercise", exerciseId: "plank", sets: 11 }] }, ["/steps/0/sets"]],
    ["custom details on a run", { custom: { effort: "easy" } }, ["/custom"]],
    ["steps on a custom session", { type: "custom", steps: [{ kind: "work", goal: { type: "open" } }] }, ["/steps"]],
    ["a long title", { title: "x".repeat(81) }, ["/title"]],
    ["long notes", { notes: "x".repeat(2001) }, ["/notes"]],
    ["a date outside the plan", { date: "2026-12-10" }, ["/date"]],
    ["a bad status", { status: "maybe" }, ["/status"]],
    ["a bad owner", { owner: "robot" }, ["/owner"]],
  ])("rejects %s", (_name, over, paths) => {
    expect(pathsOf(ok(session(over)))).toEqual(paths);
  });
});

describe("parseSessionUpdate", () => {
  const span = { startDate: "2026-11-02", weekCount: 4 };
  const ok = (body: unknown, type: SessionType = "easy") => parseSessionUpdate(body, span, type);

  it("accepts partial edits and reports whether only the status changed", () => {
    const status = ok({ status: "done" });
    expect(status.ok && status.onlyStatus).toBe(true);
    const date = ok({ date: "2026-11-05" });
    expect(date.ok && date.onlyStatus).toBe(false);
    const both = ok({ status: "skipped", notes: "sore" });
    expect(both.ok && both.onlyStatus).toBe(false);
  });

  it("accepts clear for optional fields", () => {
    const r = ok({ clear: ["title", "notes"] });
    expect(r.ok && r.value.clear).toEqual(["title", "notes"]);
  });

  it.each([
    ["an empty body", {}, ["/"]],
    ["an unknown field", { nope: 1 }, ["/nope"]],
    ["setting and clearing the same field", { title: "x", clear: ["title"] }, ["/clear"]],
    ["a bad clear field", { clear: ["date"] }, ["/clear/0"]],
    ["a repeated clear field", { clear: ["title", "title"] }, ["/clear"]],
    ["a date outside the plan", { date: "2027-02-01" }, ["/date"]],
    ["custom details for a run session", { custom: { effort: "easy" } }, ["/custom"]],
    ["a bad step", { steps: [{ kind: "work" }] }, ["/steps/0/goal"]],
  ])("rejects %s", (_name, body, paths) => {
    expect(pathsOf(ok(body))).toEqual(paths);
  });

  it("checks steps against the new type when the type changes", () => {
    expect(pathsOf(ok({ type: "strength", steps: [{ kind: "work", goal: { type: "open" } }] }))).toEqual(["/steps/0/kind"]);
    expect(ok({ type: "custom", custom: { effort: "hard" }, steps: [] }).ok).toBe(true);
  });
});

describe("parsePlanUpdate", () => {
  it("accepts goal, adaptive and week notes", () => {
    expect(parsePlanUpdate({ goal: { type: "10k" }, adaptive: false, weeks: [{ index: 1, notes: "down week" }] }, 10).ok).toBe(true);
  });
  it.each([
    ["an empty body", {}, ["/"]],
    ["an unknown field", { startDate: "2026-11-02" }, ["/startDate"]],
    ["a bad goal", { goal: { type: "x" } }, ["/goal/type"]],
    ["a week past the plan", { weeks: [{ index: 10 }] }, ["/weeks/0/index"]],
    ["long week notes", { weeks: [{ index: 0, notes: "x".repeat(1001) }] }, ["/weeks/0/notes"]],
  ])("rejects %s", (_name, body, paths) => {
    expect(pathsOf(parsePlanUpdate(body, 10))).toEqual(paths);
  });
});

describe("canonicalHash", () => {
  it("is the same whatever the key order and differs when anything changes", async () => {
    expect(await canonicalHash({ a: 1, b: { c: 2, d: [1, 2] } })).toBe(await canonicalHash({ b: { d: [1, 2], c: 2 }, a: 1 }));
    expect(await canonicalHash({ a: 1 })).not.toBe(await canonicalHash({ a: 2 }));
    expect(await canonicalHash({ a: [1, 2] })).not.toBe(await canonicalHash({ a: [2, 1] }));
    expect(await canonicalHash({ a: 1 })).toMatch(/^[0-9a-f]{64}$/);
  });
  it("ignores keys whose value is undefined", async () => {
    expect(await canonicalHash({ a: 1, b: undefined })).toBe(await canonicalHash({ a: 1 }));
  });
});
