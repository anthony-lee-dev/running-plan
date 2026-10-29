import { describe, expect, it } from "vitest";
import {
  derivePaces,
  equivalentTimeSec,
  heartRateRange,
  resolveTargetKind,
  RIEGEL_EXPONENT,
  type DerivedPaces,
  type PaceRange,
} from "../src/domain/paces";

const TEMPO_MIN = 334;
const TEMPO_MAX = 354;
const INTERVAL_MIN = 320;
const TODAY = "2026-10-28";
const fiveK = (timeSec: number, date?: string) => ({ distanceM: 5000, timeSec, ...(date ? { date } : {}) });

const mid = (r: PaceRange) => (r.minSecPerKm + r.maxSecPerKm) / 2;
const ranges = (p: DerivedPaces) => [p.easy, p.long, p.tempo, p.interval] as PaceRange[];

describe("equivalentTimeSec (Riegel)", () => {
  it("uses T2 = T1 x (D2 / D1)^1.06", () => {
    expect(RIEGEL_EXPONENT).toBe(1.06);
    expect(equivalentTimeSec(fiveK(1500), 10000)).toBeCloseTo(1500 * 2 ** 1.06, 6);
    expect(equivalentTimeSec(fiveK(1500), 10000)).toBeCloseTo(3127.8, 0);
  });
  it("returns the same time for the same distance", () => {
    expect(equivalentTimeSec({ distanceM: 10000, timeSec: 3000 }, 10000)).toBe(3000);
  });
  it("is slower per km over longer distances", () => {
    const r = fiveK(1500);
    expect(equivalentTimeSec(r, 21097) / 21097).toBeGreaterThan(equivalentTimeSec(r, 5000) / 5000);
  });
});

describe("derivePaces", () => {
  it("gives four ranges in seconds per km from a recent race", () => {
    const p = derivePaces({ recentResult: fiveK(1650, "2026-10-14"), today: TODAY });
    expect(p.source).toBe("race");
    expect(p.basedOn).toBe("5K in 27:30 on 2026-10-14");
    for (const r of ranges(p)) {
      expect(Number.isInteger(r.minSecPerKm) && Number.isInteger(r.maxSecPerKm)).toBe(true);
      expect(r.minSecPerKm).toBeLessThan(r.maxSecPerKm);
    }
  });

  it("matches the documented anchors for a 27:30 5K (330 s per km)", () => {
    const p = derivePaces({ recentResult: fiveK(1650, "2026-10-14"), today: TODAY });
    // Easy 1.20 to 1.35 of 5K pace, long 1.15 to 1.30.
    expect(p.easy).toEqual({ minSecPerKm: 396, maxSecPerKm: 446 });
    expect(p.long).toEqual({ minSecPerKm: 380, maxSecPerKm: 429 });
    // Tempo is the 10K-equivalent pace (344 s per km) plus or minus 3%; interval runs from 3K pace up to 5K pace.
    expect(p.tempo).toEqual({ minSecPerKm: TEMPO_MIN, maxSecPerKm: TEMPO_MAX });
    expect(p.interval).toEqual({ minSecPerKm: INTERVAL_MIN, maxSecPerKm: 330 });
  });

  it("starts the easy range on the slow side: easy and long are slower than tempo and interval", () => {
    const p = derivePaces({ recentResult: fiveK(1500, "2026-10-20"), today: TODAY });
    expect(p.easy!.minSecPerKm).toBeGreaterThan(p.tempo!.maxSecPerKm);
    expect(p.easy!.minSecPerKm).toBeGreaterThan(p.long!.minSecPerKm);
    expect(p.easy!.maxSecPerKm).toBeGreaterThan(p.long!.maxSecPerKm);
    expect(mid(p.interval!)).toBeLessThan(mid(p.tempo!));
    expect(mid(p.tempo!)).toBeLessThan(mid(p.long!));
    expect(mid(p.long!)).toBeLessThan(mid(p.easy!));
  });

  it("accepts a result at any distance and gives the same paces for equivalent efforts", () => {
    const fromFive = derivePaces({ recentResult: fiveK(1500, "2026-10-20"), today: TODAY });
    const tenTime = Math.round(equivalentTimeSec(fiveK(1500), 10000));
    const fromTen = derivePaces({ recentResult: { distanceM: 10000, timeSec: tenTime, date: "2026-10-20" }, today: TODAY });
    for (const key of ["easy", "long", "tempo", "interval"] as const) {
      expect(Math.abs(fromTen[key]!.minSecPerKm - fromFive[key]!.minSecPerKm)).toBeLessThanOrEqual(1);
      expect(Math.abs(fromTen[key]!.maxSecPerKm - fromFive[key]!.maxSecPerKm)).toBeLessThanOrEqual(1);
    }
  });

  it("never gets slower when the result gets faster", () => {
    let prev: DerivedPaces | undefined;
    for (let timeSec = 2400; timeSec >= 1000; timeSec -= 50) {
      const p = derivePaces({ recentResult: fiveK(timeSec, "2026-10-20"), today: TODAY });
      if (prev) {
        for (const key of ["easy", "long", "tempo", "interval"] as const) {
          expect(p[key]!.minSecPerKm, `${key} min at ${timeSec}`).toBeLessThanOrEqual(prev[key]!.minSecPerKm);
          expect(p[key]!.maxSecPerKm, `${key} max at ${timeSec}`).toBeLessThanOrEqual(prev[key]!.maxSecPerKm);
        }
      }
      prev = p;
    }
  });

  it("keeps every range inside the spec bounds (120 to 1200 s per km)", () => {
    for (const result of [{ distanceM: 1000, timeSec: 150 }, { distanceM: 42195, timeSec: 28800 }]) {
      const p = derivePaces({ recentResult: { ...result, date: "2026-10-20" }, today: TODAY });
      for (const r of ranges(p)) {
        expect(r.minSecPerKm).toBeGreaterThanOrEqual(120);
        expect(r.maxSecPerKm).toBeLessThanOrEqual(1200);
        expect(r.minSecPerKm).toBeLessThan(r.maxSecPerKm);
      }
    }
  });

  describe("without a usable result", () => {
    it("returns effort-based targets when there is no result", () => {
      expect(derivePaces({ today: TODAY })).toEqual({ source: "none" });
    });
    it("downgrades a result older than six weeks to an estimate and says so", () => {
      const p = derivePaces({ recentResult: fiveK(1650, "2026-08-01"), today: TODAY });
      expect(p.source).toBe("estimated");
      expect(p.basedOn).toBe("5K in 27:30 on 2026-08-01, more than 6 weeks ago");
      expect(p.easy).toBeDefined();
    });
    it("treats exactly six weeks as recent", () => {
      expect(derivePaces({ recentResult: fiveK(1650, "2026-09-16"), today: TODAY }).source).toBe("race");
    });
    it("treats a result with no date as recent", () => {
      const p = derivePaces({ recentResult: fiveK(1650), today: TODAY });
      expect(p.source).toBe("race");
      expect(p.basedOn).toBe("5K in 27:30");
    });
    it("rejects impossible results rather than guessing", () => {
      expect(() => derivePaces({ recentResult: { distanceM: 500, timeSec: 200 }, today: TODAY })).toThrow(RangeError);
      expect(() => derivePaces({ recentResult: { distanceM: 5000, timeSec: 10 }, today: TODAY })).toThrow(RangeError);
    });
    it("rejects results whose implied pace is not a real run", () => {
      expect(() => derivePaces({ recentResult: { distanceM: 1000, timeSec: 28800 }, today: TODAY })).toThrow(RangeError);
      expect(() => derivePaces({ recentResult: { distanceM: 42195, timeSec: 2400 }, today: TODAY })).toThrow(RangeError);
      expect(() => derivePaces({ recentResult: { distanceM: 5000, timeSec: 600 }, today: TODAY })).toThrow(RangeError);
    });
    it("rejects a result dated after today and a malformed date", () => {
      expect(() => derivePaces({ recentResult: fiveK(1650, "2026-11-01"), today: TODAY })).toThrow(RangeError);
      expect(() => derivePaces({ recentResult: fiveK(1650, "yesterday"), today: TODAY })).toThrow(RangeError);
    });
  });

  it("describes other distances and long times", () => {
    expect(derivePaces({ recentResult: { distanceM: 21097, timeSec: 7200 }, today: TODAY }).basedOn).toBe("Half marathon in 2:00:00");
    expect(derivePaces({ recentResult: { distanceM: 10000, timeSec: 3000 }, today: TODAY }).basedOn).toBe("10K in 50:00");
    expect(derivePaces({ recentResult: { distanceM: 8000, timeSec: 2400 }, today: TODAY }).basedOn).toBe("8K in 40:00");
  });
});

describe("heart rate", () => {
  it("gives no heart-rate range unless the user supplied max heart rate or zones", () => {
    expect(heartRateRange({}, "easy")).toBeUndefined();
    expect(heartRateRange(undefined, "tempo")).toBeUndefined();
  });
  it("uses the user's zones as given", () => {
    const zones = [
      { minBpm: 100, maxBpm: 120 },
      { minBpm: 121, maxBpm: 140 },
      { minBpm: 141, maxBpm: 155 },
      { minBpm: 156, maxBpm: 170 },
      { minBpm: 171, maxBpm: 190 },
    ];
    expect(heartRateRange({ zones }, "easy")).toEqual(zones[1]);
    expect(heartRateRange({ zones }, "long")).toEqual(zones[1]);
    expect(heartRateRange({ zones }, "tempo")).toEqual(zones[3]);
    expect(heartRateRange({ zones }, "interval")).toEqual(zones[4]);
  });
  it("ignores a zones list that is not exactly five and uses max heart rate instead", () => {
    const four = [{ minBpm: 100, maxBpm: 120 }, { minBpm: 121, maxBpm: 140 }, { minBpm: 141, maxBpm: 155 }, { minBpm: 156, maxBpm: 170 }];
    expect(heartRateRange({ zones: four }, "easy")).toBeUndefined();
    expect(heartRateRange({ zones: four, maxBpm: 200 }, "easy")).toEqual({ minBpm: 120, maxBpm: 150 });
  });
  it("derives bands from a supplied max heart rate only", () => {
    const easy = heartRateRange({ maxBpm: 190 }, "easy")!;
    const interval = heartRateRange({ maxBpm: 190 }, "interval")!;
    expect(easy.minBpm).toBeLessThan(easy.maxBpm);
    expect(interval.minBpm).toBeGreaterThan(easy.maxBpm);
    expect(interval.maxBpm).toBeLessThanOrEqual(190);
  });
});

describe("resolveTargetKind", () => {
  const paced: DerivedPaces = { source: "race" };
  it("shows pace when the user asked for pace and we have paces", () => {
    expect(resolveTargetKind({ display: "pace", paces: paced })).toBe("pace");
    expect(resolveTargetKind({ paces: paced })).toBe("pace");
  });
  it("falls back to effort without a result", () => {
    expect(resolveTargetKind({ display: "pace", paces: { source: "none" } })).toBe("effort");
  });
  it("shows heart rate only when heart-rate data exists", () => {
    expect(resolveTargetKind({ display: "heart_rate", paces: paced })).toBe("effort");
    expect(resolveTargetKind({ display: "heart_rate", paces: paced, heartRate: { maxBpm: 185 } })).toBe("heart_rate");
  });
  it("honours an explicit effort display", () => {
    expect(resolveTargetKind({ display: "effort", paces: paced })).toBe("effort");
  });
});
