import { describe, expect, it } from "vitest";
import type { StoredActivity } from "../src/domain/activities";
import { buildRunFacts } from "../src/domain/run-facts";
import { buildPrompt, modelFacts, parseNarration } from "../src/domain/run-summary-prompt";

const run: StoredActivity = {
  id: "a1", source: "apple_health", externalId: "HK-1", sourceApp: "Garmin Connect", workoutType: "running", startedAt: "2026-11-01T07:00:00-05:00", localDate: "2026-11-01",
  durationSec: 3480, distanceM: 10200, avgHeartRate: 152, disposition: "matched", importedAt: "2026-11-01T12:00:00.000Z", revision: 1, updatedAt: "2026-11-01T12:00:00.000Z",
};

describe("prompt", () => {
  it("carries the ready-formatted facts and nothing identifying", () => {
    const user = buildPrompt(buildRunFacts({ run, others: [], checkIn: { feel: 4, effortFelt: 6 } })).user;
    expect(JSON.parse(user)).toEqual({ distance: "10.2 km", duration: "58 min", average_pace: "5:41/km", average_heart_rate: "152 bpm", runner_rating_of_how_it_felt: "4 out of 5", runner_rating_of_effort: "6 out of 10" });
    for (const leak of ["a1", "HK-1", "Garmin", "2026", "apple_health"]) expect(user).not.toContain(leak);
    expect(user.length).toBeLessThan(1500);
  });
  it("adds the strict rule, and no check-in numbers, for a run with pain", () => {
    const facts = buildRunFacts({ run, others: [], checkIn: { feel: 1, effortFelt: 10, pain: true } });
    expect(buildPrompt(facts).system).toContain("neutral statement of the numbers");
    expect(JSON.stringify(modelFacts(facts))).not.toMatch(/felt|effort|rating/);
    expect(buildPrompt(buildRunFacts({ run, others: [] })).system).not.toContain("neutral statement of the numbers");
  });
  it("forbids advice, medical ideas and extra numbers in its rules", () => {
    const system = buildPrompt(buildRunFacts({ run, others: [] })).system;
    expect(system).toMatch(/copied exactly/);
    expect(system).toMatch(/Do not give advice/);
    expect(system).toMatch(/medical/);
  });
});

describe("parseNarration", () => {
  it.each([
    ['{"paragraph":"Hello there."}', "Hello there."],
    ['```json\n{"paragraph":"Hello there."}\n```', "Hello there."],
    [{ paragraph: "Hello there." }, "Hello there."],
  ])("reads %j", (raw, text) => expect(parseNarration(raw)).toBe(text));
  it.each([["not json"], ['{"text":"x"}'], ['{"paragraph":1}'], ['{"paragraph":"x","extra":1}'], ["[]"], [null], [undefined], [42], ['"just a string"']])("refuses %j", (raw) => expect(parseNarration(raw)).toBeUndefined());
});
