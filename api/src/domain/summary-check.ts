// The checks every run summary paragraph must pass before it is shown or stored (issue #132). The model only rewords
// facts the server computed, so a paragraph with a number the facts do not hold (or one attached to the wrong unit or
// thing), a comparison the facts do not make, medical or advice wording, a superlative the data cannot back, or the wrong
// shape is refused and the template is shown instead. A run with a pain flag gets a stricter wording check. Pure: no I/O.
import { allowedDirections, allowedQuantities, type RunFacts } from "./run-facts";
import { numbersIn } from "./run-facts";

export type CheckFailure = "empty" | "shape" | "number" | "claim" | "wording" | "strict_wording";

const MEDICAL =
  /\b(inj\w*|pain\w*|hurt\w*|ach(?:e|es|ed|ing)|strain\w*|sprain\w*|tendon\w*|tendin\w*|fractur\w*|doctors?|physio\w*|diagnos\w*|medic\w*|clinic\w*|overtrain\w*|over-train\w*|overuse|risks?|risky|danger\w*|symptom\w*|sore\w*|sick\w*|illness|niggles?|discomfort|condition|health\w*|treat\w*|rehab\w*|recover\w*|burn-?out|cramp\w*|swell\w*|swollen|blister\w*|knees?|shins?|ankles?|hamstrings?|calf|calves|hips?|fatigue\w*|exhaust\w*|dizz\w*|breath\w*|chest|cardiac|dehydrat\w*|limp\w*)\b/i;
const ADVICE = /\b(should|must|need to|needs to|ought|try to|consider|recommend\w*|advice|advis\w*|suggest\w*|make sure|be careful|avoid|don't|do not|take it|you can|you could|why not|next time|tomorrow|rest day)\b/i;
const SUPERLATIVE = /\b(personal best|personal record|PB|PR|record|best|worst|most|least|quickest|fastest|slowest|longest|shortest|all-time|breakthrough|milestone|excellent|fantastic|amazing|perfect\w*|ideal|impressive|congrat\w*)\b/i;
/** Claims about the plan the facts cannot make: the facts hold no actual-versus-plan comparison. */
const PLAN_CLAIM = /\b(exactly|precisely|hit|met|on target|on plan|on track|off track|missed|short of|fell short|achiev\w*|reached|completed|nailed|bang on)\b/i;
/** Comparison words. Each must be the very word of a comparison the facts make; the opposite or an invented one is a claim. */
const COMPARISON = /\b(quicker|faster|slower|higher|lower|better|worse|harder|easier|improv\w*|quick|fast|slow|stronger|weaker|ahead|behind|beat|exceed\w*|surpass\w*|up from|down from)\b/gi;
const NEGATION = /\b(?:no|not|never|hardly|barely|without)\b(?:\s+\S+){0,3}\s*$|n't(?:\s+\S+){0,3}\s*$/i;
/** With pain flagged: nothing that reads as advice on training through it, reassurance, or praise. */
const STRICT =
  /\b(easier|ease|gentle|gently|rest\w*|careful\w*|cautious\w*|listen\w*|push\w*|tough|struggl\w*|tired|heavy|limit\w*|stop\w*|continu\w*|keep|back off|build|body|legs?|tight\w*|stiff\w*|warning|worr\w*|concern\w*|problem\w*|issue\w*|good|great|well|well done|strong|proud|brave|nice|fine|solid|encourag\w*|safe\w*|steady|paced|relax\w*|slow|quick|fast|enjoy\w*|off|day|days|hard|better|worse)\b/i;

const NUMBER_WORDS = /\b(two|three|four|five|six|seven|eight|nine|ten|eleven|twelve|twenty|thirty|forty|fifty|hundred|thousand|half|double|twice|thrice|triple|percent|per cent)\b|%/i;
const EMOJI = /\p{Extended_Pictographic}/u;
const URL = /https?:\/\/|www\.|\w+\.(com|net|org|io|app)\b/i;
const MARKDOWN = /[*#`_[\]|<>~]|^\s*[-+]\s|\n/m;
const NON_LATIN_LETTER = /[^\p{Script=Latin}\p{N}\p{P}\p{S}\p{Z}]/u;

export const MIN_WORDS = 4;
export const MAX_WORDS = 130;
export const MAX_WORDS_PAIN = 90;

const wordCount = (text: string) => text.trim().split(/\s+/).filter(Boolean).length;
const norm = (n: string) => numbersIn(n)[0]!;

/**
 * Every number in the text must be one of these forms, and say what the facts say: a quantity with its unit that the facts
 * hold ("10.2 km", "5:41/km", "13 s/km", "152 bpm", "58 min"), "N out of 5" (feel) or "N out of 10" (effort), "N runs" for
 * the comparison's count, or "4 weeks". Anything else, such as "3 weeks", "152 beats" or a bare number, is invented.
 */
function numbersOk(text: string, facts: RunFacts): boolean {
  if (NUMBER_WORDS.test(text)) return false;
  const quantities = allowedQuantities(facts);
  const form = /(\d+(?::\d+)+|\d+(?:\.\d+)?)(?:\s?(s\/km|\/km|km|bpm|min|h)\b|\s+out of (5|10)\b|\s+(?:other\s+)?runs?\b|\s+weeks?\b)?/g;
  for (const m of text.matchAll(form)) {
    const value = norm(m[1]!);
    const whole = m[0];
    if (m[2]) {
      if (!quantities.has(`${value} ${m[2]}`)) return false;
    } else if (m[3]) {
      const expected = m[3] === "5" ? facts.feel : facts.effort;
      if (expected === undefined || String(expected) !== value) return false;
    } else if (/runs?$/.test(whole)) {
      if (facts.vsRecent?.count === undefined || String(facts.vsRecent.count) !== value) return false;
    } else if (/weeks?$/.test(whole)) {
      if (value !== "4") return false;
    } else return false;
  }
  return true;
}

function claimsOk(text: string, facts: RunFacts): boolean {
  const allowed = allowedDirections(facts);
  for (const m of text.matchAll(COMPARISON)) {
    const word = m[0].toLowerCase();
    if (!allowed.has(word)) return false;
    if (NEGATION.test(text.slice(Math.max(0, m.index! - 40), m.index!))) return false;
  }
  return true;
}

export function checkParagraph(raw: string, facts: RunFacts): { ok: true } | { ok: false; reason: CheckFailure } {
  const text = raw.trim().replace(/[‘’]/g, "'");
  if (text.length === 0) return { ok: false, reason: "empty" };
  const words = wordCount(text);
  const max = facts.pain ? MAX_WORDS_PAIN : MAX_WORDS;
  if (words < MIN_WORDS || words > max || text.includes("!") || EMOJI.test(text) || URL.test(text) || MARKDOWN.test(text) || NON_LATIN_LETTER.test(text)) {
    return { ok: false, reason: "shape" };
  }
  if (!numbersOk(text, facts)) return { ok: false, reason: "number" };
  if (MEDICAL.test(text) || ADVICE.test(text) || SUPERLATIVE.test(text) || PLAN_CLAIM.test(text)) return { ok: false, reason: "wording" };
  if (!claimsOk(text, facts)) return { ok: false, reason: "claim" };
  if (facts.pain && STRICT.test(text)) return { ok: false, reason: "strict_wording" };
  return { ok: true };
}
