// What the model is asked, and how its answer is read (issue #132). The model only rewords facts the server computed: the
// facts go in as ready-formatted strings (no free text, ids or dates), and its answer must pass `checkParagraph` or the
// template is shown. Pure: no I/O. Bump `PROMPT_VERSION` (run-summary-text.ts) with any change here.
import type { RunFacts } from "./run-facts";
import { planTypeName } from "./run-facts";

export interface NarratorPrompt {
  system: string;
  user: string;
}

const RULES = [
  "You write the summary of one run for a running app. You are given facts as JSON. Reword them as one plain paragraph of 3 to 5 sentences, about 50 to 90 words, in a calm, factual coach voice.",
  "Use only the facts given. Every number you write must be copied exactly from the facts, with its unit, and mean what the facts say it means. Never add, round, convert or work out another number.",
  "Mention only what is present in the facts. If a part is missing, leave it out; do not mention that it is missing.",
  "Compare only in the direction the facts state (for example quicker or slower, higher or lower), and never otherwise.",
  "Do not give advice, plans, tips, goals or predictions. Do not say what the runner should do next.",
  "Do not mention injury, pain, health, recovery, risk or any medical idea. Do not praise or criticise; no superlatives, no records, no exclamation marks, no emoji, no lists, no markdown.",
  'Answer with JSON only, exactly {"paragraph":"..."}.',
];

const PAIN_RULES = [
  "Extra rule for this run: write only a neutral statement of the numbers. Do not describe how the run felt, its difficulty, the effort or the pace as good or bad, and add no encouragement, reassurance or advice of any kind. 2 to 4 sentences.",
];

/** The facts the model sees: the same ready-formatted values the template uses, nothing else. */
export function modelFacts(facts: RunFacts): Record<string, unknown> {
  return {
    ...(facts.distance ? { distance: facts.distance } : {}),
    duration: facts.time,
    ...(facts.pace ? { average_pace: facts.pace } : {}),
    ...(facts.avgHr ? { average_heart_rate: facts.avgHr } : {}),
    ...(facts.vsRecent
      ? {
          compared_with: {
            number_of_other_runs_of_similar_length: facts.vsRecent.count,
            period: `last ${facts.vsRecent.window}`,
            their_average_pace: facts.vsRecent.avgPace,
            this_run_pace_versus_theirs: facts.vsRecent.pace.text,
            ...(facts.vsRecent.avgHr ? { their_average_heart_rate: facts.vsRecent.avgHr } : {}),
            ...(facts.vsRecent.hr ? { this_run_heart_rate_versus_theirs: facts.vsRecent.hr.text } : {}),
          },
        }
      : {}),
    ...(facts.plan ? { matched_planned_session: { type: planTypeName(facts.plan.type), ...(facts.plan.distance ? { planned_distance: facts.plan.distance } : {}), ...(facts.plan.time ? { planned_time: facts.plan.time } : {}) } } : {}),
    ...(facts.feel !== undefined ? { runner_rating_of_how_it_felt: `${facts.feel} out of 5` } : {}),
    ...(facts.effort !== undefined ? { runner_rating_of_effort: `${facts.effort} out of 10` } : {}),
  };
}

export function buildPrompt(facts: RunFacts): NarratorPrompt {
  return {
    system: [...RULES, ...(facts.pain ? PAIN_RULES : [])].join("\n"),
    user: JSON.stringify(modelFacts(facts)),
  };
}

/** The paragraph in a model's answer, or undefined when it is not the agreed JSON. Tolerates a code fence around it. */
export function parseNarration(raw: unknown): string | undefined {
  let value: unknown = raw;
  if (typeof raw === "string") {
    const cleaned = raw.trim().replace(/^```(?:json)?\s*/i, "").replace(/\s*```$/, "");
    try {
      value = JSON.parse(cleaned);
    } catch {
      return undefined;
    }
  }
  if (value === null || typeof value !== "object" || Array.isArray(value)) return undefined;
  const keys = Object.keys(value);
  const paragraph = (value as Record<string, unknown>).paragraph;
  return keys.length === 1 && typeof paragraph === "string" ? paragraph : undefined;
}
