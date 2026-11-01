# ios

SwiftUI app, iOS 17 minimum (WorkoutKit), built with Xcode on the Mac. Layout:

- `RunningPlan/App/` entry point, `AppTab` (Next, Plan, Progress, Goal) and `RootView`.
- `RunningPlan/Theme/` colour tokens (`Palette`, from `docs/design-notes.md`) and `Metrics`.
- `RunningPlan/Features/` one folder per screen as they land; `PlaceholderScreen` stands in until then.
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

- Start date (issue #97): the preview has a "Starts on" date picker (`preview.startDate`), today by default, today or
  earlier only. The chosen date goes to `plans/generate` as `today` (the engine builds from it), `PreviewViewModel.startDate`
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

## The saved plan (task 3.5)

- `Features/Plan/`: `PlanStore` (owned by `RootView`, shared by the tabs) loads the active plan on launch and, after a
  save, the saved plan by id. Signed out or a 401 that survives the refresh shows the empty state ("Set a goal")
  without an error; offline or a server error shows a retry. Kept in memory only: the on-device store is slice 5.
- The active plan is the most recently updated one on the first `listPlans` page. The list is ordered by start date
  then id, not by save time, so `updatedAt` picks the latest save. Session edits do not move a plan's `updatedAt`.
- `PlanSchedule` is pure: it takes `today` as `YYYY-MM-DD` and counts weeks in calendar days from `startDate`, never
  with `Date` intervals. It works out the week, today's sessions, the next session and week totals. Distance actually
  run waits for the progress endpoint (backlog 2.15); only session status (`done`) is used until then.
- UI tests that touch the API pass `-auth.reset YES`, so an earlier test's sign-in (and plan) never replaces "Set a goal".
- Screens: `NextModel`, `WeekModel` and `WholeModel` are pure (built from `PlanSchedule`) and pinned by unit tests;
  `NextView`, `WeekView` and `WholeView` only draw them. Snapshot tests render the views with `PlanFixture` (the boards'
  plan, today Wed 2026-10-28) through `BoardSnapshot`. Left for later tasks: the review and inbox cards, and distance
  run and "On track" (progress endpoint, 2.15).
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
  seconds, distance whole km (0 to 200) and hundredths of a km (10 m steps), pace minutes (2 to 20) and seconds.
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

## Delete plan (interim, task 3.9 issue #92)

- `PlanScreen` shows a small "Delete plan" under the plan (`plan.delete`) with a confirmation dialog; `PlanStore.deletePlan`
  calls `SessionWriting.deletePlan` (`DELETE /v1/plans/{id}`, `If-Match` = the plan's `revision`), then returns to the
  empty state. 404 counts as deleted; 409 reloads; offline or other errors keep the plan and show a line under the button.
  Goal and settings (3.7) replaces it. The row shows in week mode only (an inset covered the whole-plan list's rows on a
  short screen and broke the Preview UI test). Known limits: workouts already on the watch stay until the next resync, and a
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
  (WorkoutKit in `LiveWatchScheduler`, a fake in tests). It asks permission only from the user's tap on "Keep my next
  sessions on my watch"; `RootView` resyncs in the background only when that is on and already allowed.
- If a free team refuses to sign the HealthKit entitlement, remove the `entitlements:` block and the two
  `INFOPLIST_KEY_NSHealth*` lines from `project.yml`; the preview still works and scheduling needs a device check.
- Add to Apple Watch uses `.workoutPreview`, which needs no permission. Watch sends need a paired Apple Watch.

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
- Not done here: calling `generateProposals` after an import (the review and proposals tasks, 4.5 on).

## Runs from any session (issue #105)

- No API change: `PUT /v1/sessions/{id}/match` replaces the session's run (the old one returns to the inbox) and moves a
  run matched elsewhere (that session goes back to `planned`); `DELETE` unmatches; `GET /v1/activities` without `inbox`
  returns every run with its `match`.
- The session page shows the matched run with Change and Unmatch (`session.run.change`, `session.run.unmatch`), or
  "Match a run" (`session.run.match`) for a live non-rest session dated today or earlier with no run. The picker lists
  unmatched inbox runs of a fitting type, nearest the session's day first (`RunMatchModel`, pure).
- "All imported runs" (`inbox.allRuns`, `RunsScreen`) lists matched, inbox, extra and ignored runs; re-map with
  "Match to a session" / "Change session", "Unmatch", "Back to inbox". `InboxStore.allRuns` is loaded on demand.
- A move changes a second session the reply does not carry, so `InboxStore` reloads the plan when the match displaces
  one (known from `allRuns`); otherwise the old session would stay `done` locally and its next edit would 409.
- The Next tab's inbox card is unchanged. The UI test covers unmatch and rematch from the runs list; the session page
  is pinned by `RunMatchModelTests` (no UI test: the first session of a fresh plan is usually in the future).

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
