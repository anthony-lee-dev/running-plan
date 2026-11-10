import { NarratorError, type RunNarrator } from "../../ports";

/** The part of the Workers AI binding this adapter uses (`env.AI`, `[ai]` in wrangler.toml). */
export interface AiBinding {
  run(model: string, input: unknown): Promise<unknown>;
}

/** The model that wording is checked against on the fixtures (`scripts/eval-summary.ts`). Change it only after an eval. */
export const DEFAULT_MODEL = "@cf/meta/llama-3.1-8b-instruct-fp8-fast";
export const MAX_OUTPUT_TOKENS = 300;
export const TIMEOUT_MS = 8000;

const SCHEMA = { type: "object", properties: { paragraph: { type: "string" } }, required: ["paragraph"], additionalProperties: false };

/** Run summaries on Workers AI. The only file that touches the `AI` binding. Text in or out is never logged. */
export class WorkersAiNarrator implements RunNarrator {
  constructor(
    private readonly ai: AiBinding,
    readonly model: string = DEFAULT_MODEL,
    private readonly timeoutMs: number = TIMEOUT_MS,
  ) {}

  async narrate(prompt: { system: string; user: string }): Promise<unknown> {
    let timer: ReturnType<typeof setTimeout> | undefined;
    const timeout = new Promise<never>((_, reject) => {
      timer = setTimeout(() => reject(new NarratorError("timeout")), this.timeoutMs);
    });
    try {
      const out = (await Promise.race([
        this.ai.run(this.model, {
          messages: [
            { role: "system", content: prompt.system },
            { role: "user", content: prompt.user },
          ],
          max_tokens: MAX_OUTPUT_TOKENS,
          temperature: 0.2,
          response_format: { type: "json_schema", json_schema: SCHEMA },
        }),
        timeout,
      ])) as { response?: unknown } | null;
      return out?.response;
    } catch (error) {
      if (error instanceof NarratorError) throw error;
      // The allowance used up is reported as a 4006 error ("you have used up your daily free allocation"); anything else is a failure.
      const message = error instanceof Error ? error.message : "";
      throw new NarratorError(/4006|daily free allocation|neurons|quota/i.test(message) ? "quota" : "unavailable");
    } finally {
      if (timer !== undefined) clearTimeout(timer);
    }
  }
}
