# Plan vs actual and check-in

Part of the iOS guide (`ios/CLAUDE.md` has the index). Read this before changing `Features/CheckIn`.

## Plan vs actual and check-in (DK-CheckIn, issue #68)

- `Features/CheckIn/`: `CheckInModel` (pure, unit-tested) compares the session with the matched run as a whole (no rep
  detail in imported summaries): distance and time bars (fill = done / planned, capped at 1; "~" when the time is an
  estimate from distance), and a pace row. Only easy and long runs are judged against their pace range (band and marker
  on a scale one range-width either side); intervals and tempo show the average against the planned average, since it
  takes in the warm-up and jogs. Strength and cross-training show time only.
- "How did it feel?" sends `feel` / `effortFelt`: Easier 4/4, About right 3/6, Harder 2/8 (`when: after`), so the answers
  reach the server's proposal rules (`HARD_EFFORT`, `EASY_FEEL`, `EASY_EFFORT` in `api/src/domain/proposals.ts`); change both
  together. Pain is yes/no. The pain guidance always shows, whatever the review setting (§6.6a), and becomes a notice card on Yes.
- A match confirmed from the inbox (Confirm or the picker) sets `InboxStore.pendingCheckIn` (session plus the run's fields,
  kept before the lists reload); `InboxScreen` presents `CheckInScreen` full screen. The picker's choice is confirmed in the
  sheet's `onDismiss`, so the cover is never presented while the sheet is still leaving. Save sends through
  `PlanStore.checkIn(sessionId:after:id:)` (id made once per visit) and closes; "Skip for now" and the back link send nothing.
  A saved check-in takes away the inbox's Undo (`finishCheckIn(saved: true)`): unmatching would leave the stored check-in
  feeding proposals for a session no longer done. Opening the inbox drops a check-in left pending from an earlier visit.
- Not wired: a check-in from the session page or after a re-map from the all-runs list.
- UI-test request counts are for the whole run (one server), so compare before and after an action.
