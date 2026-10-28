// Pace is always minutes per km, written like "6:30/km".

/** Formats a pace given in whole seconds per km, e.g. 390 -> "6:30/km". */
export function formatPace(secondsPerKm: number): string {
  if (!Number.isFinite(secondsPerKm) || secondsPerKm <= 0) {
    throw new RangeError(`pace must be a positive number of seconds, got ${secondsPerKm}`);
  }
  const total = Math.round(secondsPerKm);
  const minutes = Math.floor(total / 60);
  const seconds = total % 60;
  return `${minutes}:${seconds.toString().padStart(2, "0")}/km`;
}

/** Parses "6:30/km" or "6:30" into seconds per km. */
export function parsePace(text: string): number {
  const match = /^(\d{1,2}):([0-5]\d)(?:\/km)?$/.exec(text.trim());
  if (!match) throw new SyntaxError(`not a pace: "${text}"`);
  return Number(match[1]) * 60 + Number(match[2]);
}
