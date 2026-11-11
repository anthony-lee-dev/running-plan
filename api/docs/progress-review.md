# Progress and the weekly review

Part of the API guide (`api/CLAUDE.md` has the index). Read this before changing `src/domain/insights.ts`, `src/http/progress.ts`, `reviews.ts`.

- Progress and the weekly review (`src/domain/insights.ts`, tasks 2.15 and 2.18): `computeProgress` and
  `computeWeeklyReview` are pure. A session is done when marked done or its match is confirmed; "missed" only after
  its day is over (so due can exceed done + skipped + missed by what is left today); actual volume comes from the
  confirmed activity, or the plan when a session was marked done by hand; strength and cross-training count toward
  time only. On track means 70% or more of the judged sessions done (at least 3 judged). A review looks back at a finished
  week: its review day is the first chosen weekday on or after the week's last day (the last day itself by default),
  and it is due for seven days from then; after an import it is also due once the week has something done. Thresholds are for the coach review (H.1).
- Weekly review API (task 2.18, `src/http/reviews.ts`, `GET /v1/plans/{planId}/reviews/{weekIndex}`): a read that never writes. It adds
  the plan's pending proposals (`ProposalStore.list`, so a moved plan's proposals are already stale and left out; none when reviews
  are Off or the plan is blank and not adaptive) and `looseEnds.inboxActivities` (`ActivityStore.countInbox`, the user's whole inbox,
  not only that week's dates) to `computeWeeklyReview`. About seven queries, in one `Promise.all` after the plan read. A week outside
  the plan, or not a number, is a 404 (the spec documents no 400); a missing or bad `today` is a 400 the spec does not list (checked
  after the token, so an unsigned call is still a 401; follow-up spec PR).
