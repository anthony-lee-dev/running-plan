// Manual eval of the run summary model (issue #132): runs fixture runs through candidate Workers AI models and prints how often
// the text passes the checks (the share that would show instead of the template) and the neurons spent. Never run in CI: it
// calls the real model and spends the account's free daily pool (about 10 neurons a call, up to 2 calls per fixture: 30 fixtures x 3
// models can reach 2,000 to 5,000 neurons). Run it right after 00:00 UTC so the live cap is not starved, or pass one model.
//
//   CLOUDFLARE_ACCOUNT_ID=... CLOUDFLARE_API_TOKEN=... npx tsx api/scripts/eval-summary.ts [model ...]
//   SAVE=captured.json ...   also writes every raw model result to a file (no secrets in it) so it can be re-judged offline
//   OFFLINE=captured.json npx tsx api/scripts/eval-summary.ts   re-judges saved results: no network, no token, no neurons
//                                                               (file: [{ model, run, result }], run = 1-based fixture number)
//
// The token needs only "Workers AI: Read" (create it in the dashboard; never commit it). Fixtures are made-up runs.
import { readFileSync, writeFileSync } from "node:fs";
import { buildRunFacts } from "../src/domain/run-facts";
import { buildPrompt } from "../src/domain/run-summary-prompt";
import { fixtures, judge } from "./eval-summary-fixtures";

const MODELS = process.argv.slice(2).length > 0 ? process.argv.slice(2) : ["@cf/meta/llama-3.1-8b-instruct-fp8-fast", "@cf/meta/llama-3.2-3b-instruct", "@cf/ibm-granite/granite-4.0-h-micro"];
// Neurons per million tokens (input, output), from Cloudflare's Workers AI pricing page when this was written: check it again.
const NEURONS_PER_M: Record<string, [number, number]> = {
  "@cf/meta/llama-3.1-8b-instruct-fp8-fast": [4119, 34868],
  "@cf/meta/llama-3.2-3b-instruct": [4625, 30475],
  "@cf/ibm-granite/granite-4.0-h-micro": [1542, 10158],
};

const offline = process.env.OFFLINE;
const account = process.env.CLOUDFLARE_ACCOUNT_ID;
const token = process.env.CLOUDFLARE_API_TOKEN;
if (!offline && (!account || !token)) {
  console.error("Set CLOUDFLARE_ACCOUNT_ID and CLOUDFLARE_API_TOKEN (or OFFLINE=<file> to re-judge saved results).");
  process.exit(1);
}

type Usage = { prompt_tokens?: number; completion_tokens?: number };
/** One call; returns the whole Workers AI `result` (its shape differs by model: `response` string or object, or `choices`). */
async function ask(model: string, system: string, user: string): Promise<{ result: unknown; usage: Usage }> {
  const res = await fetch(`https://api.cloudflare.com/client/v4/accounts/${account}/ai/run/${model}`, {
    method: "POST",
    headers: { authorization: `Bearer ${token}`, "content-type": "application/json" },
    body: JSON.stringify({ messages: [{ role: "system", content: system }, { role: "user", content: user }], max_tokens: 300, temperature: 0.2, response_format: { type: "json_schema", json_schema: { type: "object", properties: { paragraph: { type: "string" } }, required: ["paragraph"], additionalProperties: false } } }),
  });
  if (!res.ok) throw new Error(`HTTP ${res.status}${(await res.text()).includes("4006") ? " (daily allowance used up: stop and rerun after 00:00 UTC)" : ""}`);
  const body = (await res.json()) as { result?: { usage?: Usage } };
  return { result: body.result, usage: body.result?.usage ?? {} };
}

const show = (result: unknown) => (typeof result === "string" ? result : JSON.stringify(result) ?? "").slice(0, 300);
const saved: { model: string; run: number; result: unknown }[] = [];
const captured = offline ? (JSON.parse(readFileSync(offline, "utf8")) as { model: string; run: number; result: unknown }[]) : [];

for (const model of offline ? [...new Set(captured.map((c) => c.model))] : MODELS) {
  let ok = 0;
  let total = 0;
  let neurons = 0;
  const reasons = new Map<string, number>();
  const [inRate, outRate] = NEURONS_PER_M[model] ?? [0, 0];
  const all = fixtures();
  const runs = offline ? [...new Set(captured.filter((c) => c.model === model).map((c) => c.run))] : all.map((_, i) => i + 1);
  for (const run of runs) {
    const f = all[run - 1]!;
    total++;
    const facts = buildRunFacts(f.input);
    const prompt = buildPrompt(facts);
    let verdict = "error";
    try {
      // Same rule as the endpoint: one retry when the first answer fails (offline: each saved result is one attempt, first passing one wins).
      const attempts = offline ? captured.filter((c) => c.model === model && c.run === run).map((c) => ({ result: c.result, usage: {} as Usage })) : [];
      for (let attempt = 0; attempt < 2; attempt++) {
        const { result, usage } = offline ? (attempts[attempt] ?? attempts[attempts.length - 1]!) : await ask(model, prompt.system, prompt.user);
        if (!offline) saved.push({ model, run, result });
        neurons += ((usage.prompt_tokens ?? 0) * inRate + (usage.completion_tokens ?? 0) * outRate) / 1e6;
        verdict = judge(result, facts);
        if (verdict === "ok") break;
        if (attempt === 1 || process.env.SHOW || (offline && attempt === attempts.length - 1)) console.log(`  [${model}] ${f.name} ${verdict}: ${show(result)}`);
        if (offline && attempt >= attempts.length - 1) break;
      }
    } catch (error) {
      verdict = `error ${(error as Error).message}`;
    }
    if (verdict === "ok") ok++;
    reasons.set(verdict, (reasons.get(verdict) ?? 0) + 1);
  }
  console.log(`\n${model}\n  AI text shown: ${ok}/${total} (template otherwise)\n  outcomes: ${[...reasons].map(([k, v]) => `${k} ${v}`).join(", ")}${offline ? "" : `\n  neurons (estimate): ${neurons.toFixed(0)}, per call about ${(neurons / total).toFixed(1)}`}`);
}
if (process.env.SAVE && saved.length > 0) writeFileSync(process.env.SAVE, JSON.stringify(saved, null, 1));
