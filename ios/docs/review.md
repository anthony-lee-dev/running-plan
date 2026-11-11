# Weekly review and proposals

Part of the iOS guide (`ios/CLAUDE.md` has the index). Read this before changing `Features/Review`.

## Weekly review and proposals (DK-Review, issue #71)

- `Features/Review/`: `ReviewModel` (header, tiles, key runs, check-in line, inbox card) and `ProposalCardModel` (title,
  reason, before to after rows, locked rows, stale) are pure and unit-tested; `ReviewView`, `ProposalCardView` and
  `ReviewSettingsSheet` only draw. `ReviewServing` / `APIReviewService` wrap `getWeeklyReview`, `generateProposals`,
  `listProposals`, `acceptProposal`, `dismissProposal` and the profile's review setting.
- The API has no user name and no per-session feel, so the headline drops the name ("A steady week") and a key run's note is
  its outcome (Done, Missed, no make-up, Skipped, Coming up); the check-in averages become one line. A proposal has only a
  `reason`, so `ProposalCardModel` works the title out from its changes ("Ease Saturday's long run", "Drop ...", "Swap ...").
- `ReviewStore` (owned by `RootView`, keyed on plan id, content revision, day, scene phase and the inbox or review closing)
  does not decide when a review is due: from this week back (at most two weeks, for a custom review day) the first week
  whose review has `due` is shown. With none due, this week's review shows only if proposals are pending (an urgent one).
  A due review calls `generateProposals` once per plan revision, because the review endpoint never makes proposals; every
  import match or edit moves the revision, which is how "After every import" works without touching `InboxStore`. The
  server raises pain proposals itself on a check-in; a missed key session is only found when `generate` runs, so with Weekly
  plus urgent it appears with the review, not before. Next shows an amber card (`next.review`) and a badge on its tab.
- `ProposalsStore` + `ProposalList` are the reusable proposal UI: `show(_:planId:)` takes any list, `proposeInterviewRerun`
  makes an `interview_rerun` proposal and shows it. Goal and settings (#77) presents `ProposalList` for it and
  `ReviewSettingsSheet` for the frequency and day.
- `ProposalCardModel` sorts rows by date itself (proposals stored before #133 list all drops first); when folded rows hold
  both kinds, `moreText` reads "and 40 more (25 added, 15 dropped)". A re-run's goal line ends "N weeks in total".
- Stale is compared live: `baseContentRevision` against the plan's `contentRevision` (accepting one proposal makes the others
  stale at once). A stale card has its actions off, "This suggestion is out of date" and Refresh (generate, then re-read the
  pending list). A 409 on accept reloads the plan; `stale_proposal` keeps the card with that reason, anything else (already
  decided elsewhere) reloads the list. Accepting replaces the plan with the reply (`PlanStore.replace(plan:)`) and leaves an
  "Applied" row; user-owned sessions stay locked unless "Include my own sessions" is on (`includeUserOwned`).
- The review screen opens the inbox itself as a cover (not through `RootView`), and reloads when it or the settings sheet
  closes. `ReviewUITests` starts a plan in the previous month so the review is due and key sessions were missed.
- The review frequency lives on the profile (`PATCH /v1/profile`, `If-Match` the profile revision, `review` replaced whole,
  so the day goes back with the frequency). The setting is reached from the review's footer and from Goal and settings (see below).
