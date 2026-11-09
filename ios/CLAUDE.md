# ios

SwiftUI app, iOS 17 minimum (WorkoutKit), built with Xcode on the Mac. Layout:

- `RunningPlan/App/` entry point, `AppTab` (Next, Plan, Progress, Goal) and `RootView`.
- `RunningPlan/Theme/` colour tokens (`Palette`, from `docs/design-notes.md`) and `Metrics`.
- `RunningPlan/Features/` one folder per screen.
- Screens set `accessibilityIdentifier("screen.<name>")` so UI tests can find them.
- Fonts (Bricolage Grotesque, Inter) are not bundled yet; screens use the system font until a screen task adds them.

## Decisions for the bootstrap task

- Generate the Xcode project with XcodeGen from `ios/project.yml` (`brew install xcodegen`, then `xcodegen` in `ios/`).
  The `.xcodeproj` is gitignored, so parallel worktrees never conflict on `project.pbxproj`. It lists every file
  by name, so a pull that adds or removes iOS files leaves it stale ("cannot find ... in scope" in Xcode). The hooks
  in `scripts/githooks/` regenerate it after a pull, rebase or branch switch that needs it; turn them on once per
  clone with `git config core.hooksPath scripts/githooks`. No hook runs on `git reset --hard` or `git stash pop`;
  after those, run `xcodegen generate` in `ios/` by hand.
- App target `RunningPlan`, unit test target `RunningPlanTests` (Swift Testing), UI test target `RunningPlanUITests`.
- API client generated from `../spec/openapi.yaml` with Apple's swift-openapi-generator, run by
  `bash scripts/generate-api-client.sh` into `ios/APIClient/Sources/APIClient/Generated` (committed; local package
  `ios/APIClient`). Not the build plugin: `xcodebuild` cannot trust a plugin without a skip-validation flag.
  After a spec change, regenerate and commit; `verify.sh ios` fails when the output is stale.
- Look and feel from `../designs/dark/DK-*.dc.html` and `../docs/design-notes.md`: Bricolage Grotesque for
  headings, Inter for body, the dark palette there, 44 pt minimum touch targets.

## Preview (DK-Preview, task 3.3)

- `Features/Preview/`: `PlanPreview` works out everything the screen shows from the API's `PlanDraft`; `PreviewViewModel`
  loads a draft saved less than 24 hours ago for the same answers, else calls `PlanGenerating` (the generated client's
  `generatePlan`, with a random per-install `X-Device-Id` used only for rate limiting); `PreviewDraftStore` keeps the
  draft in UserDefaults for 24 hours; `OnboardingFlow` goes interview, then preview, and "Change an answer" returns to
  the interview prefilled. The API base URL is the deployed Worker (`APIConfiguration.deployedURL`) unless the `API_BASE_URL`
  environment variable or the `apiBaseURL` user default names another (for example `http://localhost:8787` in the
  simulator; always include the scheme: a value without one falls back to the deployed API); a real iPhone cannot
  reach `localhost` on the Mac. The app target links the runtime packages itself (see `project.yml`).
- Save (task 3.4): `SaveFlowModel` signs in with an emailed code when needed (`SignInView` sheet), then `APIPlanSaver`
  creates the plan from the stored draft. The draft keeps client-assigned plan and session ids (`PlanIDs`), so a
  repeated save replays instead of duplicating; a saved draft is cleared, and a draft over 24 hours old is refused.
  Stored tokens the server rejects lead back to sign-in without an error. The preview's close button keeps the draft.
- Build every client with `APIConfiguration.client(...)`: the server's timestamps carry milliseconds, which the
  OpenAPI runtime's default date format rejects (a save then fails after the server stored the plan).
- SwiftUI: an `.accessibilityIdentifier` on a container is copied to every child unless the container is marked
  `.accessibilityElement(children: .contain)` first; and read observable state in `body`, not only inside a
  `Binding(get:)` closure, or the view does not redraw when it changes.

- Start date (issue #97): the preview has a "Starts on" date picker (`preview.startDate`), today by default, any earlier
  day, or a later one up to 12 months ahead (`PreviewViewModel.latestStart`; the engine and API accept a future `today`,
  no spec change). A plan that has not started shows through `PlanSchedule.Position.notStarted`: Next shows "Starts <day>"
  and the first session, Plan opens on week 1, the watch window and inbox have no "today" session or missed ones. The chosen date goes to `plans/generate` as `today` (the engine builds from it), `PreviewViewModel.startDate`
  is nil for "today", and `SavedPreview.startDate` (optional) keeps it so a saved draft is reused only for the same date.
  A goal date can still move the start (engine alignment); the preview then says so. The interview itself is unchanged.
- Inbox picker (issue #98): "Match to a session" lists every open session of a fitting type in the plan, nearest the
  run's day first (no 7-day window), and says why when there is none. Deleting a plan returns its runs to the inbox
  (server `unlink`), and the inbox refreshes when the plan id changes.

## Signing in (task 3.4)

- `Features/Account/`: `AuthSession` (an actor) signs in with an emailed code (`clientType: ios`) and refreshes the
  access token. The server revokes the whole token family when a rotated refresh token is reused, so refreshes run
  one at a time and there is exactly one session per run (`APIConfiguration.liveSession`); never build a second.
  Only a 400 or 401 from refresh signs out; offline or a server error keeps the tokens.
- `AuthMiddleware` adds `Authorization: Bearer` to every operation except the public ones (health, auth, generate),
  and on a 401 retries once with the session's fresh token. Use `APIConfiguration.liveSignedInClient()` for
  signed-in calls.
- Tokens live in the Keychain (`KeychainTokenStore`), one item per API host and port, so deployed tokens never go to
  a local server. Never log them or put them in UserDefaults. Keychain items survive a reinstall: UI tests pass
  `-auth.reset YES` to start signed out.
- The save UI test signs in with a fresh address each run and reads the code from `/__test/codes/latest`.
- Sign-in must be reachable on its own, not only inside a save (issue #129: after Sign out the only way in was the save
  flow, which creates a new plan and hides the account's existing one). `SignInModel` is plain sign-in: it asks for the
  email and code through the same `AuthSession`, then `onSignedIn` calls `PlanStore.load()`, which shows the account's
  most recent plan and never creates one; an account with no plan lands on "Set a goal". `SignInView` serves both models
  (`SignInFlowing`, `purpose: .save | .signIn`). `RootView` owns one sheet and offers it through the `requestSignIn`
  environment action: `SignInLink` ("Sign in", `account.signin`) under "Set a goal" on Next, Plan, Progress and Goal when
  `PlanStore.isSignedIn` is false (signed out, or the server refused the tokens; a signed-in account with no plan only
  offers "Set a goal"), and `SignInAgainButton` under any message starting `SignedOutMessage.prefix`. A new "You've been
  signed out" message must start with that prefix and show the button. The action closes the Inbox, Review, session and
  editor covers first (a sheet cannot open over them) and opens sign-in once they are gone. A sign-in bumps
  `AccountChanges`, which is part of the review, progress, inbox and watch keys so they reload even for the same plan.
  `.environment(\.requestSignIn, ...)` is the last modifier on `RootView`'s body so its covers inherit it. A sheet that
  Goal presents itself (review settings, re-run proposals) is not tracked by `RootView`, so it must not show
  `SignInAgainButton`: the sign-in sheet could not open over it.
- The UI-test API has no sign-in rate limit (every UI test shares one address, and the real per-IP limit of 15 an hour ran out).

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
- VoiceOver reads paces in words through `PaceFormat.spoken` ("6 minutes 25 to 7 minutes 10 per kilometre").

## Session sheet and editor (task 4.1)

- `Features/Session/`: `SessionSheetModel` (DK-Session: steps in watch-builder order with repeats grouped, the strength
  checklist, the copy-as-text string) and `SessionDraft` (DK-Editor's working copy, keeping the server's step rules
  from `parseSteps`) are pure and unit-tested; `SessionView` and `SessionEditorView` only draw them. Exercise names
  mirror `api/src/domain/strength.ts` in `ExerciseLibrary`; change both together.
- Edits go straight to the API through `PlanStore.apply/create/delete` (`APISessionWriter`, `If-Match: "<revision>"`),
  and the server's copy of the session replaces ours, so the next edit sends the new revision. A 409 reloads the plan
  and says so; offline is an inline error (the queue is slice 5).
- Quick adjustments (`QuickAdjustment`): Shorter, Easier, Swap (move to another day of the week; what is there takes
  its place) and Skip. The server keeps `owner: system` for a status-only edit, so Skip also sends the unchanged
  `date` to make the session the user's. The amounts are starting values for the coach review (H.1).
- Before-session check-in: Fresh, Okay, Tired send `feel` 5, 3, 2 (`when: before`).
- "I'd rather build my own plan" creates a blank plan (`BlankPlan`: this week's Monday, `source: blank`, not
  adaptive, no sessions) through `SaveFlowModel.saveBlank`; sessions are added with Week's "Add a session".
- `RootView` presents the sheet (`SessionScreen`, full screen) and the editor or move sheet (`SessionRoute`). Week
  rows are buttons with the identifier `week.session`, each labelled with its day.
- UI tests share `LocalAPI` (launch, preview, sign in). A relaunch that must stay signed in leaves out `-auth.reset`.
- The OpenAPI runtime percent-encodes header parameters (`If-Match: "3"` went out as `%223%22`, which the API refuses);
  `EntityTagMiddleware`, added by `APIConfiguration.client(...)`, decodes it again.

## Scroll dials (issue #99)

- Time, distance and pace are set on two native wheel pickers (`TwoWheelDial`), not typed: time is minutes (0 to 3333) and
  seconds, distance whole km (0 to 200) and tenths of a km (0.1 km steps; a value saved at two decimals, like 1.25 km, adds its own
  step to the tenths wheel so it still shows, and is only rewritten when the user moves a wheel), pace minutes (2 to 20) and seconds.
  `DialValues` (pure, unit-tested) splits and rejoins them within the API's ranges (goal 1 to 200000, pace 120 to 1200).
  The dials read the saved value directly and write only when a wheel moves, so opening a step never changes it, and
  the km wheel keeps an off-grid saved value's metres. Identifiers: `goal.time`, `goal.distance`, `pace.fastest`,
  `pace.slowest` (each with `.first` and `.second` wheels). The sets, reps, hold and rest `Stepper`s are unchanged.

## UI tests against a local API (task 3.9)

- UI tests that need the API run against the in-memory UI-test server (`api/test/ui-server`, on a free port per run),
  never the deployed one: they set `API_BASE_URL` in `launchEnvironment` and pass `-preview.draft ""` so a draft saved
  by an earlier run is not reused. `scripts/verify.sh ios` starts the server on a free port, passes `LOCAL_API_URL` to the test runner
  (`TEST_RUNNER_LOCAL_API_URL`), and fails if no UI test generated a plan on it. To run one from Xcode, start the server
  (`npm run ui-test-server -w api`, port 8790) and add `LOCAL_API_URL=http://127.0.0.1:8790` to the scheme's test environment;
  without it the test skips. Sign-in codes come from `GET /__test/codes/latest?email=` on that server.
- Plain `http://127.0.0.1` works in the simulator without an App Transport Security exception.

## Delete plan (task 3.9 issue #92, moved to Goal and settings by #77)

- Goal and settings has "Delete plan" (`plan.delete`) with a confirmation dialog; the Plan tab no longer has it. `PlanStore.deletePlan`
  calls `SessionWriting.deletePlan` (`DELETE /v1/plans/{id}`, `If-Match` = the plan's `revision`), then returns to the
  empty state. 404 counts as deleted; 409 reloads; offline or other errors keep the plan and show a line (`plan.delete.error`) in the card.
  Deleting the plan removes its workouts from the watch (`WatchSyncModel`, see Send to watch). Known limit: a
  user with an older saved plan sees that one after a relaunch.

## Unit tests

- Keep each `#expect` simple: build an expected array in a typed `let` first. An inline literal joined with `+` and
  `Array(repeating:)` compiled on the Mac but hit "unable to type-check this expression in reasonable time" on CI.

## Snapshot tests

- A screen's snapshot test hosts the real view in a `UIHostingController` (not `ImageRenderer`, which leaves out
  ScrollView) and compares it with `designs/dark/png/DK-*.png` on a coarse colour grid (see
  `InterviewSnapshotTests`). The bundled system fonts differ from Bricolage and Inter and each simulator frames the window
  differently (CI's iPhone 17 Pro failed an absolute threshold calibrated on the Mac), so compare relatively: the
  right render must score lower than a wrong selection and than a different screen. That catches layout, colour
  and selection regressions, not typography. Filter one Swift Testing test with
  `-only-testing:RunningPlanTests/Suite/test()` (the parentheses are needed).

## Bundle ID

- Release ID: `ca.anthonylee.runningplan` (from the human's domain anthonylee.ca). **Never register it with the
  free Personal Team**: an ID a Personal Team registers can stay blocked for the paid team later.
- `project.yml` sets `PRODUCT_BUNDLE_IDENTIFIER: ca.anthonylee.runningplan$(BUNDLE_ID_SUFFIX)`, and a committed
  `ios/Signing.xcconfig` sets `BUNDLE_ID_SUFFIX = .dev`. So free-team builds are `ca.anthonylee.runningplan.dev`.
  When the paid account exists, a separate release configuration sets the suffix to empty.
- Extensions and groups derive from it: `<bundle id>.watchkitapp`, `<bundle id>.widgets`, `group.<bundle id>`.

## Signing (free Personal Team, no paid account yet)

- Simulator builds need no signing. For the iPhone, the human's team ID goes in `ios/Local.xcconfig`
  (gitignored, `DEVELOPMENT_TEAM = <team id>`), included from `project.yml`, so regenerating the project keeps it.
- Free-team installs expire after 7 days; re-run from Xcode to renew. Up to 3 apps per device.
- Do not add capabilities that need the paid program: Sign in with Apple, App Attest, Push, iCloud. HealthKit
  (needed for import and WorkoutKit) should work on a free team. Task 4.2 added the HealthKit entitlement
  (`RunningPlan.entitlements`, generated from `project.yml`) and the Health usage strings; the simulator build accepts
  them. Only a device can show that a free team's provisioning profile accepts the entitlement and that the scheduler syncs.

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

## Run details (issue #131)

- No API or spec change: `ActivityFields` already had `elevationGainM`, `getProfile`/`updateProfile` hold `heartRate.maxBpm`, and
  splits, zones and routes never leave the device. `Features/RunDetails/`: `RunDetailsModel` (hero stats, grid, plan chip, plan vs
  actual through `CheckInModel`, the limited-data note), `RunSplits` (per km from distance samples, moving time, fastest and
  slowest of the full km, thin bar = speed relative to the fastest), `HeartRateZones` (bands 60/70/80/90% of the typed max, or the
  profile's own five zones; a reading holds at most 30 s; starting values for H.1), `ZonesSection` (what the zone card shows), all pure
  and unit-tested; `RunDetailsStore` loads Health readings and the profile; `RunDetailsScreen` only draws.
- Opened from "Run details" on each card in All imported runs (`runs.details`) and on the session page's matched run
  (`session.run.details`). A missing stat is left out (never 0 or a dash) and one "Limited data from <source>" note shows.
- **Do not add HealthKit read types** (stepCount, workoutRoute...) casually: `needsAccess()` compares with the whole set, so a new
  type makes it true for every existing user and `load()` silently stops importing on open. Elevation comes from the workout's
  metadata, splits from `distanceWalkingRunning` samples, zones from `heartRate` samples, all already allowed. Cadence stays hidden.
- Backfill: opening details calls `InboxStore.backfill`, which re-reads the workout and re-sends it only when Health now has a
  distance, heart rate or climb the stored run lacks (`HealthWorkoutMapper.fillsGap`). The server merges (never erases a field) and
  keeps the match. It never asks for Health access.
- Max heart rate is asked once on the card (`MaxHeartRateServing`: reads the profile, sends `heartRate` back with the user's zones
  because the section is replaced whole). "Not now" is remembered in UserDefaults (`rundetails.maxhr.declined`); a saved value always
  shows zones. Writing the profile bumps its revision, so a review-settings sheet opened earlier may 409 once on its next save.

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

## Commands

- `bash scripts/verify.sh ios` (from repo root) regenerates the project, then builds and runs tests on a simulator.
  The `ios` check on GitHub runs the same script on a macOS runner with the newest Xcode it has, which may differ
  from the Mac's Xcode 27.1; keep the deployment target at iOS 17 so both build.
  It picks the first iPhone on the newest installed iOS runtime (older runtimes may not match the
  installed Xcode). Override with `IOS_SIM_DEST='platform=iOS Simulator,id=<udid>'`.
- The `ios` check builds only when `ios/` changes beyond Markdown (or `spec/`, `api/`, `scripts/verify.sh` or the workflow
  does). It caches the API client generator build and DerivedData; a cache miss only makes it slower.

## Manual gates (agents list these in the PR body, the human ticks them)

- Send-to-watch with WorkoutKit on a real Apple Watch.
- HealthKit import on a real iPhone.
- Sign in with Apple and App Attest, once the paid Apple Developer account exists (backlog "Later").
