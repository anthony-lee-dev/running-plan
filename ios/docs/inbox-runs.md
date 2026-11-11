# HealthKit import, the inbox, matching runs

Part of the iOS guide (`ios/CLAUDE.md` has the index). Read this before changing `Features/Inbox`, HealthKit import.

## Import inbox (task 4.3)

- `Features/Inbox/`: `InboxModel` (pure: cards, "Match to a session" choices, missed sessions) and `LocalDay` (a start
  `Date` in the workout's own zone to `YYYY-MM-DD`) are unit-tested; `HealthWorkoutMapper` (pure) turns Health workouts
  and manual entries into upload records; `InboxStore` drives `InboxServing` (the activity endpoints) and
  `HealthImporting` (HealthKit in `LiveHealthImporter`, a fake in tests); `InboxScreen` only draws.
- Health read access is asked for only from the user's tap on "Check Health for new workouts"; opening the inbox imports
  only when access was already given, so no system prompt appears unasked (and UI tests are never blocked by one).
  A workout's `localDate` uses the zone in its Health metadata, else the device's. Uploads skip a record with a bad
  duration and drop bad optional fields (one bad field makes the API refuse the whole batch), in batches of 200.
- The server's `suggestedSessionId` is not stored, so `InboxStore` keeps it for this run; the model falls back to the
  same local date, a fitting type (mirrors `fits` in `api/src/domain/suggestions.ts`) and a session no other card holds.
  Two runs on one day: the second is offered the day's session by hand until the first is confirmed.
- Next has an always-visible "Import inbox" card (`next.inbox`): it is the way in to the inbox when empty and to manual entry.
  A confirmed match is merged into `PlanStore` (`replace(session:...)`) so Next and Week show the session done.
- The HealthKit query has no type, name or metadata filter (issue #134). The session page reads Health through
  `InboxStore.openSessionPage()` (`load()`, so not again within 5 minutes of an import) before "Match a run" lists.
  `sourceLabel` cuts by UTF-16 units, the API's length: one over-long `sourceApp` makes it refuse the whole batch.
- `generateProposals` is not called from the inbox: the review does it (see "Weekly review and proposals").

## Runs from any session (issue #105)

- No API change: `PUT /v1/sessions/{id}/match` replaces the session's run (the old one returns to the inbox) and moves a
  run matched elsewhere (that session goes back to `planned`); `DELETE` unmatches; `GET /v1/activities` without `inbox`
  returns every run with its `match`.
- The session page shows the matched run with Change and Unmatch (`session.run.change`, `session.run.unmatch`), or
  "Match a run" (`session.run.match`) for a live non-rest session dated today or earlier with no run. The picker lists
  unmatched runs of a fitting type, nearest the session's day first (`RunMatchModel`, pure). That includes extra and
  ignored runs, tagged "Extra run" / "Ignored" (issue #134), because the all-runs list lets the user match those too. It
  reads `InboxStore.allRuns` (`matchCandidates(for:)`), never `activities`: the inbox endpoint leaves extra and ignored runs out.
- "All imported runs" (`inbox.allRuns`, `RunsScreen`) lists matched, inbox, extra and ignored runs; re-map with
  "Match to a session" / "Change session", "Unmatch", "Back to inbox". `InboxStore.allRuns` is loaded on demand.
- A move changes a second session the reply does not carry, so `InboxStore` reloads the plan when the match displaces
  one (known from `allRuns`); otherwise the old session would stay `done` locally and its next edit would 409.
- The Next tab's inbox card is unchanged. The UI test covers unmatch and rematch from the runs list; the session page
  is pinned by `RunMatchModelTests` (no UI test: the first session of a fresh plan is usually in the future).
