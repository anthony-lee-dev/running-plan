import { describe, expect, it } from "vitest";
import { DEFAULT_PROFILE, applyProfileUpdate, parseProfileUpdate } from "../src/domain/profile";

const ok = (body: unknown) => {
  const parsed = parseProfileUpdate(body);
  if (!parsed.ok) throw new Error(`expected valid: ${JSON.stringify(parsed.errors)}`);
  return parsed.value;
};
const errorsOf = (body: unknown) => {
  const parsed = parseProfileUpdate(body);
  return parsed.ok ? [] : parsed.errors.map((e) => e.path);
};

describe("DEFAULT_PROFILE", () => {
  it("is pace display, no paces, no heart rate, weekly plus urgent review", () => {
    expect(DEFAULT_PROFILE).toEqual({
      targetDisplay: "pace",
      paces: { source: "none" },
      heartRate: {},
      scheduling: {},
      review: { frequency: "weekly_plus_urgent" },
    });
  });
});

describe("parseProfileUpdate", () => {
  it("accepts each section on its own", () => {
    expect(ok({ targetDisplay: "effort" })).toEqual({ targetDisplay: "effort" });
    expect(ok({ review: { frequency: "weekly", day: "sun" } })).toEqual({ review: { frequency: "weekly", day: "sun" } });
    expect(ok({ scheduling: { longRunDay: "sun", restDay: "fri", unavailableDays: ["mon", "tue"] } })).toBeDefined();
    expect(ok({ heartRate: { maxBpm: 190 } })).toEqual({ heartRate: { maxBpm: 190 } });
    expect(ok({ paces: { easy: { minSecPerKm: 360, maxSecPerKm: 400 } } })).toBeDefined();
  });

  it.each([
    ["an empty body", {}, ["/"]],
    ["not an object", [], ["/"]],
    ["an unknown field", { targetDisplay: "pace", extra: 1 }, ["/extra"]],
    ["a bad display", { targetDisplay: "speed" }, ["/targetDisplay"]],
    ["a bad review frequency", { review: { frequency: "daily" } }, ["/review/frequency"]],
    ["no review frequency", { review: { day: "mon" } }, ["/review/frequency"]],
    ["a bad review day", { review: { frequency: "weekly", day: "monday" } }, ["/review/day"]],
    ["an unknown review field", { review: { frequency: "weekly", x: 1 } }, ["/review/x"]],
    ["max heart rate too low", { heartRate: { maxBpm: 99 } }, ["/heartRate/maxBpm"]],
    ["max heart rate too high", { heartRate: { maxBpm: 231 } }, ["/heartRate/maxBpm"]],
    ["fractional max heart rate", { heartRate: { maxBpm: 180.5 } }, ["/heartRate/maxBpm"]],
    ["four zones", { heartRate: { zones: Array(4).fill({ minBpm: 100, maxBpm: 120 }) } }, ["/heartRate/zones"]],
    ["a zone that runs backwards", { heartRate: { zones: [{ minBpm: 130, maxBpm: 120 }, ...Array(4).fill({ minBpm: 100, maxBpm: 120 })] } }, ["/heartRate/zones/0"]],
    ["a pace outside 120 to 1200", { paces: { easy: { minSecPerKm: 100, maxSecPerKm: 400 } } }, ["/paces/easy"]],
    ["a pace range that runs backwards", { paces: { tempo: { minSecPerKm: 400, maxSecPerKm: 300 } } }, ["/paces/tempo"]],
    ["an unknown pace zone", { paces: { sprint: { minSecPerKm: 200, maxSecPerKm: 250 } } }, ["/paces/sprint"]],
    ["seven unavailable days", { scheduling: { unavailableDays: ["mon", "tue", "wed", "thu", "fri", "sat", "sun"] } }, ["/scheduling/unavailableDays"]],
    ["a repeated unavailable day", { scheduling: { unavailableDays: ["mon", "mon"] } }, ["/scheduling/unavailableDays"]],
    ["a long run on an unavailable day", { scheduling: { longRunDay: "sat", unavailableDays: ["sat"] } }, ["/scheduling/longRunDay"]],
    ["a bad weekday", { scheduling: { longRunDay: "someday" } }, ["/scheduling/longRunDay"]],
  ])("rejects %s", (_name, body, paths) => {
    expect(errorsOf(body)).toEqual(paths);
  });

  it("reports every problem at once", () => {
    expect(errorsOf({ targetDisplay: "x", heartRate: { maxBpm: 1 } }).sort()).toEqual(["/heartRate/maxBpm", "/targetDisplay"]);
  });
});

describe("applyProfileUpdate", () => {
  const base = { ...DEFAULT_PROFILE };

  it("changes only what was sent", () => {
    const next = applyProfileUpdate(base, ok({ targetDisplay: "effort" }));
    expect(next).toEqual({ ...base, targetDisplay: "effort" });
  });

  it("replaces a whole section: heart rate, scheduling and review", () => {
    const first = applyProfileUpdate(base, ok({ heartRate: { maxBpm: 190 }, scheduling: { restDay: "fri" } }));
    const second = applyProfileUpdate(first, ok({ heartRate: { maxBpm: 185 }, scheduling: { longRunDay: "sun" } }));
    expect(second.heartRate).toEqual({ maxBpm: 185 });
    expect(second.scheduling).toEqual({ longRunDay: "sun" });
  });

  it("marks manually set paces as manual, drops the provenance and keeps the other zones", () => {
    const derived = {
      ...base,
      paces: { source: "race" as const, basedOn: "5K in 27:30", easy: { minSecPerKm: 396, maxSecPerKm: 446 }, tempo: { minSecPerKm: 334, maxSecPerKm: 354 } },
    };
    const next = applyProfileUpdate(derived, ok({ paces: { easy: { minSecPerKm: 380, maxSecPerKm: 420 } } }));
    expect(next.paces).toEqual({
      source: "manual",
      easy: { minSecPerKm: 380, maxSecPerKm: 420 },
      tempo: { minSecPerKm: 334, maxSecPerKm: 354 },
    });
  });

  it("leaves paces alone for an empty paces object", () => {
    expect(applyProfileUpdate(base, ok({ paces: {}, targetDisplay: "effort" })).paces).toEqual({ source: "none" });
  });

  it("does not change its inputs", () => {
    const copy = structuredClone(base);
    applyProfileUpdate(base, ok({ targetDisplay: "effort", heartRate: { maxBpm: 190 } }));
    expect(base).toEqual(copy);
  });
});
