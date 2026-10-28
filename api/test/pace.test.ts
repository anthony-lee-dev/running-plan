import { describe, expect, it } from "vitest";
import { formatPace, parsePace } from "../src/domain/pace";

describe("formatPace", () => {
  it.each([
    [390, "6:30/km"],
    [300, "5:00/km"],
    [425, "7:05/km"],
    [389.6, "6:30/km"],
  ])("%s s/km -> %s", (seconds, expected) => {
    expect(formatPace(seconds)).toBe(expected);
  });

  it("rejects zero and negative paces", () => {
    expect(() => formatPace(0)).toThrow(RangeError);
    expect(() => formatPace(-5)).toThrow(RangeError);
  });
});

describe("parsePace", () => {
  it("round-trips with formatPace", () => {
    for (const s of [300, 315, 390, 430]) expect(parsePace(formatPace(s))).toBe(s);
  });

  it("rejects malformed input", () => {
    expect(() => parsePace("6:75/km")).toThrow(SyntaxError);
    expect(() => parsePace("fast")).toThrow(SyntaxError);
  });
});
