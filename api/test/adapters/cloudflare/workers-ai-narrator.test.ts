import { describe, expect, it } from "vitest";
import { MAX_OUTPUT_TOKENS, WorkersAiNarrator } from "../../../src/adapters/cloudflare/workers-ai-narrator";
import { NarratorError } from "../../../src/ports";

const prompt = { system: "rules", user: '{"distance":"5.0 km"}' };

describe("WorkersAiNarrator (stub binding, no network)", () => {
  it("sends the prompt as chat messages with a token limit and a JSON schema, and returns the response", async () => {
    const calls: { model: string; input: any }[] = []; // eslint-disable-line @typescript-eslint/no-explicit-any
    const ai = { run: async (model: string, input: unknown) => (calls.push({ model, input }), { response: '{"paragraph":"x"}' }) };
    const narrator = new WorkersAiNarrator(ai, "@cf/test/model");
    expect(await narrator.narrate(prompt)).toBe('{"paragraph":"x"}');
    expect(narrator.model).toBe("@cf/test/model");
    expect(calls[0]!.model).toBe("@cf/test/model");
    expect(calls[0]!.input.messages).toEqual([{ role: "system", content: "rules" }, { role: "user", content: prompt.user }]);
    expect(calls[0]!.input.max_tokens).toBe(MAX_OUTPUT_TOKENS);
    expect(calls[0]!.input.response_format.type).toBe("json_schema");
  });
  it("passes an object response through for the caller to read", async () => {
    expect(await new WorkersAiNarrator({ run: async () => ({ response: { paragraph: "x" } }) }).narrate(prompt)).toEqual({ paragraph: "x" });
  });
  it("times out", async () => {
    const slow = new WorkersAiNarrator({ run: () => new Promise(() => {}) }, "m", 20);
    await expect(slow.narrate(prompt)).rejects.toMatchObject({ kind: "timeout" });
  });
  it.each([
    [new Error("4006: you have used up your daily free allocation of 10,000 neurons"), "quota"],
    [new Error("3040: capacity temporarily exceeded"), "unavailable"],
    ["a string thrown", "unavailable"],
  ])("maps %s to %s without carrying its message", async (thrown, kind) => {
    const narrator = new WorkersAiNarrator({ run: async () => { throw thrown; } }); // eslint-disable-line @typescript-eslint/only-throw-error
    const error = await narrator.narrate(prompt).catch((e: unknown) => e);
    expect(error).toBeInstanceOf(NarratorError);
    expect((error as NarratorError).kind).toBe(kind);
    expect((error as NarratorError).message).toBe(kind);
  });
});
