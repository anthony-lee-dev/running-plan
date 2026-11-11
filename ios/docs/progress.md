# Progress screen and run totals

Part of the iOS guide (`ios/CLAUDE.md` has the index). Read this before changing `Features/Progress`.

## Progress (DK-Progress, issue #73)

- `Features/Progress/`: `ProgressModel` (pure, unit-tested) builds the screen from `getProgress` and the plan; `ProgressStore`
  loads it through `ProgressLoading` (`APIProgressLoader`); `ProgressOverview` only draws (not `ProgressView`, which would
  shadow SwiftUI's spinner); `ProgressScreen` handles no plan, loading and retry. `ProgressFixture` holds the board's reply.
- It reloads on a key of plan id, local day and every session's revision, so an edit or a match refreshes it
  (the day is read when the view redraws, not on a midnight timer); pull to refresh also reloads, and a failed refresh
  keeps what was shown. The chart runs through this week, at most the last 8 weeks (`maxBars`), with
  planned bars only and "Your first week's progress appears on your review day" until week 1 is over.
- The endpoint has no per-run detail, so the board's pace sentence and longest-run win are replaced: the goal card speaks
  about sessions done (on track, behind, or too early to say) and the win is the latest finished week when it was the biggest.

- Distance done (issue #74): `RootView` owns the one `ProgressStore` and loads it (key: plan, day, session revisions) for
  Next, Plan and Progress; `ProgressScreen` only reads it. `NextModel`, `WeekModel` and `WholeModel` take an optional
  progress reply through `DistanceDone` and keep their planned-only text when there is none or it is for another plan.
  Distance bars fill by ran / planned (capped at 1); Week's "plus N min cross-training" is the user's own sessions in the week
  that are not skipped (the reply cannot split running from other time); Whole shows ran / planned up to this week, and the goal card's
  "On track" badge and bar (whole weeks done plus this week's share).

## Your running on Progress (issue #137)

- No API or spec change: totals are worked out on the device from `InboxStore.allRuns` (every run, `listActivities`), the same
  rules as the web (`web/src/runTotals.ts`; change both together). `RunTotals` (pure) buckets running workouts on `localDate` into
  calendar weeks (Monday to Sunday, 8 shown) and months (6 shown); matched, inbox and extra runs count, ignored ones and other
  workout types do not. Pace is total time over total distance of the runs that have a distance; with none it is hidden.
  `RunningStatsModel` (pure) builds the card (tiles, comparison with the period before, bars, spoken summary, plan week) and
  `RunningStatsCard` draws it; `ProgressOverview` takes it as a `footer` so the DK-Progress layout above is unchanged.
- The plan week ("Plan week 4: 18.5 of 25 km planned") is labelled apart from "This week": a plan's weeks start on its own start
  date and the server's ran distance counts only matched runs. It shows for the week period only, when the plan is under way.
- `ProgressScreen` loads the runs itself (`inbox.loadAllRuns()`, keyed on the plan, day and session revisions, and on pull to
  refresh). That shares `InboxStore.busy` and `error` with the inbox and runs screens. A runner with no plan still sees the card
  under "Set a goal" once runs exist.
