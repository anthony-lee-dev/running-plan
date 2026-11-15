# The saved plan (Next, Week, Whole)

Part of the iOS guide (`ios/CLAUDE.md` has the index). Read this before changing `Features/Plan`.

## The saved plan (task 3.5)

- `Features/Plan/`: `PlanStore` (owned by `RootView`, shared by the tabs) loads the active plan on launch and, after a
  save, the saved plan by id. Signed out or a 401 that survives the refresh shows the empty state ("Set a goal")
  without an error; offline or a server error shows a retry. Kept in memory only: the on-device store is slice 5.
- The active plan is the most recently updated one on the first `listPlans` page. The list is ordered by start date
  then id, not by save time, so `updatedAt` picks the latest save. Session edits do not move a plan's `updatedAt`.
- `PlanSchedule` is pure: it takes `today` as `YYYY-MM-DD` and counts weeks in calendar days from `startDate`, never
  with `Date` intervals. It works out the week, today's sessions, the next session and week totals. Distance actually
  run comes from the progress endpoint through `DistanceDone` (see "Progress" below); `PlanSchedule` itself only uses session status.
- UI tests that touch the API pass `-auth.reset YES`, so an earlier test's sign-in (and plan) never replaces "Set a goal".
- Screens: `NextModel`, `WeekModel` and `WholeModel` are pure (built from `PlanSchedule`) and pinned by unit tests;
  `NextView`, `WeekView` and `WholeView` only draw them. Snapshot tests render the views with `PlanFixture` (the boards'
  plan, today Wed 2026-10-28) through `BoardSnapshot`.
- Next's title is today's date (`NextModel.title`, "Wednesday, Oct 28") with the plan position above it (`eyebrow`,
  "Week 4 of 10 · Build", id `next.plan`). "Ready when you are" was removed at the human's request (issue #186); do
  not bring a tagline back. With the "Done today" card showing, "Open workout" is an outline button (one filled
  button on the screen).
- VoiceOver reads paces in words through `PaceFormat.spoken` ("6 minutes 25 to 7 minutes 10 per kilometre").
