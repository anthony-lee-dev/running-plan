// Manual eval of the run summary model (issue #132): runs fixture runs through candidate Workers AI models and prints how often
// the text passes the checks (the share that would show instead of the template) and the neurons spent. Never run in CI: it
// calls the real model and spends the account's free daily pool (about 10 neurons a call, up to 2 calls per fixture: 30 fixtures x 3
// models can reach 2,000 to 5,000 neurons). Run it right after 00:00 UTC so the live cap is not starved, or pass one model.
//
//   CLOUDFLARE_ACCOUNT_ID=... CLOUDFLARE_API_TOKEN=... npx tsx api/scripts/eval-summary.ts [model ...]
//
// The token needs only "Workers AI: Read" (create it in the dashboard; never commit it). Fixtures are made-up runs.
import type { StoredActivity } from "../src/domain/activities";
import { buildRunFacts, type RunFactsInput } from "../src/domain/run-facts";
import { buildPrompt, parseNarration } from "../src/domain/run-summary-prompt";
import { checkParagraph } from "../src/domain/summary-check";

const MODELS = process.argv.slice(2).length > 0 ? process.argv.slice(2) : ["@cf/meta/llama-3.1-8b-instruct-fp8-fast", "@cf/meta/llama-3.2-3b-instruct", "@cf/ibm-granite/granite-4.0-h-micro"];
// Neurons per million tokens (input, output), from Cloudflare's Workers AI pricing page when this was written: check it again.
const NEURONS_PER_M: Record<string, [number, number]> = {
  "@cf/meta/llama-3.1-8b-instruct-fp8-fast": [4119, 34868],
  "@cf/meta/llama-3.2-3b-instruct": [4625, 30475],
  "@cf/ibm-granite/granite-4.0-h-micro": [1542, 10158],
};

const account = process.env.CLOUDFLARE_ACCOUNT_ID;
const token = process.env.CLOUDFLARE_API_TOKEN;
if (!account || !token) {
  console.error("Set CLOUDFLARE_ACCOUNT_ID and CLOUDFLARE_API_TOKEN.");
  process.exit(1);
}

let n = 0;
const act = (daysAgo: number, over: Partial<StoredActivity> = {}): StoredActivity => ({
  id: `f${++n}`, source: "manual", externalId: `x${n}`, workoutType: "running",
  startedAt: "2026-11-01T07:00:00Z", localDate: new Date(Date.parse("2026-11-01T00:00:00Z") - daysAgo * 86_400_000).toISOString().slice(0, 10),
  durationSec: 3000, distanceM: 8000, avgHeartRate: 150, disposition: "matched", importedAt: "2026-11-01T00:00:00.000Z", revision: 1, updatedAt: "2026-11-01T00:00:00.000Z", ...over,
});

/** 30 made-up runs: lengths, with and without heart rate, history, planned sessions, check-ins, and a few with pain. */
function fixtures(): { name: string; input: RunFactsInput }[] {
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

async function ask(model: string, system: string, user: string) {
  const res = await fetch(`https://api.cloudflare.com/client/v4/accounts/${account}/ai/run/${model}`, {
    method: "POST",
    headers: { authorization: `Bearer ${token}`, "content-type": "application/json" },
    body: JSON.stringify({ messages: [{ role: "system", content: system }, { role: "user", content: user }], max_tokens: 300, temperature: 0.2, response_format: { type: "json_schema", json_schema: { type: "object", properties: { paragraph: { type: "string" } }, required: ["paragraph"], additionalProperties: false } } }),
  });
  if (!res.ok) throw new Error(`HTTP ${res.status}${(await res.text()).includes("4006") ? " (daily allowance used up: stop and rerun after 00:00 UTC)" : ""}`);
  const body = (await res.json()) as { result?: { response?: unknown; usage?: { prompt_tokens?: number; completion_tokens?: number } } };
  return { raw: body.result?.response, usage: body.result?.usage ?? {} };
}

for (const model of MODELS) {
  let ok = 0;
  let neurons = 0;
  const reasons = new Map<string, number>();
  const [inRate, outRate] = NEURONS_PER_M[model] ?? [0, 0];
  for (const f of fixtures()) {
    const facts = buildRunFacts(f.input);
    const prompt = buildPrompt(facts);
    let verdict = "error";
    try {
      // Same rule as the endpoint: one retry when the first answer fails.
      for (let attempt = 0; attempt < 2; attempt++) {
        const { raw, usage } = await ask(model, prompt.system, prompt.user);
        neurons += ((usage.prompt_tokens ?? 0) * inRate + (usage.completion_tokens ?? 0) * outRate) / 1e6;
        const text = parseNarration(raw);
        const checked = text === undefined ? ({ ok: false, reason: "malformed" } as const) : checkParagraph(text, facts);
        verdict = checked.ok ? "ok" : checked.reason;
        if (checked.ok) break;
        if (attempt === 1 || process.env.SHOW) console.log(`  [${model}] ${f.name} ${verdict}: ${typeof raw === "string" ? raw.slice(0, 300) : JSON.stringify(raw)?.slice(0, 300)}`);
      }
    } catch (error) {
      verdict = `error ${(error as Error).message}`;
    }
    if (verdict === "ok") ok++;
    reasons.set(verdict, (reasons.get(verdict) ?? 0) + 1);
  }
  console.log(`\n${model}\n  AI text shown: ${ok}/30 (template otherwise)\n  outcomes: ${[...reasons].map(([k, v]) => `${k} ${v}`).join(", ")}\n  neurons (estimate): ${neurons.toFixed(0)}, per call about ${(neurons / 30).toFixed(1)}`);
}
