import fc from "fast-check";
import { describe, expect, it } from "vitest";
import { AUTO_MATCH_LIMIT, autoMatches, suggestSessions, type SuggestActivity, type SuggestSession } from "../src/domain/suggestions";

const run = (id: string, localDate: string, durationSec = 1800, workoutType: SuggestActivity["workoutType"] = "running"): SuggestActivity => ({ id, localDate, durationSec, workoutType });
const sess = (id: string, date: string, type: SuggestSession["type"] = "easy", minutes = 30): SuggestSession => ({
  id,
  date,
  type,
  steps: type === "strength" || type === "rest" || type === "custom" ? [] : [{ kind: "work", goal: { type: "time", value: minutes * 60 } }],
  ...(type === "custom" ? { custom: { goal: { type: "time" as const, value: minutes * 60 } } } : {}),
});

describe("suggestSessions", () => {
  it("suggests the planned run on the activity's local date", () => {
    expect(suggestSessions([run("a1", "2026-10-28")], [sess("s1", "2026-10-28"), sess("s2", "2026-10-29")])).toEqual(new Map([["a1", "s1"]]));
  });

  it("suggests nothing when no session is on that date", () => {
    expect(suggestSessions([run("a1", "2026-10-30")], [sess("s1", "2026-10-28")]).size).toBe(0);
  });

  it("matches by type: a run to a run session, strength to strength, cross-training to custom, never to rest", () => {
    const sessions = [sess("easy", "2026-10-28"), sess("str", "2026-10-28", "strength"), sess("cus", "2026-10-28", "custom"), sess("rest", "2026-10-28", "rest")];
    expect(suggestSessions([run("r", "2026-10-28")], sessions).get("r")).toBe("easy");
    expect(suggestSessions([run("t", "2026-10-28", 1800, "strength")], sessions).get("t")).toBe("str");
    expect(suggestSessions([run("c", "2026-10-28", 1800, "cycling")], sessions).get("c")).toBe("cus");
    expect(suggestSessions([run("w", "2026-10-28", 1800, "walking")], [sess("rest", "2026-10-28", "rest")]).size).toBe(0);
  });

  it("picks the session whose planned time is closest to the duration", () => {
    const sessions = [sess("short", "2026-10-28", "easy", 20), sess("long", "2026-10-28", "long", 90), sess("mid", "2026-10-28", "tempo", 40)];
    expect(suggestSessions([run("a", "2026-10-28", 85 * 60)], sessions).get("a")).toBe("long");
    expect(suggestSessions([run("a", "2026-10-28", 38 * 60)], sessions).get("a")).toBe("mid");
  });

  it("does not suggest a session far off in duration", () => {
    expect(suggestSessions([run("a", "2026-10-28", 10 * 60)], [sess("s", "2026-10-28", "long", 90)]).size).toBe(0);
  });

  it("still suggests a session with no computable planned time", () => {
    const open: SuggestSession = { id: "s", date: "2026-10-28", type: "easy", steps: [{ kind: "work", goal: { type: "open" } }] };
    expect(suggestSessions([run("a", "2026-10-28")], [open]).get("a")).toBe("s");
  });

  it("gives two runs on one day two different sessions, the better fit first", () => {
    const sessions = [sess("am", "2026-10-28", "easy", 30), sess("pm", "2026-10-28", "long", 90)];
    const got = suggestSessions([run("a1", "2026-10-28", 88 * 60), run("a2", "2026-10-28", 30 * 60)], sessions);
    expect(got).toEqual(new Map([["a1", "pm"], ["a2", "am"]]));
  });

  it("never suggests one session twice", () => {
    const got = suggestSessions([run("a1", "2026-10-28"), run("a2", "2026-10-28")], [sess("s", "2026-10-28")]);
    expect(got.size).toBe(1);
  });

  it("is the same whatever order the sessions come in", () => {
    const sessions = [sess("s1", "2026-10-28", "easy", 30), sess("s2", "2026-10-28", "easy", 30)];
    const acts = [run("a1", "2026-10-28"), run("a2", "2026-10-28")];
    expect(suggestSessions(acts, sessions)).toEqual(suggestSessions(acts, [...sessions].reverse()));
  });

  it("property: every suggestion is a distinct session on the activity's date, never a rest day", () => {
    const date = fc.constantFrom("2026-10-27", "2026-10-28", "2026-10-29");
    const types = fc.constantFrom<SuggestSession["type"]>("easy", "long", "intervals", "tempo", "strength", "rest", "custom");
    const acts = fc.array(
      fc.record({ localDate: date, durationSec: fc.integer({ min: 60, max: 20000 }), workoutType: fc.constantFrom<SuggestActivity["workoutType"]>("running", "strength", "cycling", "other") }),
      { maxLength: 8 },
    );
    const sessions = fc.array(fc.record({ date, type: types, minutes: fc.integer({ min: 5, max: 150 }) }), { maxLength: 8 });
    fc.assert(
      fc.property(acts, sessions, (as, ss) => {
        const activities = as.map((a, i) => ({ id: `a${i}`, ...a }));
        const candidates = ss.map((s, i) => sess(`s${i}`, s.date, s.type, s.minutes));
        const got = suggestSessions(activities, candidates);
        expect(new Set(got.values()).size).toBe(got.size);
        for (const [aid, sid] of got) {
          expect(activities.find((a) => a.id === aid)!.localDate).toBe(candidates.find((s) => s.id === sid)!.date);
          expect(candidates.find((s) => s.id === sid)!.type).not.toBe("rest");
        }
      }),
    );
  });
});

describe("autoMatches (issue #186)", () => {
  const D = "2026-10-28";
  const one = run("a1", D);

  it("matches the only waiting run of the day to the only planned session that fits", () => {
    expect(autoMatches([one], [one], [sess("s1", D), sess("s2", "2026-10-29")])).toEqual(new Map([["a1", "s1"]]));
  });

  it("leaves two runs on one day to the runner, also when the other was uploaded earlier", () => {
    const evening = run("a2", D, 1500);
    expect(autoMatches([one, evening], [one, evening], [sess("s1", D)]).size).toBe(0);
    expect(autoMatches([evening], [one, evening], [sess("s1", D)]).size).toBe(0);
  });

  it("leaves a day with two sessions that fit to the runner", () => {
    expect(autoMatches([one], [one], [sess("s1", D), sess("s2", D, "tempo", 40)]).size).toBe(0);
  });

  it("counts by kind: a strength workout the same day does not get in the way of the run", () => {
    const lift = run("a2", D, 1800, "strength");
    const sessions = [sess("s1", D), sess("str", D, "strength")];
    expect(autoMatches([one, lift], [one, lift], sessions)).toEqual(new Map([["a1", "s1"], ["a2", "str"]]));
  });

  it("does not match the wrong type, a day with no session, or a duration far from the plan", () => {
    expect(autoMatches([one], [one], [sess("str", D, "strength")]).size).toBe(0);
    expect(autoMatches([one], [one], [sess("s1", "2026-10-29")]).size).toBe(0);
    const short = run("a3", D, 10 * 60);
    expect(autoMatches([short], [short], [sess("s1", D, "long", 90)]).size).toBe(0);
  });

  it("only matches the activities it is asked about, and never across days", () => {
    const old = run("a0", "2026-10-27");
    expect(autoMatches([one], [old, one], [sess("s0", "2026-10-27"), sess("s1", D)])).toEqual(new Map([["a1", "s1"]]));
  });

  it("stops at the limit", () => {
    const days = Array.from({ length: AUTO_MATCH_LIMIT + 3 }, (_, i) => `2026-11-${String(i + 1).padStart(2, "0")}`);
    const runs = days.map((d, i) => run(`a${i}`, d));
    expect(autoMatches(runs, runs, days.map((d, i) => sess(`s${i}`, d))).size).toBe(AUTO_MATCH_LIMIT);
  });
});
