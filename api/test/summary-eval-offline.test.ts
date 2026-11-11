import { describe, expect, it } from "vitest";
import { fixtures, judge } from "../scripts/eval-summary-fixtures";
import { buildRunFacts } from "../src/domain/run-facts";
import { modelAnswer, parseNarration } from "../src/domain/run-summary-prompt";
import { checkParagraph } from "../src/domain/summary-check";
import { CAPTURED } from "./fixtures/summary-eval-captured";

const facts = (run: number) => buildRunFacts(fixtures()[run - 1]!.input);

describe("offline eval on captured model answers (issue #160)", () => {
  it.each(CAPTURED.map((c, i) => [`${c.real ? "REAL" : "synthetic"} #${i} ${c.model} run ${c.run} -> ${c.expect}`, c] as const))("%s", (_name, c) => {
    expect(judge(c.result, facts(c.run))).toBe(c.expect);
  });

  it("summarises the pass rate per model", () => {
    const rate = new Map<string, string>();
    for (const model of new Set(CAPTURED.map((c) => c.model))) {
      const all = CAPTURED.filter((c) => c.model === model);
      const ok = all.filter((c) => judge(c.result, facts(c.run)) === "ok").length;
      rate.set(model, `${ok}/${all.length}`);
    }
    console.log([...rate].map(([m, r]) => `${m} ${r}`).join("\n"));
  });
});

describe("number check accepts spoken units, still refuses wrong numbers", () => {
  const f = facts(4); // 10.0 km, 59 min, 5:51/km, 4 similar runs averaging 5:52/km, no heart rate
  const pass = (text: string) => expect(checkParagraph(text, f)).toEqual({ ok: true });
  const fail = (text: string, reason = "number") => expect(checkParagraph(text, f)).toEqual({ ok: false, reason });

  it("accepts the same facts written in words", () => {
    pass("Today's run covered 10.0 km in 59 minutes, with an average pace of 5:51/km. This run's pace is about the same as the average pace of the other 4 runs of similar length over the last 4 weeks, which was 5:52/km.");
    pass("You ran 10 kilometres in 59 mins at 5:51 per kilometre, about the same as your 4 other runs over the last 4 weeks.");
    pass("The run was 10.0 km in 59 minutes at 5 minutes and 51 seconds per kilometre.");
    pass("The run was 10.0 km in 59 minutes over the last 28 days of similar runs, 4 runs.");
  });
  it("accepts min/km paces, adjectives before runs, and hyphenated units", () => {
    pass("The run was 10.0 km in 59 minutes at 5:51 min/km, about the same as your 4 similar runs over the last 4 weeks.");
    pass("The run was 10.0 km in 59 minutes at 5:51 minutes per km, like your 4 other similar runs.");
    pass("A 59-minute run of 10-kilometre length, with 4 recent runs for comparison.");
    fail("The run was 10.0 km in 59 minutes at 5:53 min/km.");
    fail("The run was 10.0 km in 59 minutes, with 5 similar runs for comparison.");
    fail("A 58-minute run of 10.0 km.");
  });
  it("accepts hours and heart rate in words", () => {
    const g = facts(5); // 1 h 17 min, 144 bpm, 12.5 km, 6:08/km
    expect(checkParagraph("Today's run covered 12.5 km in 1 hour and 17 minutes at 6:08/km, with an average heart rate of 144 beats per minute.", g)).toEqual({ ok: true });
    expect(checkParagraph("Today's run covered 12.5 km in 1 hour 17 minutes at 6:08/km, with an average heart rate of 145 beats per minute.", g)).toEqual({ ok: false, reason: "number" });
    expect(checkParagraph("Today's run covered 12.5 km in 77 minutes at 6:08/km.", g)).toEqual({ ok: false, reason: "number" });
  });
  it("still refuses wrong, invented or mis-unit numbers", () => {
    fail("Today's run covered 10.0 km in 60 minutes at 5:51/km.");
    fail("Today's run covered 10.0 km in 59 hours at 5:51/km.");
    fail("Today's run covered 11 kilometres in 59 minutes at 5:51/km.");
    fail("Today's run covered 10.0 km in 59 minutes at 5:53 per kilometre.");
    fail("Today's run covered 10.0 km in 59 minutes at 5 minutes and 53 seconds per kilometre.");
    fail("Today's run covered 10.0 km in 59 minutes. The 5 other runs of similar length averaged 5:52/km.");
    fail("Today's run covered 10.0 km in 59 minutes. The 4 other runs over the last 3 weeks averaged 5:52/km.");
    fail("Today's run covered 10.0 km in 59 minutes. The 4 other runs over the last 30 days averaged 5:52/km.");
    fail("Today's run covered 10.0 km in 59 minutes with an average heart rate of 150 beats per minute.");
    fail("Today's run covered 10.0 km in 59 minutes. You rated it 3 out of 5.");
    fail("Today's run covered ten km in 59 minutes.");
  });
  it("refuses words run together with a number", () => {
    fail("The run took44 minutes and covered 10.0 km.", "shape");
  });
  it("keeps the pain rules strict", () => {
    const p = buildRunFacts({ ...fixtures()[19]!.input }); // run 20 has pain
    expect(p.pain).toBe(true);
    const base = `Today's run covered ${p.distance} in ${p.time.replace(" min", " minutes")} at ${p.pace}.`;
    expect(checkParagraph(base, p)).toEqual({ ok: true });
    expect(checkParagraph(`${base} It was a good steady effort.`, p)).toEqual({ ok: false, reason: "strict_wording" });
    expect(checkParagraph(`${base} You should rest.`, p)).toEqual({ ok: false, reason: "wording" });
  });
});

describe("modelAnswer reads every response shape", () => {
  const answer = { paragraph: "Four words are here." };
  it("reads a string, an object, choices and text-choices", () => {
    expect(parseNarration(modelAnswer({ response: JSON.stringify(answer) }))).toBe(answer.paragraph);
    expect(parseNarration(modelAnswer({ response: answer }))).toBe(answer.paragraph);
    expect(parseNarration(modelAnswer({ choices: [{ message: { content: JSON.stringify(answer) } }] }))).toBe(answer.paragraph);
    expect(parseNarration(modelAnswer({ choices: [{ text: JSON.stringify(answer) }] }))).toBe(answer.paragraph);
    expect(parseNarration(modelAnswer({ result: { response: answer } }))).toBe(answer.paragraph);
    expect(parseNarration(modelAnswer(answer))).toBe(answer.paragraph);
  });
  it("gives undefined for nothing usable", () => {
    expect(modelAnswer({ usage: {} })).toBeUndefined();
    expect(modelAnswer(null)).toBeNull();
    expect(parseNarration(modelAnswer({ choices: [] }))).toBeUndefined();
  });
});
