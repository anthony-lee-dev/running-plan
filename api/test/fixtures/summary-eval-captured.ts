// Model answers for the offline eval (issue #160). `real: true` is text quoted in the issue from the human's 2026-11-11 run
// (the only paragraph the issue gives in full); every other entry is SYNTHETIC: written to look like what each model does
// (units in words, "per kilometre", "N out of 5", Granite answering chat-completion style) and to include wrong text that must
// still be refused. `run` is the 1-based fixture number from scripts/eval-summary-fixtures.ts. `expect` is the verdict.
export interface Captured {
  model: string;
  run: number;
  real: boolean;
  /** The whole Workers AI `result`, or just its `response`, as the model returned it. */
  result: unknown;
  expect: string;
}

const L31 = "@cf/meta/llama-3.1-8b-instruct-fp8-fast";
const L32 = "@cf/meta/llama-3.2-3b-instruct";
const GR = "@cf/ibm-granite/granite-4.0-h-micro";
const json = (paragraph: string) => JSON.stringify({ paragraph });

export const CAPTURED: Captured[] = [
  // Real (issue #160): correct text that the old check refused ("59 minutes").
  { model: L31, run: 4, real: true, expect: "ok", result: { response: json("Today's run covered 10.0 km in 59 minutes, with an average pace of 5:51/km. This run's pace is about the same as the average pace of the other 4 runs of similar length over the last 4 weeks, which was 5:52/km.") } },

  // Synthetic llama-3.1.
  { model: L31, run: 5, real: false, expect: "ok", result: { response: json("Today's run covered 12.5 km in 1 hour 17 minutes, at an average pace of 6:08 per kilometre and an average heart rate of 144 beats per minute. It matched an easy run planned for 12.5 km. You rated how it felt 5 out of 5 and the effort 5 out of 10.") } },
  { model: L31, run: 6, real: false, expect: "ok", result: { response: { paragraph: "You ran 16.0 km in 1 hour and 43 minutes at 6:25/km, with an average heart rate of 145 bpm. That is about the same pace as your 4 other runs of similar length in the last 4 weeks (6:26/km), with a heart rate 5 bpm lower than theirs." } } },
  { model: L31, run: 8, real: false, expect: "ok", result: { response: json("The run was 3.0 km in 16 minutes, an average pace of 5 minutes and 29 seconds per kilometre. Over the last 4 weeks, 4 other runs of similar length averaged 5:30/km, so this pace is about the same.") } },
  { model: L31, run: 4, real: false, expect: "number", result: { response: json("Today's run covered 10.0 km in 60 minutes, with an average pace of 5:51/km. The 4 other runs of similar length over the last 4 weeks averaged 5:52/km.") } },
  { model: L31, run: 4, real: false, expect: "number", result: { response: json("Today's run covered 10.0 km in 59 minutes at 5:51/km. Your 5 other runs of similar length over the last 4 weeks averaged 5:52/km.") } },
  { model: L31, run: 6, real: false, expect: "number", result: { response: json("You ran 16.0 km in 1 hour 43 minutes. You rated how it felt 4 out of 5.") } },
  { model: L31, run: 4, real: false, expect: "number", result: { response: json("Today's run covered about 10 kilometres in 59 minutes. The pace was 5:51 per kilometre, 3 seconds per kilometre quicker than the 4 other runs of similar length.") } },
  { model: L31, run: 4, real: false, expect: "claim", result: { response: json("Today's run covered 10.0 km in 59 minutes at 5:51/km, which is faster than the 4 other runs of similar length over the last 4 weeks.") } },

  // Synthetic llama-3.2 (smaller: run-together words and sloppy numbers).
  { model: L32, run: 1, real: false, expect: "ok", result: { response: json("Today's run covered 3.0 km in 15 minutes at an average pace of 5:00/km and an average heart rate of 140 bpm. It was an easy run planned for 3.0 km. Compared with the 4 other runs of similar length in the last 4 weeks, the pace was about the same and the heart rate was 10 bpm lower.") } },
  { model: L32, run: 2, real: false, expect: "shape", result: { response: json("The run took44 minutes, covering 5.0 km at 5:17/km.") } },
  { model: L32, run: 2, real: false, expect: "number", result: { response: json("You covered 5.0 km in 26 minutes, around 5 minutes per kilometre. You said it felt 2 out of 5.") } },
  { model: L32, run: 3, real: false, expect: "wording", result: { response: json("Today's run was completed: 8.0 km in 45 minutes at 5:34/km, as planned for the tempo run.") } },
  { model: L32, run: 7, real: false, expect: "ok", result: { response: json("Today's run covered 21.1 km in 1 hour 50 minutes at an average pace of 5:12/km, with an average heart rate of 146 bpm. The planned tempo run was 21.1 km.") } },
  { model: L32, run: 8, real: false, expect: "ok", result: { response: json("Today's run covered 3.0 km in 16 min at 5:29/km. Over the past 28 days, 4 other runs were similar.") } },
  { model: L32, run: 8, real: false, expect: "number", result: { response: json("Today's run covered 3.0 km in 16 min at 5:29/km. Over the past 30 days, 4 other runs were similar.") } },

  // Synthetic Granite: chat-completion shape, response as an object, and one with plain prose instead of JSON.
  { model: GR, run: 4, real: false, expect: "ok", result: { choices: [{ message: { role: "assistant", content: json("Today's run covered 10.0 km in 59 minutes at an average pace of 5:51 per kilometre. The 4 other runs of similar length in the last 4 weeks averaged 5:52/km, so the pace is about the same.") } }] } },
  { model: GR, run: 5, real: false, expect: "ok", result: { response: { paragraph: "Today's run covered 12.5 km in 1 hour 17 minutes at 6:08/km, with an average heart rate of 144 bpm. It was an easy run planned for 12.5 km. You rated how it felt 5 out of 5 and the effort 5 out of 10." } } },
  { model: GR, run: 1, real: false, expect: "number", result: { choices: [{ message: { content: json("Today's run covered 3.0 km in 15 minutes at 5:00/km and an average heart rate of 148 bpm.") } }] } },
  { model: GR, run: 2, real: false, expect: "malformed", result: { response: "Today's run covered 5.0 km in 26 minutes at 5:17/km." } },
  { model: GR, run: 8, real: false, expect: "malformed", result: { usage: { prompt_tokens: 300 } } },
];
