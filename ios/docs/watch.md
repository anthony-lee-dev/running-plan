# Send to watch (WorkoutKit)

Part of the iOS guide (`ios/CLAUDE.md` has the index). Read this before changing `Features/Watch`.

## Send to watch (task 4.2)

- `Features/Watch/`: `WatchWorkoutMapper` (pure) turns a run session into a WorkoutKit `CustomWorkout`: leading warm-up
  and trailing cool-down, every other step or repeat group an interval block, pace as a speed-range alert (the pace's
  faster end is the upper speed), heart rate as a heart-rate alert, effort and none as no alert. Strength, rest and custom
  sessions are not sent. A plan's id is derived from session id and revision, so the same session is the same plan.
- `WatchSync` (pure) picks the window (next 15 planned runs from today) and diffs it against what is scheduled by
  `(plan id, local date)`; removals run before additions so the cap holds. `WatchSyncModel` drives a `WatchScheduling`
  (WorkoutKit in `LiveWatchScheduler`, a fake in tests).
- One automatic setting (issue #112, design in #100); there is no per-session "Add to Apple Watch" (`.workoutPreview` is gone).
  Intent (`wantsSync`) is kept apart from permission: a refused or revoked permission shows `.denied` and the intent
  stays on, so sync resumes by itself once allowed. Never store `false` on denied. Permission is asked only from a tap
  (`turnOn`: the Next card's Turn on or the Watch settings switch), never from a resync.
- The setting (`watch.sync.<userId>`) and the "asked" flag (`watch.asked.<userId>`) live in UserDefaults on this iPhone,
  per account; `watch.owner` records whose workouts are on the watch, so a different account or sign-out removes them.
  `WatchSyncModel.update(state:account:today:)` is the one entry point: `.loaded` resyncs, `.empty` (deleted plan,
  signed out) clears, `.loading` and `.failed` do nothing. Never clear on `plan == nil`. `RootView` calls it on launch,
  on a plan change and on `scenePhase == .active` (no background refresh task).
- Next shows a one-time card ("Put your runs on your Apple Watch?", Turn on / Not now) until answered, only when
  `WorkoutScheduler.isSupported`. The session page shows one status line (`WatchStatusCopy`, pure and unit-tested) and a
  "Watch settings" link for open runs; none for strength, custom, rest, done, skipped or past sessions or an unsupported
  device. `WatchSettingsSheet` holds the switch and is reused by Goal and settings (#77).
- If a free team refuses to sign the HealthKit entitlement, remove the `entitlements:` block and the two
  `INFOPLIST_KEY_NSHealth*` lines from `project.yml`; scheduling then cannot work, so this needs the paid team.
  Scheduling under a free team is checked on a device (manual gate). Watch sends need a paired Apple Watch.
