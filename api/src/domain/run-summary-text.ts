// The template summary of a run (issue #132): the text shown when no model text exists, and the oracle the model's text
// is held to. Also the "what to do next" line, which the server writes (never the model). Pure: no I/O.
import { formatDistance, formatDuration, planTypeName, statedGoals, type RunFacts } from "./run-facts";
import type { SessionType, Step } from "./plan-input";

/** Shown word for word with a pain flag, in place of the "what to do next" line. Same words as the check-in screen. */
export const PAIN_GUIDANCE = "If something hurts, stop and talk to a qualified professional. This app can't give medical advice.";

const article = (word: string) => (/^[aeiou]/i.test(word) ? "an" : "a");

/** The paragraph, built from the facts alone. Deterministic. */
export function templateParagraph(facts: RunFacts): string {
  const sentences: string[] = [];
  const first = [facts.distance ? `${facts.distance} in ${facts.time}` : `${facts.time} of running`];
  if (facts.pace) first.push(`at ${facts.pace}`);
  let opening = first.join(" ");
  if (facts.avgHr) opening += `, with an average heart rate of ${facts.avgHr}`;
  sentences.push(`${opening}.`);

  const v = facts.vsRecent;
  if (v) {
    sentences.push(
      v.pace.dir === "same"
        ? `Your ${v.count} other runs of about this length in the last ${v.window} averaged ${v.avgPace}, about the same pace as this one.`
        : `You ran ${v.pace.text} than your ${v.count} other runs of about this length in the last ${v.window}, which averaged ${v.avgPace}.`,
    );
    if (v.hr && v.avgHr) {
      sentences.push(v.hr.dir === "same" ? `Your heart rate was about the same as their average of ${v.avgHr}.` : `Your heart rate was ${v.hr.text} than their average of ${v.avgHr}.`);
    }
  } else {
    sentences.push("There are not yet enough runs of about this length in the last 4 weeks to compare this one with.");
  }

  if (facts.plan && (facts.plan.distance || facts.plan.time)) {
    const planned = [facts.plan.distance, facts.plan.time].filter(Boolean).join(" in about ");
    sentences.push(`It was matched to ${article(planTypeName(facts.plan.type))} ${planTypeName(facts.plan.type)} that planned ${planned}.`);
  } else if (facts.plan) {
    sentences.push(`It was matched to ${article(planTypeName(facts.plan.type))} ${planTypeName(facts.plan.type)} in your plan.`);
  }
  if (facts.feel !== undefined && facts.effort !== undefined) sentences.push(`You rated how it felt ${facts.feel} out of 5 and the effort ${facts.effort} out of 10.`);
  else if (facts.feel !== undefined) sentences.push(`You rated how it felt ${facts.feel} out of 5.`);
  else if (facts.effort !== undefined) sentences.push(`You rated the effort ${facts.effort} out of 10.`);
  return sentences.join(" ");
}

const WEEKDAY = ["Sunday", "Monday", "Tuesday", "Wednesday", "Thursday", "Friday", "Saturday"] as const;
const DAY_MS = 86_400_000;
const dayNumber = (date: string) => Math.floor(Date.parse(`${date}T00:00:00Z`) / DAY_MS);

export interface NextCandidate {
  date: string;
  type: SessionType;
  status: "planned" | "done" | "skipped";
  steps: Step[];
  deletedAt?: string | null;
}

/**
 * "Next planned session: Easy run, 6 km, on Thursday." The earliest open running or strength session dated after `today`.
 * Rest days and sessions already done or skipped are passed over. Only what the plan states is named: no invented distance.
 */
export function nextStepLine(sessions: NextCandidate[], today: string): string | undefined {
  const next = sessions
    .filter((s) => !s.deletedAt && s.status === "planned" && s.type !== "rest" && s.date > today)
    .sort((a, b) => (a.date < b.date ? -1 : a.date > b.date ? 1 : 0))[0];
  if (!next) return undefined;
  const name = planTypeName(next.type);
  const goals = statedGoals(next.steps);
  const detail = goals.distanceM !== undefined ? formatDistance(goals.distanceM) : goals.timeSec !== undefined ? formatDuration(goals.timeSec) : undefined;
  const days = dayNumber(next.date) - dayNumber(today);
  const when = days === 1 ? "tomorrow" : days < 7 ? `on ${WEEKDAY[new Date(`${next.date}T00:00:00Z`).getUTCDay()]}` : `on ${WEEKDAY[new Date(`${next.date}T00:00:00Z`).getUTCDay()]} (in ${days} days)`;
  const label = `${name.charAt(0).toUpperCase()}${name.slice(1)}`;
  return `Next planned session: ${label}${detail ? `, ${detail}` : ""}, ${when}.`;
}

/** Bump with any change to the prompt or the facts' meaning: stored paragraphs of another version are written again. */
export const PROMPT_VERSION = "v1";
