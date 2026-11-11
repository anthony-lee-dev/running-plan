# Preview and the unsaved draft

Part of the iOS guide (`ios/CLAUDE.md` has the index). Read this before changing `Features/Preview`, `Features/Interview`.

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
