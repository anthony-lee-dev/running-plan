// The 30 made-up runs the summary eval uses, and how one model answer is judged. No side effects, so tests can import it.
import type { StoredActivity } from "../src/domain/activities";
import type { RunFacts, RunFactsInput } from "../src/domain/run-facts";
import { modelAnswer, parseNarration } from "../src/domain/run-summary-prompt";
import { checkParagraph } from "../src/domain/summary-check";

let n = 0;
const act = (daysAgo: number, over: Partial<StoredActivity> = {}): StoredActivity => ({
  id: `f${++n}`, source: "manual", externalId: `x${n}`, workoutType: "running",
  startedAt: "2026-11-01T07:00:00Z", localDate: new Date(Date.parse("2026-11-01T00:00:00Z") - daysAgo * 86_400_000).toISOString().slice(0, 10),
  durationSec: 3000, distanceM: 8000, avgHeartRate: 150, disposition: "matched", importedAt: "2026-11-01T00:00:00.000Z", revision: 1, updatedAt: "2026-11-01T00:00:00.000Z", ...over,
});

/** 30 made-up runs: lengths, with and without heart rate, history, planned sessions, check-ins, and a few with pain. */
export function fixtures(): { name: string; input: RunFactsInput }[] {
  n = 0;
  const out: { name: string; input: RunFactsInput }[] = [];
  const lengths = [3000, 5000, 8000, 10000, 12500, 16000, 21100];
  for (let i = 0; i < 30; i++) {
    const distanceM = lengths[i % lengths.length]!;
    const pace = 300 + ((i * 17) % 90);
    const run = act(0, { distanceM, durationSec: Math.round((distanceM / 1000) * pace), ...(i % 4 === 3 ? { avgHeartRate: undefined } : { avgHeartRate: 140 + (i % 25) }) });
    const others = i % 5 === 4 ? [] : [3, 9, 15, 22].map((d, k) => act(d, { distanceM: distanceM * (0.9 + 0.05 * k), durationSec: Math.round(((distanceM * (0.9 + 0.05 * k)) / 1000) * (pace + (k % 2 ? 12 : -10))), avgHeartRate: 145 + k * 3 }));
    const type = (["easy", "long", "tempo", "intervals"] as const)[i % 4]!;
    const checkIn = i % 3 === 0 ? undefined : { feel: 1 + (i % 5), effortFelt: 1 + (i % 10), pain: i % 10 === 9 };
    out.push({ name: `run ${i + 1}${checkIn?.pain ? " (pain)" : ""}`, input: { run, others, ...(i % 2 === 0 ? { session: { type, steps: [{ kind: "work" as const, goal: { type: "distance" as const, value: distanceM } }] } } : {}), ...(checkIn ? { checkIn } : {}) } });
  }
  return out;
}

/** The verdict on one raw model result (the whole Workers AI `result`, or just its `response`): "ok" or the failure reason. */
export function judge(result: unknown, facts: RunFacts): string {
  const text = parseNarration(modelAnswer(result));
  if (text === undefined) return "malformed";
  const checked = checkParagraph(text, facts);
  return checked.ok ? "ok" : checked.reason;
}
