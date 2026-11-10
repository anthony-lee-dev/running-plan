import fc from "fast-check";
import { describe, expect, it } from "vitest";
import type { StoredActivity } from "../src/domain/activities";
import { allowedNumbers, buildRunFacts, formatDuration, formatPace, numbersIn, type RunFacts } from "../src/domain/run-facts";
import { nextStepLine, PAIN_GUIDANCE, templateParagraph } from "../src/domain/run-summary-text";
import { checkParagraph } from "../src/domain/summary-check";

let n = 0;
const run = (over: Partial<StoredActivity> = {}): StoredActivity => ({
  id: `a${++n}`,
  source: "apple_health",
  externalId: `e${n}`,
  workoutType: "running",
  startedAt: "2026-11-01T07:00:00-05:00",
  localDate: "2026-11-01",
  durationSec: 3480,
  distanceM: 10200,
  avgHeartRate: 152,
  disposition: "matched",
  importedAt: "2026-11-01T12:00:00.000Z",
  revision: 1,
  updatedAt: "2026-11-01T12:00:00.000Z",
  ...over,
});
const earlier = (days: number, over: Partial<StoredActivity> = {}) => run({ localDate: new Date(Date.parse("2026-11-01T00:00:00Z") - days * 86_400_000).toISOString().slice(0, 10), ...over });
const recent = [
  earlier(3, { durationSec: 3600, distanceM: 10000, avgHeartRate: 155 }),
  earlier(10, { durationSec: 3550, distanceM: 10300, avgHeartRate: 156 }),
  earlier(17, { durationSec: 3500, distanceM: 9800, avgHeartRate: 154 }),
];

describe("formats", () => {
  it("formats durations and paces in the repo's style", () => {
    expect(formatDuration(3480)).toBe("58 min");
    expect(formatDuration(3900)).toBe("1 h 05 min");
    expect(formatDuration(20)).toBe("1 min");
    expect(formatPace(341)).toBe("5:41/km");
  });
  it("reads numbers the same whatever their padding", () => {
    expect(numbersIn("1 h 05 min at 5:41/km, 10.2 km, 152 bpm")).toEqual(["1", "5", "5:41", "10.2", "152"]);
  });
});

describe("buildRunFacts", () => {
  it("states the run itself", () => {
    const f = buildRunFacts({ run: run(), others: [] });
    expect(f).toMatchObject({ distance: "10.2 km", time: "58 min", pace: "5:41/km", avgHr: "152 bpm", pain: false });
    expect(f.vsRecent).toBeUndefined();
  });
  it("leaves out what the run lacks", () => {
    const f = buildRunFacts({ run: run({ distanceM: undefined, avgHeartRate: undefined }), others: [] });
    expect(f).toEqual({ time: "58 min", pain: false });
  });
  it("compares with at least three similar runs of the last 28 days", () => {
    const f = buildRunFacts({ run: run(), others: recent });
    expect(f.vsRecent).toMatchObject({ count: 3, window: "4 weeks", pace: { dir: "quicker" }, hr: { dir: "lower" } });
    expect(buildRunFacts({ run: run(), others: recent.slice(0, 2) }).vsRecent).toBeUndefined();
  });
  it("ignores ignored runs, other lengths, older runs, later runs and itself", () => {
    const me = run();
    const others = [
      ...recent.slice(0, 2),
      earlier(5, { disposition: "ignored" }),
      earlier(5, { distanceM: 5000 }),
      earlier(40),
      run({ localDate: "2026-11-02" }),
      me,
    ];
    expect(buildRunFacts({ run: me, others }).vsRecent).toBeUndefined();
  });
  it("does not compare an interval or tempo run with other runs", () => {
    expect(buildRunFacts({ run: run(), others: recent, session: { type: "intervals", steps: [] } }).vsRecent).toBeUndefined();
    expect(buildRunFacts({ run: run(), others: recent, session: { type: "easy", steps: [] } }).vsRecent).toBeDefined();
  });
  it("states only the goals the plan states", () => {
    const steps = [
      { kind: "warmup" as const, goal: { type: "time" as const, value: 600 } },
      { kind: "repeat" as const, count: 4, steps: [{ kind: "work" as const, goal: { type: "distance" as const, value: 1000 } }] },
    ];
    const f = buildRunFacts({ run: run(), others: [], session: { type: "intervals", steps } });
    expect(f.plan).toEqual({ type: "intervals", distance: "4.0 km", time: "10 min" });
    const open = buildRunFacts({ run: run(), others: [], session: { type: "easy", steps: [{ kind: "work", goal: { type: "open" } }] } });
    expect(open.plan).toEqual({ type: "easy" });
  });
  it("carries the check-in numbers, but not for a run with pain", () => {
    expect(buildRunFacts({ run: run(), others: [], checkIn: { feel: 4, effortFelt: 6 } })).toMatchObject({ feel: 4, effort: 6, pain: false });
    const pain = buildRunFacts({ run: run(), others: [], checkIn: { feel: 2, effortFelt: 9, pain: true } });
    expect(pain.pain).toBe(true);
    expect(pain.feel).toBeUndefined();
    expect(pain.effort).toBeUndefined();
  });
});

describe("template paragraph", () => {
  it("reads like the plan's example", () => {
    const f = buildRunFacts({ run: run(), others: recent, session: { type: "easy", steps: [{ kind: "work", goal: { type: "distance", value: 10000 } }] }, checkIn: { feel: 4, effortFelt: 6 } });
    expect(templateParagraph(f)).toBe(
      "10.2 km in 58 min at 5:41/km, with an average heart rate of 152 bpm. You ran 13 s/km quicker than your 3 other runs of about this length in the last 4 weeks, which averaged 5:54/km. Your heart rate was 3 bpm lower than their average of 155 bpm. It was matched to an easy run that planned 10.0 km. You rated how it felt 4 out of 5 and the effort 6 out of 10.",
    );
  });
  it("says so when there is nothing to compare with", () => {
    expect(templateParagraph(buildRunFacts({ run: run(), others: [] }))).toContain("not yet enough runs of about this length");
  });
});

describe("next step line", () => {
  const s = (date: string, over = {}) => ({ date, type: "easy" as const, status: "planned" as const, steps: [{ kind: "work" as const, goal: { type: "distance" as const, value: 6000 } }], ...over });
  it("names the next planned session after today", () => {
    expect(nextStepLine([s("2026-11-03"), s("2026-11-05")], "2026-11-02")).toBe("Next planned session: Easy run, 6.0 km, tomorrow.");
    expect(nextStepLine([s("2026-11-05")], "2026-11-02")).toBe("Next planned session: Easy run, 6.0 km, on Thursday.");
  });
  it("passes over today, rest, done, skipped and deleted sessions, and has nothing when none is left", () => {
    const list = [s("2026-11-02"), s("2026-11-03", { type: "rest" }), s("2026-11-04", { status: "done" }), s("2026-11-05", { status: "skipped" }), s("2026-11-06", { deletedAt: "x" })];
    expect(nextStepLine(list, "2026-11-02")).toBeUndefined();
  });
  it("invents no distance", () => {
    expect(nextStepLine([s("2026-11-05", { steps: [] })], "2026-11-02")).toBe("Next planned session: Easy run, on Thursday.");
  });
  it("keeps the pain guidance word for word", () => {
    expect(PAIN_GUIDANCE).toBe("If something hurts, stop and talk to a qualified professional. This app can't give medical advice.");
  });
});

describe("checkParagraph", () => {
  const facts = buildRunFacts({ run: run(), others: recent, session: { type: "easy", steps: [{ kind: "work", goal: { type: "distance", value: 10000 } }] }, checkIn: { feel: 4, effortFelt: 6 } });
  const good = templateParagraph(facts);
  const painFacts: RunFacts = { ...buildRunFacts({ run: run(), others: recent, checkIn: { feel: 2, pain: true } }) };

  it("accepts the template", () => expect(checkParagraph(good, facts)).toEqual({ ok: true }));
  it.each([
    ["an invented number", good.replace("152 bpm", "158 bpm"), "number"],
    ["a mis-rounded pace", good.replace("5:41/km", "5:42/km"), "number"],
    ["an inverted pace claim", good.replace("quicker than", "slower than"), "claim"],
    ["an inverted heart rate claim", good.replace("3 bpm lower", "3 bpm higher"), "claim"],
    ["a swapped unit", good.replace("10.2 km", "10.2 bpm"), "claim"],
    ["a number on the wrong thing", good.replace("152 bpm", "155 km"), "claim"],
    ["an injury word", `${good} That sounds like an injury.`, "wording"],
    ["advice", `${good} You should rest tomorrow.`, "wording"],
    ["a personal best", `${good} A personal best for you.`, "wording"],
    ["an exclamation mark", `${good}!`, "shape"],
    ["markdown", `**${good}**`, "shape"],
    ["a link", `${good} See https://example.com`, "shape"],
    ["an emoji", `${good} 🎉`, "shape"],
    ["another script", `${good} 良い走り`, "shape"],
    ["too short", "Nice run.", "shape"],
    ["nothing", "   ", "empty"],
    ["two lines", good.replace(". You", ".\nYou"), "shape"],
  ])("refuses %s", (_name, text, reason) => expect(checkParagraph(text, facts)).toEqual({ ok: false, reason }));

  it("refuses a comparison the facts do not make", () => {
    const alone = buildRunFacts({ run: run(), others: [] });
    expect(checkParagraph(`${templateParagraph(alone)} That was faster than usual.`, alone)).toEqual({ ok: false, reason: "claim" });
  });

  it("holds a run with pain to a stricter check", () => {
    const text = "10.2 km in 58 min at 5:41/km, with an average heart rate of 152 bpm. You ran 13 s/km quicker than your 3 other runs of about this length in the last 4 weeks.";
    expect(checkParagraph(text, painFacts)).toEqual({ ok: true });
    expect(checkParagraph(`${text} A good, solid effort.`, painFacts)).toEqual({ ok: false, reason: "strict_wording" });
    expect(checkParagraph(`${text} A good, solid effort.`, facts)).toEqual({ ok: true });
    expect(checkParagraph(`${text} Keep it gentle next time.`, painFacts).ok).toBe(false);
  });
});

describe("properties", () => {
  const activity = fc.record({
    durationSec: fc.integer({ min: 60, max: 30_000 }),
    distanceM: fc.option(fc.integer({ min: 500, max: 60_000 }), { nil: undefined }),
    avgHeartRate: fc.option(fc.integer({ min: 60, max: 210 }), { nil: undefined }),
    daysAgo: fc.integer({ min: 0, max: 40 }),
  });
  const toRun = (a: { durationSec: number; distanceM: number | undefined; avgHeartRate: number | undefined; daysAgo: number }) => earlier(a.daysAgo, { durationSec: a.durationSec, distanceM: a.distanceM, avgHeartRate: a.avgHeartRate });

  it("any facts give a template whose numbers all come from the facts and which passes every check", () => {
    fc.assert(
      fc.property(
        activity,
        fc.array(activity, { maxLength: 12 }),
        fc.option(fc.record({ feel: fc.integer({ min: 1, max: 5 }), effortFelt: fc.option(fc.integer({ min: 1, max: 10 }), { nil: undefined }), pain: fc.boolean() }), { nil: undefined }),
        fc.option(fc.constantFrom("easy", "long", "intervals", "tempo"), { nil: undefined }),
        (a, others, checkIn, type) => {
          const facts = buildRunFacts({ run: toRun({ ...a, daysAgo: 0 }), others: others.map(toRun), ...(checkIn ? { checkIn } : {}), ...(type ? { session: { type, steps: [{ kind: "work" as const, goal: { type: "distance" as const, value: 8000 } }] } } : {}) });
          const text = templateParagraph(facts);
          const allowed = allowedNumbers(facts);
          expect(numbersIn(text).every((x) => allowed.has(x))).toBe(true);
          expect(checkParagraph(text, facts)).toEqual({ ok: true });
        },
      ),
    );
  });
  it("the paragraph of a run with pain never mentions it", () => {
    const f = buildRunFacts({ run: run(), others: recent, checkIn: { feel: 1, effortFelt: 10, pain: true } });
    expect(templateParagraph(f)).not.toMatch(/pain|hurt|injur|felt|effort/i);
  });
});
