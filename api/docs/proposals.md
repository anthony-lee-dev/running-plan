# Proposal engine and API

Part of the API guide (`api/CLAUDE.md` has the index). Read this before changing `src/domain/proposals.ts`, `proposal-model.ts`, `src/http/proposals.ts`.

- Proposal engine (`src/domain/proposals.ts`, task 2.13): `proposeAdjustments({ plan, checkIns, matches, today })`
  returns proposal drafts and never edits the plan. Rules: a missed key session (last 14 days, not done, no confirmed
  match) is dropped, one proposal each and urgent; pain in the last 7 days makes next week 30% lighter with hard
  sessions turned easy (urgent, and the only load proposal); two of the last three after-session check-ins "much
  harder" (effort 8+ or feel 1) ease next week by 15%; three easy ones in a row add 5% to next week's easy and long
  runs. User-owned sessions are included but flagged `userOwned` (locked unless the user opts in); blank plans are
  off unless `adaptive`. Each draft has a stable `key` so a dismissed proposal is not made again; the API task
  (2.14) adds ids, the plan revision and the status. Numbers are starting values for the coach review (H.1).
- Proposals API (task 2.14, `src/http/proposals.ts`, `ProposalStore`, `src/domain/proposal-model.ts`, `src/domain/rerun.ts`):
  - `generate` without `interview` runs the 2.13 engine on the plan, its matches and check-ins, and stores what is new:
    review setting Off makes none, and a draft whose `key` is already pending, accepted or dismissed is not made again
    (`proposals.draft_key`, migration 0005). With `interview` it always makes one `interview_rerun`, even with reviews Off.
  - **Re-run** (`proposeRerun`, pure, ids passed in): weeks run from the plan's start date in blocks of seven days, and the
    current week stays; the first week that may change is the first one starting after `today` (week 0 if the plan has not
    begun). The engine plans from that boundary. Deleted: system-owned `planned` sessions from the boundary on; kept:
    everything earlier, user-owned sessions and anything done or skipped. Created: draft sessions from the boundary up to the
    plan's new last day. `planChanges` carries goal, `weekCount` (start date never moves; the plan stretches or shrinks to
    the draft's end, never below the weeks already lived or a kept session, at most 52), the weeks from the boundary (notes the
    user wrote stay) and the new engine info. 400 `no_future_weeks`, `no_plan_fits` or `too_many_changes` (over the spec's 400
    changes); 409 `plan_changed` if the plan keeps moving while it is made. `changes` are ordered by date, a drop before its
    replacement on the same day (not all drops first), so a short preview shows both sides (#133). The reason names weeks
    counted from 1 ("weeks 3 to 12"), matching the plan's total length.
  - **Stale**: reads (`list`, `usedKeys`) report a pending proposal as stale as soon as the plan's `contentRevision` moves
    past `baseContentRevision`; `markStale` writes it (sync, above). `create` writes nothing if the plan moved, so a race
    between reading the plan and storing never leaves a stale proposal pending. `accept` and `dismiss` re-check inside their
    transaction: D1 runs the claim first and aborts the whole batch (`json('{')` on `changes() = 0`, like the match store)
    if it changed nothing. 409 `stale_proposal` or `proposal_not_pending`.
  - **Accept** applies update, create and delete changes in one batch, skipping `userOwned` ones unless `includeUserOwned`,
    tombstones deleted sessions and unlinks their matches (2.21), moves the plan's `contentRevision` once (and its `revision`
    when plan-level changes apply) and returns `PlanDetail`. Deleting a plan tombstones its proposals.
  - **Pain flag**: a check-in with `pain: true` (the endpoint, and `checkin.create` in sync) raises the urgent proposal at once
    under Weekly plus urgent only, after the check-in is saved, best effort and logged without data on failure. Check-ins carry
    no date, so "today" is the later of the session's date and the server's UTC date. A missed key session raises nothing by
    itself (no event); the client's `generate` finds it.
  - The spec lists no 400 for `acceptProposal`, `dismissProposal` or `listProposals` (a bad body or `status`), nor 409 or
    400 variants for `generateProposals`; the routes answer them anyway (follow-up spec PR).
