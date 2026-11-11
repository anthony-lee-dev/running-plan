# Session sheet, step editor, scroll dials

Part of the iOS guide (`ios/CLAUDE.md` has the index). Read this before changing `Features/Session`.

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
- A UI test that is not about the interview, preview or sign-in starts with `LocalAPI.signedInApp(api)` (optionally
  `startingOn:` a date): it asks the UI-test API's `POST /__test/seed` for a fresh account with a saved 10K plan and
  launches the app with `-auth.seed "<access>|<refresh>|<userId>"` (Debug builds only, read after `-auth.reset`
  in `liveTokenStore`), so it lands on Next with the plan at once. Only `InterviewUITests`, `PreviewUITests` and
  `SignInAgainUITests` go through the interview, preview and sign-in screens; keep one full test of each there.
  `LocalAPI.send` gives a local API request 90 s and one retry (a slow CI runner once stalled the server past 60 s).
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
