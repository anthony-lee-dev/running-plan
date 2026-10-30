import { describe, expect, it } from "vitest";
import { parseActivityBatch, planImport, type ActivityFields, type StoredActivity } from "../src/domain/activities";

const NOW = "2026-10-29T09:00:00.000Z";
const run = (over: Partial<ActivityFields> = {}): ActivityFields => ({
  source: "apple_health",
  externalId: "HK-1",
  workoutType: "running",
  startedAt: "2026-10-28T07:00:00-04:00",
  localDate: "2026-10-28",
  durationSec: 1800,
  distanceM: 5000,
  ...over,
});
const stored = (over: Partial<StoredActivity> = {}): StoredActivity => ({
  ...run(),
  id: "00000000-0000-4000-8000-000000000a01",
  disposition: "inbox",
  importedAt: NOW,
  revision: 1,
  updatedAt: NOW,
  ...over,
});
let n = 0;
const ids = () => `00000000-0000-4000-8000-${String(++n).padStart(12, "0")}`;

describe("planImport", () => {
  it("creates an activity it has not seen", () => {
    const plan = planImport([], [run()], NOW, ids);
    expect(plan.results).toEqual([{ externalId: "HK-1", status: "created", activityId: plan.creates[0]!.id }]);
    expect(plan.creates[0]).toMatchObject({ ...run(), disposition: "inbox", importedAt: NOW, revision: 1, updatedAt: NOW });
    expect(plan.updates).toEqual([]);
  });

  it("calls the same record sent again a duplicate and writes nothing", () => {
    const plan = planImport([stored()], [run()], NOW, ids);
    expect(plan.results).toEqual([{ externalId: "HK-1", status: "duplicate", activityId: stored().id }]);
    expect(plan.creates).toEqual([]);
    expect(plan.updates).toEqual([]);
  });

  it("updates a record with the same id whose values changed, keeping its disposition", () => {
    const plan = planImport([stored({ disposition: "extra" })], [run({ avgHeartRate: 150 })], NOW, ids);
    expect(plan.results[0]).toMatchObject({ status: "updated", activityId: stored().id });
    expect(plan.updates[0]).toMatchObject({ id: stored().id, avgHeartRate: 150, disposition: "extra", revision: 2 });
  });

  it("maps a re-written record (new id, start a little later, same run) to the existing activity", () => {
    const rewrite = run({ externalId: "HK-2", sourceApp: "Garmin Connect", startedAt: "2026-10-28T07:01:00-04:00", durationSec: 1810, distanceM: 5040 });
    const plan = planImport([stored()], [rewrite], NOW, ids);
    expect(plan.results[0]).toEqual({ externalId: "HK-2", status: "updated", activityId: stored().id });
    expect(plan.updates[0]).toMatchObject({ id: stored().id, externalId: "HK-2", sourceApp: "Garmin Connect" });
  });

  it("compares start times across UTC offsets", () => {
    const plan = planImport([stored()], [run({ externalId: "HK-2", startedAt: "2026-10-28T11:00:30Z" })], NOW, ids);
    expect(plan.results[0]!.status).toBe("updated");
  });

  it.each<[string, Partial<ActivityFields>]>([
    ["another workout type", { workoutType: "cycling" }],
    ["a start three minutes apart", { startedAt: "2026-10-28T07:03:00-04:00" }],
    ["a much longer duration", { durationSec: 2400 }],
    ["a much longer distance", { distanceM: 6000 }],
  ])("keeps %s as a separate activity", (_name, over) => {
    const plan = planImport([stored()], [run({ externalId: "HK-2", ...over })], NOW, ids);
    expect(plan.results[0]!.status).toBe("created");
  });

  it("ignores distance when one side has none", () => {
    const plan = planImport([stored()], [run({ externalId: "HK-2", distanceM: undefined })], NOW, ids);
    expect(plan.results[0]!.status).toBe("updated");
  });

  it("dedupes inside one batch", () => {
    const plan = planImport([], [run(), run(), run({ externalId: "HK-2", startedAt: "2026-10-28T07:00:20-04:00" })], NOW, ids);
    expect(plan.results.map((r) => r.status)).toEqual(["created", "duplicate", "updated"]);
    expect(new Set(plan.results.map((r) => r.activityId)).size).toBe(1);
    expect(plan.creates).toHaveLength(1);
    expect(plan.creates[0]!.externalId).toBe("HK-2");
    expect(plan.updates).toEqual([]);
  });

  it("does not match a source record to another source", () => {
    const plan = planImport([stored({ source: "manual" })], [run()], NOW, ids);
    expect(plan.results[0]!.status).toBe("created");
  });
});

describe("parseActivityBatch", () => {
  const ok = { activities: [{ ...run(), sourceApp: "Garmin Connect", avgHeartRate: 150, maxHeartRate: 170, avgCadence: 170, elevationGainM: 40 }] };

  it("accepts a batch and keeps the fields as sent", () => {
    expect(parseActivityBatch(ok)).toEqual({ ok: true, value: ok.activities });
  });

  it.each<[string, unknown, string]>([
    ["not an object", [], "/"],
    ["no activities", {}, "/activities"],
    ["an empty batch", { activities: [] }, "/activities"],
    ["over 200 activities", { activities: Array.from({ length: 201 }, () => run()) }, "/activities"],
    ["an unknown top-level field", { ...ok, extra: 1 }, "/extra"],
    ["an unknown activity field", { activities: [{ ...run(), route: [] }] }, "/activities/0/route"],
    ["an unknown source", { activities: [run({ source: "strava" as never })] }, "/activities/0/source"],
    ["an empty external id", { activities: [run({ externalId: "" })] }, "/activities/0/externalId"],
    ["a long external id", { activities: [run({ externalId: "x".repeat(129) })] }, "/activities/0/externalId"],
    ["an unknown workout type", { activities: [run({ workoutType: "yoga" as never })] }, "/activities/0/workoutType"],
    ["a start without an offset", { activities: [run({ startedAt: "2026-10-28T07:00:00" })] }, "/activities/0/startedAt"],
    ["a start that is not a time", { activities: [run({ startedAt: "yesterday" })] }, "/activities/0/startedAt"],
    ["a local date that is not a date", { activities: [run({ localDate: "2026-02-30" })] }, "/activities/0/localDate"],
    ["a zero duration", { activities: [run({ durationSec: 0 })] }, "/activities/0/durationSec"],
    ["a distance over 400 km", { activities: [run({ distanceM: 400001 })] }, "/activities/0/distanceM"],
    ["a heart rate of 20", { activities: [run({ avgHeartRate: 20 })] }, "/activities/0/avgHeartRate"],
    ["a cadence as text", { activities: [{ ...run(), avgCadence: "170" }] }, "/activities/0/avgCadence"],
    ["missing required fields", { activities: [{ source: "manual" }] }, "/activities/0/externalId"],
  ])("rejects %s", (_name, body, path) => {
    const result = parseActivityBatch(body);
    expect(result.ok).toBe(false);
    if (!result.ok) expect(result.errors.map((e) => e.path)).toContain(path);
  });
});
