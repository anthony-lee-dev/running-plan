// The checks every run summary paragraph must pass before it is shown or stored (issue #132). The model only rewords
// facts the server computed, so a paragraph with a number the facts do not hold, medical or advice wording, a superlative
// the data cannot back, or the wrong shape is refused and the template is shown instead. A run with a pain flag gets a
// stricter wording check. Pure: no I/O.
import { allowedNumbers, numbersIn, type RunFacts } from "./run-facts";

export type CheckFailure = "empty" | "shape" | "number" | "wording" | "strict_wording";

const MEDICAL =
  /\b(inj\w*|pain\w*|hurt\w*|ach(?:e|es|ed|ing)|strain\w*|sprain\w*|tendon\w*|tendin\w*|fractur\w*|doctors?|physio\w*|diagnos\w*|medic\w*|clinic\w*|overtrain\w*|over-train\w*|overuse|risks?|risky|danger\w*|symptom\w*|sore\w*|sick\w*|illness|niggles?|discomfort|condition|health\w*|treat\w*|rehab\w*|recover\w*|burn-?out)\b/i;
const ADVICE = /\b(should|must|need to|needs to|ought|try to|consider|recommend\w*|advice|advis\w*|suggest\w*|make sure|be careful|avoid|don't|do not|take it|you can|you could|why not)\b/i;
const SUPERLATIVE = /\b(personal best|personal record|PB|PR|record|best ever|fastest|slowest|longest|shortest|all-time|breakthrough|milestone)\b/;
/** With pain flagged: nothing that reads as advice on training through it, reassurance, or praise. */
const STRICT =
  /\b(easier|ease|gentle|gently|rest\w*|careful\w*|cautious\w*|listen\w*|push\w*|tough|struggl\w*|fatigu\w*|tired|heavy|limit\w*|stop\w*|continu\w*|keep|back off|build|body|legs?|tight\w*|stiff\w*|warning|worr\w*|concern\w*|problem\w*|issue\w*|good|great|well done|strong|impressive|proud|brave|nice|fine|solid|encourag\w*|safe\w*)\b/i;

const EMOJI = /\p{Extended_Pictographic}/u;
const URL = /https?:\/\/|www\.|\w+\.(com|net|org|io|app)\b/i;
const MARKDOWN = /[*#`_[\]|<>~]|^\s*[-+]\s|\n/m;
const NON_LATIN_LETTER = /[^\p{Script=Latin}\p{N}\p{P}\p{S}\p{Z}]/u;

export const MIN_WORDS = 12;
export const MAX_WORDS = 130;
export const MAX_WORDS_PAIN = 90;

const wordCount = (text: string) => text.trim().split(/\s+/).filter(Boolean).length;

export function checkParagraph(text: string, facts: RunFacts): { ok: true } | { ok: false; reason: CheckFailure } {
  const trimmed = text.trim();
  if (trimmed.length === 0) return { ok: false, reason: "empty" };
  const words = wordCount(trimmed);
  const max = facts.pain ? MAX_WORDS_PAIN : MAX_WORDS;
  if (words < MIN_WORDS || words > max || trimmed.includes("!") || EMOJI.test(trimmed) || URL.test(trimmed) || MARKDOWN.test(trimmed) || NON_LATIN_LETTER.test(trimmed)) {
    return { ok: false, reason: "shape" };
  }
  const allowed = allowedNumbers(facts);
  if (numbersIn(trimmed).some((n) => !allowed.has(n))) return { ok: false, reason: "number" };
  if (MEDICAL.test(trimmed) || ADVICE.test(trimmed) || SUPERLATIVE.test(trimmed)) return { ok: false, reason: "wording" };
  if (facts.pain && STRICT.test(trimmed)) return { ok: false, reason: "strict_wording" };
  return { ok: true };
}
