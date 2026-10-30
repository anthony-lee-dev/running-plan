// Strength sessions (design 6.4): one or two short sessions a week, placed away from the hard runs, from a small
// curated library of bodyweight and dumbbell movements. The library and the doses are starting values for the coach
// review (backlog H.1). Pure.

export type Equipment = "bodyweight" | "dumbbells";

export interface Exercise {
  id: string;
  name: string;
  equipment: Equipment;
  /** Reps per set, or a hold in seconds; never both. */
  reps?: number;
  holdSec?: number;
}

/** The whole library. An exercise id in a plan is always one of these. */
export const EXERCISES: readonly Exercise[] = [
  { id: "bodyweight-squat", name: "Bodyweight squat", equipment: "bodyweight", reps: 12 },
  { id: "reverse-lunge", name: "Reverse lunge", equipment: "bodyweight", reps: 10 },
  { id: "glute-bridge", name: "Glute bridge", equipment: "bodyweight", reps: 12 },
  { id: "step-up", name: "Step-up", equipment: "bodyweight", reps: 10 },
  { id: "calf-raise", name: "Single-leg calf raise", equipment: "bodyweight", reps: 12 },
  { id: "bird-dog", name: "Bird dog", equipment: "bodyweight", reps: 10 },
  { id: "plank", name: "Plank", equipment: "bodyweight", holdSec: 30 },
  { id: "side-plank", name: "Side plank", equipment: "bodyweight", holdSec: 25 },
  { id: "goblet-squat", name: "Goblet squat", equipment: "dumbbells", reps: 12 },
  { id: "dumbbell-rdl", name: "Dumbbell Romanian deadlift", equipment: "dumbbells", reps: 12 },
  { id: "split-squat", name: "Dumbbell split squat", equipment: "dumbbells", reps: 10 },
  { id: "dumbbell-calf-raise", name: "Dumbbell calf raise", equipment: "dumbbells", reps: 15 },
  { id: "farmer-carry", name: "Farmer carry", equipment: "dumbbells", holdSec: 40 },
];

const byId = new Map(EXERCISES.map((e) => [e.id, e]));
export const exerciseById = (id: string): Exercise | undefined => byId.get(id);

/** Two alternating sessions per equipment choice: legs, hinge, single leg, calves, core. */
const ROUTINES: Record<Equipment, [string[], string[]]> = {
  bodyweight: [
    ["bodyweight-squat", "glute-bridge", "reverse-lunge", "calf-raise", "plank"],
    ["step-up", "glute-bridge", "bodyweight-squat", "calf-raise", "side-plank"],
  ],
  dumbbells: [
    ["goblet-squat", "dumbbell-rdl", "split-squat", "dumbbell-calf-raise", "plank"],
    ["split-squat", "dumbbell-rdl", "goblet-squat", "dumbbell-calf-raise", "farmer-carry"],
  ],
};

const REST_SEC = 45;
const SECONDS_PER_REP = 3;

export interface StrengthStep {
  kind: "exercise";
  exerciseId: string;
  sets: number;
  reps?: number;
  durationSec?: number;
  restSec: number;
  effort: "easy" | "moderate";
  loadNote?: string;
}

export interface StrengthSession {
  steps: StrengthStep[];
  /** For the session's notes: "About 20 minutes." */
  minutes: number;
}

/**
 * One strength session. `variant` alternates the routine, `phase` sets the dose: two easy sets in the base and the
 * taper, three moderate sets in the build and the peak (two when cautious).
 */
export function strengthSession(equipment: Equipment, phase: "base" | "build" | "peak" | "taper", variant: number, cautious: boolean): StrengthSession {
  const heavy = (phase === "build" || phase === "peak") && !cautious;
  const sets = heavy ? 3 : 2;
  const routine = ROUTINES[equipment][variant % 2]!;
  const steps = routine.map((id): StrengthStep => {
    const exercise = byId.get(id)!;
    return {
      kind: "exercise",
      exerciseId: id,
      sets,
      ...(exercise.reps !== undefined ? { reps: exercise.reps } : {}),
      ...(exercise.holdSec !== undefined ? { durationSec: exercise.holdSec + (heavy ? 10 : 0) } : {}),
      restSec: REST_SEC,
      effort: heavy ? "moderate" : "easy",
      ...(exercise.equipment === "dumbbells" ? { loadNote: heavy ? "Pick a weight that leaves about 2 reps in reserve on the last set." : "Pick a weight that leaves 3 or 4 reps in reserve on every set." } : {}),
    };
  });
  const seconds = steps.reduce((sum, s) => sum + s.sets * ((s.durationSec ?? (s.reps ?? 0) * SECONDS_PER_REP) + s.restSec), 0);
  return { steps, minutes: Math.max(5, Math.round(seconds / 300) * 5) };
}

const circular = (a: number, b: number): number => Math.min(Math.abs(a - b), 7 - Math.abs(a - b));

/**
 * Days (offsets within the week) for strength sessions: never a hard day or the day before one, never an
 * unavailable day, and never leaving the week without a rest day. Days with no run come first, then easy-run days;
 * two sessions are kept apart.
 */
export function placeStrength(input: { runs: { offset: number; hard: boolean }[]; unavailable: Set<number>; count: number }): number[] {
  const hard = input.runs.filter((r) => r.hard).map((r) => r.offset);
  const forbidden = new Set<number>([...hard, ...hard.map((h) => (h + 6) % 7)]);
  const running = new Set(input.runs.map((r) => r.offset));
  const chosen: number[] = [];
  for (let n = 0; n < input.count; n++) {
    const candidates = [0, 1, 2, 3, 4, 5, 6].filter((k) => !forbidden.has(k) && !input.unavailable.has(k) && !chosen.includes(k));
    const busyDays = new Set([...running, ...chosen]);
    // A session on a free day uses up a rest day: keep at least one.
    const usable = candidates.filter((k) => running.has(k) || busyDays.size < 6);
    const best = usable.sort((a, b) => {
      const free = Number(running.has(a)) - Number(running.has(b)); // free days first
      const apart = chosen.length > 0 ? Math.min(...chosen.map((c) => circular(b, c))) - Math.min(...chosen.map((c) => circular(a, c))) : 0;
      return free || apart || a - b;
    })[0];
    if (best === undefined) break;
    chosen.push(best);
  }
  return chosen.sort((a, b) => a - b);
}
