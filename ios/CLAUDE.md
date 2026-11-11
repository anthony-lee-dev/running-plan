# ios

SwiftUI app, iOS 17 minimum (WorkoutKit), built with Xcode on the Mac. Layout:

- `RunningPlan/App/` entry point, `AppTab` (Next, Plan, Progress, Goal) and `RootView`.
- `RunningPlan/Theme/` colour tokens (`Palette`, from `docs/design-notes.md`) and `Metrics`.
- `RunningPlan/Features/` one folder per screen.
- Screens set `accessibilityIdentifier("screen.<name>")` so UI tests can find them.
- Fonts (Bricolage Grotesque, Inter) are not bundled yet; screens use the system font until a screen task adds them.

## Feature notes (read only the ones you need)

Decisions and traps for each feature live in `ios/docs/`, one file per feature, so a task reads only what it
touches. Before you change a folder, read its note; a change to shared code (networking, navigation, app state)
means reading the notes of the screens that use it. When a task teaches something worth keeping, add it to that
feature's note. This file is only for what every iOS task needs.

| You are changing | Read |
|---|---|
| `Features/Preview`, `Features/Interview` | `ios/docs/preview.md` |
| `Features/Account`, auth middleware, Keychain | `ios/docs/sign-in.md` |
| `Features/Plan` | `ios/docs/plan.md` |
| `Features/Session` | `ios/docs/session-editor.md` |
| `Features/Goal` | `ios/docs/goal-settings.md` |
| `Features/Watch` | `ios/docs/watch.md` |
| `Features/Inbox`, HealthKit import | `ios/docs/inbox-runs.md` |
| `Features/RunDetails` | `ios/docs/run-details.md` |
| `Features/CheckIn` | `ios/docs/check-in.md` |
| `Features/Progress` | `ios/docs/progress.md` |
| `Features/Review` | `ios/docs/review.md` |

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

## UI tests against a local API (task 3.9)

- UI tests that need the API run against the in-memory UI-test server (`api/test/ui-server`, on a free port per run),
  never the deployed one: they set `API_BASE_URL` in `launchEnvironment` and pass `-preview.draft ""` so a draft saved
  by an earlier run is not reused. `scripts/verify.sh ios` starts the server on a free port, passes `LOCAL_API_URL` to the test runner
  (`TEST_RUNNER_LOCAL_API_URL`), and fails if no UI test generated a plan on it. To run one from Xcode, start the server
  (`npm run ui-test-server -w api`, port 8790) and add `LOCAL_API_URL=http://127.0.0.1:8790` to the scheme's test environment;
  without it the test skips. Sign-in codes come from `GET /__test/codes/latest?email=` on that server.
- Plain `http://127.0.0.1` works in the simulator without an App Transport Security exception.

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

## Commands

- `bash scripts/verify.sh ios` (from repo root) regenerates the project, then builds and runs tests on a simulator.
  The `ios` check on GitHub runs the same script on a macOS runner with the newest Xcode it has, which may differ
  from the Mac's Xcode 27.1; keep the deployment target at iOS 17 so both build.
  It picks the first iPhone on the newest installed iOS runtime (older runtimes may not match the
  installed Xcode). Override with `IOS_SIM_DEST='platform=iOS Simulator,id=<udid>'`.
- Workers run the quick mode instead: `IOS_TEST_SCOPE=quick IOS_UI_TESTS="GoalUITests InboxUITests" bash scripts/verify.sh ios`
  does the same spec check, project generation and build, runs all of `RunningPlanTests` and only the UI test classes
  named (none if `IOS_UI_TESTS` is unset), and skips the "UI tests reached the local API" check. CI runs the full
  suite; the Stop hook runs the quick mode with no UI classes (the full suite doesn't fit its time limit). Name the UI test classes of the screens you changed.
- Without `IOS_SIM_DEST`, `verify.sh` locks the simulator it picks (`$TMPDIR/running-plan-sim-<udid>.lock`, holding
  the run's pid) so two runs never share one; when it is held, the run uses a clone named `RunningPlan verify <n>`,
  created on first need. Runs started by an older `verify.sh` don't take the lock.
- The required `ios` check always reports, but builds only when something the iOS build or UI tests use changed: `ios/`
  (not Markdown), `spec/`, `designs/dark/png` (the snapshot tests read it), `api/src`, `api/test/ui-server`, `api/migrations`, the API and root package files,
  `scripts/verify.sh`, `scripts/generate-api-client.sh` or the workflow (the list is in `ios-ci.yml`, pinned by `scripts/test/ios-ci-paths.test.sh`). Keep it in step
  with what `api/test/ui-server` imports. It builds once (`IOS_PHASE=build`, `build-for-testing`, products passed as an artifact) and runs the suite as three parallel shards from that build (`IOS_PHASE=test`, `IOS_SHARD=<i>/<n>`, see
  `ios_shard_filters` in `verify.sh`): the unit tests and each UI test class are dealt out by the times in
  `IOS_SHARD_WEIGHTS`, so re-measure those (each shard's log lists its slowest tests) when a class is added or the
  shards drift apart. One test running over 5 minutes is failed by name (`IOS_TEST_ALLOWANCE`), and a shard past its limit is restarted once.
  It caches the API client generator build and DerivedData; a cache miss only makes it slower.

## Manual gates (agents list these in the PR body, the human ticks them)

- Send-to-watch with WorkoutKit on a real Apple Watch.
- HealthKit import on a real iPhone.
- Sign in with Apple and App Attest, once the paid Apple Developer account exists (backlog "Later").
