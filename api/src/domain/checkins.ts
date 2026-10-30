// Before- and after-session check-ins (design §8.3, §10): validation of `CheckInCreate`. The pain flag is coarse by
// design. Pure: no I/O.
import type { FieldError } from "./profile";

export interface CheckInFields {
  when: "before" | "after";
  /** 1 (awful) to 5 (great). */
  feel: number;
  /** 1 to 10, after a session only. */
  effortFelt?: number;
  pain?: boolean;
  note?: string;
}

const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;
const KEYS = ["id", "when", "feel", "effortFelt", "pain", "note"];
const isInt = (v: unknown, min: number, max: number): v is number => Number.isInteger(v) && (v as number) >= min && (v as number) <= max;

/** Validates a create body. Reports every problem, not just the first. */
export function parseCheckInCreate(body: unknown): { ok: true; value: CheckInFields & { id: string } } | { ok: false; errors: FieldError[] } {
  if (body === null || typeof body !== "object" || Array.isArray(body)) return { ok: false, errors: [{ path: "/", message: "Send the check-in" }] };
  const b = body as Record<string, unknown>;
  const errors: FieldError[] = [];
  for (const key of Object.keys(b)) if (!KEYS.includes(key)) errors.push({ path: `/${key}`, message: "Unknown field" });
  if (!(typeof b.id === "string" && UUID.test(b.id))) errors.push({ path: "/id", message: "A UUID made by the client" });
  if (b.when !== "before" && b.when !== "after") errors.push({ path: "/when", message: "Use before or after" });
  if (!isInt(b.feel, 1, 5)) errors.push({ path: "/feel", message: "1 (awful) to 5 (great)" });
  if ("effortFelt" in b) {
    if (!isInt(b.effortFelt, 1, 10)) errors.push({ path: "/effortFelt", message: "1 to 10" });
    else if (b.when === "before") errors.push({ path: "/effortFelt", message: "Only after a session" });
  }
  if ("pain" in b && typeof b.pain !== "boolean") errors.push({ path: "/pain", message: "true or false" });
  if ("note" in b && !(typeof b.note === "string" && b.note.length <= 500)) errors.push({ path: "/note", message: "Up to 500 characters" });
  if (errors.length > 0) return { ok: false, errors };
  return {
    ok: true,
    value: {
      id: b.id as string,
      when: b.when as CheckInFields["when"],
      feel: b.feel as number,
      ...("effortFelt" in b ? { effortFelt: b.effortFelt as number } : {}),
      ...("pain" in b ? { pain: b.pain as boolean } : {}),
      ...("note" in b ? { note: b.note as string } : {}),
    },
  };
}

/** True when a repeat carries the same check-in as the stored one (an absent pain flag is no pain). */
export function sameCheckIn(stored: CheckInFields & { sessionId: string }, input: CheckInFields & { sessionId: string }): boolean {
  return (
    stored.sessionId === input.sessionId &&
    stored.when === input.when &&
    stored.feel === input.feel &&
    stored.effortFelt === input.effortFelt &&
    (stored.pain ?? false) === (input.pain ?? false) &&
    stored.note === input.note
  );
}
