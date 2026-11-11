# Activities, matches, suggested sessions

Part of the API guide (`api/CLAUDE.md` has the index). Read this before changing `src/domain/activities.ts`, `matches.ts`, `suggestions.ts` and their routes.

- Activities (task 2.11, `src/domain/activities.ts`): an upload dedupes on `source` + `externalId` (unchanged is
  `duplicate`, changed is `updated`) and, for Garmin re-writes with a new id, on the same type with the start within
  2 minutes and duration and distance within 3% (60 s, 100 m floors). Such a re-write keeps the stored id and values
  and only fills gaps, so two copies of one run in Health settle; the disposition always stays. The D1 store does one
  read (a day either side of the batch, plus the batch's source ids at any date) and one `db.batch` write, which fails
  whole on a clashing insert rather than dropping it. Keep
  every request to a few queries: Workers Free allows 50 D1 queries per request, and a batch counts as one.
- Matches (task 2.12, `src/domain/matches.ts`): one match per session and per activity; matching an activity
  elsewhere moves it. Confirming sets the session `done` (new revision, plan `contentRevision` + 1) and the activity
  `matched`; unlinking, downgrading to a suggestion or a new disposition undoes only what the match did. The route
  loads the state, the pure `planMatchChange` decides, and `MatchStore.apply` writes it in one D1 batch whose first
  statement aborts it (`json('{')`) if anything read has changed; the route retries up to three times.
  Deleting a session or a plan unlinks its matches (task 2.21): the match rows go and an activity they had matched
  returns to the inbox with a new revision. The D1 store does it in the delete's batch, guarded by the tombstone time
  just written, so a refused delete unlinks nothing; the memory plan store calls the match store through
  `onSessionsDeleted`. Reads still skip matches of deleted sessions, for rows written before this.
- Suggested sessions (task 2.12, `src/domain/suggestions.ts`): the upload results carry `suggestedSessionId` for
  every activity of the batch still in the inbox (a re-send gets it again). It is only returned, never written as a
  match row; the client confirms with `PUT /match`. Candidates come from `MatchStore.suggestionCandidates` (one query:
  live `planned` sessions on the batch's dates with no match). Rules: same local date, run workouts to easy/long/
  intervals/tempo, strength to strength, other types to custom, never rest; planned time (`plannedTimeSec`) within a
  factor of 2 of the duration (a session with no planned time is allowed but ranks last); closest fit first, and a
  session is suggested to at most one activity per batch. Starting values for the coach review (H.1).
