// One match change: load the state, let the pure rules decide, write it, and start again from a fresh read when
// something changed in between. Shared by the match routes and the upload's automatic matching (issue #186).
import { planMatchChange, type MatchChange, type MatchEffects, type MatchState } from "../domain/matches";
import { MatchConflictError, type Deps } from "../ports";

const ATTEMPTS = 3;

/**
 * `found` says whether the state has what the change needs; when it does not, the result is undefined (a 404 for
 * the routes). Throws MatchConflictError when the state kept moving.
 */
export async function changeMatch(
  deps: Deps,
  userId: string,
  ref: { sessionId?: string; activityId?: string },
  change: MatchChange,
  found: (s: MatchState) => boolean,
): Promise<MatchEffects | undefined> {
  for (let attempt = 1; ; attempt++) {
    const state = await deps.matches.load(userId, ref);
    if (!found(state)) return undefined;
    const now = deps.clock.now().toISOString();
    const effects = planMatchChange(state, change, now);
    try {
      await deps.matches.apply(userId, state, effects, now);
      return effects;
    } catch (error) {
      if (!(error instanceof MatchConflictError) || attempt >= ATTEMPTS) throw error;
    }
  }
}
