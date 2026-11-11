# Goal and settings, delete plan

Part of the iOS guide (`ios/CLAUDE.md` has the index). Read this before changing `Features/Goal`.

## Goal and settings (issue #77)

- `Features/Goal/`: the Goal tab (`GoalScreen`, heading `screen.goal` in every state). No DK board exists, so the layout comes from
  the tokens: a goal card, one settings card, plan, account and privacy cards. `GoalModel` (pure, unit-tested) holds the goal
  summary, the goal edit and `answers(goal:profile:today:)`; `GoalStore` (owned by `RootView`) does the calls through `GoalSettingsServing`
  (`getProfile`, `updatePlan`, `exportAccount`, `deleteAccount`). Review frequency, day and target display go through the
  `ReviewSettingsModel` and `ReviewSettingsSheet` of #71 (Off can be turned back on there).
- One profile revision, one holder: the target display lives in `ReviewSetting` and is saved by `ReviewSettingsModel.choose(targetDisplay:)`,
  so it and the review setting never send a stale `If-Match`. A second model holding the profile revision would 409 against it.
  The sheet closing on Goal bumps `RootView.reviewSettingsChanges` (part of `reviewKey`), so Next's review card looks at the new setting.
- Re-run the interview: `InterviewView(isRerun: true)` (no "build my own plan", its own privacy line) starts from the answers the plan was made
  from (`engine.interview`, so runs per week, weekly km, history, pain and strength are not reset), then the plan's goal as it is now, then the
  profile's target display, heart rate max, days off and long-run day. The interview accepts less than the plan and profile hold (goal time
  10 min to 6 h, at most 4 days off, no past date), so out-of-range values are left out; a custom or no goal with no stored answers starts it fresh.
  Edit goal keeps the target time's seconds unless the minutes are changed (`GoalModel.targetSeconds`). Continue keeps a
  prefilled answer and Skip clears it. The answers go to `ProposalsStore.proposeInterviewRerun` on the store of `GoalStore` (not the review's
  list) and `RerunProposalsSheet` shows `ProposalList`; nothing changes until accepted.
- Edit goal changes the date and target time only (`updatePlan`, `If-Match` the plan revision, reply replaces the plan); the distance and
  the weeks change through the re-run. Target display is saved but no screen reads it yet: targets still show as pace until one does.
- Export (`POST /v1/account/export`) writes `running-plan-export.json` to the temporary folder (complete file protection) and offers it with
  `ShareLink`; it is the typed reply encoded again, so fields outside the spec are not in it. The file is removed before the next export and on
  sign-out. Sign out and Delete account (confirmed) end in `AuthSession.signOut()`, `PlanStore.load()` (the empty state, which clears the watch)
  and `ReviewSettingsModel.reset()`; `RootView` clears the `ReviewStore` when the plan is gone, so no review badge outlives the account.
  A 401 on delete counts as already signed out.
- The Apple Watch row shows only where `WorkoutScheduler.isSupported`, and opens `WatchSettingsSheet`.

## Delete plan (task 3.9 issue #92, moved to Goal and settings by #77)

- Goal and settings has "Delete plan" (`plan.delete`) with a confirmation dialog; the Plan tab no longer has it. `PlanStore.deletePlan`
  calls `SessionWriting.deletePlan` (`DELETE /v1/plans/{id}`, `If-Match` = the plan's `revision`), then returns to the
  empty state. 404 counts as deleted; 409 reloads; offline or other errors keep the plan and show a line (`plan.delete.error`) in the card.
  Deleting the plan removes its workouts from the watch (`WatchSyncModel`, see Send to watch). Known limit: a
  user with an older saved plan sees that one after a relaunch.
