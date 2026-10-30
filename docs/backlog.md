# Backlog

Work is ordered in **vertical slices**: each slice is one feature a runner can use, with just the API and iOS work it
needs, and it ends with an end-to-end check before the next slice starts. Agents take the first unticked task in the
first unfinished slice (`/next-task`); a slice is finished when its tasks are ticked and its **Done when** holds.
Tasks marked `any time` may be picked when the current slice is waiting on the human. The web companion and the
`Later` sections come after slice 12.

One task = one PR. `ask first` = post the plan and wait for the human before writing code. Task numbers are stable
IDs, not order (2.x started as API tasks, 3.x and 4.x as iOS tasks). Tasks in one slice without a shared `needs` can
run side by side, one worktree each (`claude --worktree <name>`); two or three at once is a sensible limit.

Sources: § points to `designs/Running Planner — System Design v1.0.md` (what to build). The test approach per layer
and manual-gate rules come from `designs/Running Planner Agent Build Workflow.md` (how to build). That document's
phase order and Gates B and C are replaced by the slices below: every slice adds contract tests for its endpoints
(Gate B, a slice at a time) and snapshot and UI tests for its screens (Gate C, a slice at a time).

**End-to-end check for every slice** (from slice 1 on):
1. API contract tests for the slice's endpoints pass on the Workers and the Node entry.
2. An iOS UI test runs the slice's flow in the simulator against the local Node API (in memory, no network).
3. The slice's last PR lists a device check against the deployed API as an unticked `## Manual gates` box for the
   human; WorkoutKit and HealthKit checks are Gate D items. Agents never tick these boxes.

Every screen task also needs 0.5 for its snapshot test.

## Done before the slices

### Setup on the Mac (human)

From the workflow doc's Day-1 checklist.

- [x] 0.1 Tools installed, email hidden, `bash scripts/bootstrap.sh` ended with "main is protected"
- [x] 0.2 On GitHub, `api` and `ios` ran green on `main`, and Settings, Rules shows the `main` ruleset (before any PR)
- [x] 0.3 Test the Stop hook once: break a pace test in a worktree, ask Claude to finish, check it keeps going
      (before the first agent task)
- [x] 0.4 `npx wrangler login`, `npx wrangler d1 create running-plan` from `api/`, put the id in `api/wrangler.toml`
      as a small PR (before any deploy; 1.5 tests run locally without it)
- [x] 0.5 Export the 11 dark boards as PNGs into `designs/dark/png/` (needed by the screen snapshot tests)
- [x] 0.6 Sign in to Xcode with the Apple account so the Personal Team can run the app on the iPhone (needed for gate D)
- [x] 0.7 Re-run `bash scripts/setup-github.sh` after 1.6 merges, to turn on Dependabot security update PRs
      (agents may not run it)

### Foundations

- [x] 1.1 Monorepo scaffold, CLAUDE.md files, verify scripts, Stop hook, reviewer, `/ship`, api-ci
- [x] 1.2 `ask first` Derive the full `spec/openapi.yaml` from §7 (the 19 operations it lists: auth sign-in, refresh,
      account delete; `plans/generate`; plans list, create, get, patch, delete; session patch; sync; activities
      batch and list; session match and check-ins; proposals generate, accept, dismiss; plan progress), schemas
      from §5, auth with client-type token scopes. Sign-in is email only for now (root `CLAUDE.md`). Propose routes
      for the gaps §7 leaves open, so later tasks need no extra spec PR: email sign-in needs two steps (request a
      code, verify it); creating and deleting single sessions (or say they go through plan PATCH and sync); the
      Profile (target display, review frequency and day); the weekly review summary; account data export.
      Spec only, no code; Redocly lint green. needs: 0.2, 0.3
- [x] 1.3 iOS bootstrap (runs alongside 1.2): `ios/project.yml` (XcodeGen), SwiftUI app shell with the four tabs
      (Next, Plan, Progress, Goal, as in `docs/design-notes.md`), Swift Testing and UI test targets, bundle ID and
      signing as in `ios/CLAUDE.md`, `verify.sh ios` green. needs: 0.2, 0.3
- [x] 1.4 Design handoff: extend `docs/design-notes.md` with component states and a screen-to-endpoint map, using the
      `design:design-handoff` and `design:accessibility-review` skills if they load (44 pt touch targets).
      needs: 1.2 for the endpoint names
- [x] 1.5 D1 schema: first migration from the §5 data model (every synced entity has a client UUID, revision,
      `updatedAt` and `deletedAt` tombstone), schema tests in workerd with `@cloudflare/vitest-plugin` (renamed from `vitest-pool-workers`). The D1
      repositories themselves come with the API tasks that use them (2.4 onwards). needs: 1.2, 1.6
- [x] 1.6 Clear the Dependabot alerts (all in dev tooling): `vitest` `^4.1.12`, `@redocly/cli` `^2.72.0`, so
      `npm audit` shows 0. Check dependencies early: audit step in `verify.sh`, dependency review in `api-ci`,
      `.github/dependabot.yml`, reviewer checks lockfile changes

**Gate A (human, passed):** approve and merge 1.2 line by line. Everything below builds on it.

### Plan engine and API built ahead of the slices

Built in the earlier API-first order; each is picked up by the slice whose screens use it.

- [x] 2.8 Plan validators (§6.4): conservative first week, capped week-to-week growth with down weeks, easy or rest
      day between hard sessions, one protected rest day, long-run share cap, taper, strength placement. Warn, never
      block; hard errors only for invalid data. Runs on generated, edited and blank plans
- [x] 2.9 `ask first` Pace and target derivation (§6.3): propose the race-equivalence model (open question §12.2);
      ranges in min/km starting on the slow side; effort targets when there is no recent result; heart rate only
      when the user gives max HR or zones
- [x] 2.1 Rule engine: 5K preset, table-driven tests over interview answers (runs per week, tier, plan length, day
      constraints), property tests for conservative start and bounded weekly growth; response carries assumptions
      and warnings. needs: 2.8, 2.9
- [x] 2.2 Rule engine: 10K and half-marathon presets, strength sessions from a small curated exercise library,
      snapshot tests over the 54 base variants (§6.2). needs: 2.1
- [x] 2.10 Rule engine edge cases (§6.5): goal date too soon (shorten to a minimum, else propose a later date),
      goal date far away (base phase), baseline far below the goal, pain flag selects the cautious variant. needs: 2.1
- [x] 2.4 `ask first` Auth: email sign-in with a one-time code, refresh tokens with client-type scopes, account
      delete. Sending email goes through an `EmailSender` port; the dev adapter logs the code, and the task
      proposes a provider. needs: 1.5
- [x] 2.5 Plans and sessions CRUD, including blank plans and user-owned custom sessions; edits carry the base
      revision. needs: 2.4
- [x] 2.11 Activities: `POST /v1/activities:batch` (native clients only, by token scope; App Attest is L.2) and
      `GET /v1/activities`; dedupe on start time, duration and distance, not only the external id. needs: 2.4
- [x] 2.13 Proposal engine `propose_adjustments` (§6.6): missed key session is dropped not rescheduled, harder than
      planned eases next week, pain flag reduces load, consistently easy progresses; never edits the plan;
      user-owned sessions locked; off for blank plans unless opted in. needs: 2.1
- [x] 2.17 Profile API: target display, derived pace ranges and their provenance, scheduling preferences, review
      frequency and day (§5, §6.6a). needs: 2.4

## Slice 0: Get a suggested plan (done)

- [x] 2.3 `POST /v1/plans/generate` (stateless, no auth) with the §7 abuse controls: rate limit by IP and device,
      strict schema bounds, no persistence, no logging of interview answers, bounded compute and response size.
      Rate limiting goes through a `RateLimiter` port; the Workers implementation lives in `adapters/cloudflare/`.
      needs: 2.1
- [x] 3.1 Generated API client from the spec with Apple's swift-openapi-generator, run by
      `scripts/generate-api-client.sh` with the output committed (the build plugin needs a human to trust it in
      Xcode and `xcodebuild` skips that only with a safety flag). `verify.sh ios` fails if it is stale. needs: 1.3
- [x] 3.2 Interview screen (DK-Interview): Appendix B questions, one per screen, skippable with defaults.
      needs: 1.3, 0.5
- [x] 3.3 Preview with no account (DK-Preview): whole plan, week 1, a sample session, assumptions and warnings;
      changing an answer regenerates; draft kept on the device for 24 hours (unit test for expiry).
      needs: 3.1, 3.2, 0.5

**Done when (passed):** the interview gives a preview from the deployed API on a real iPhone (#28 device check;
the human confirmed it in a session on 2026-10-30).

## Slice 1: End-to-end test setup

- [ ] 2.7 Contract tests from `spec/openapi.yaml`, run against both the Workers and the Node entry, for every
      endpoint that exists today (generate, auth, profile, plans and sessions, activities, matches, check-ins).
      Request validation must enforce `unevaluatedProperties: false` (Swift's generator ignores it). Later slices
      add their endpoints to it. needs: 2.3, 2.4, 2.5, 2.11, 2.17
- [x] 3.9 iOS UI tests against a local API: start the Node entry (in-memory stores) for the UI test target and point
      the app at it with `API_BASE_URL`; port the interview-to-preview UI test to it. Signing in from a UI test needs
      a known code: an email sender for the Node entry that only runs in tests, never in the Workers entry. The CI
      change in `scripts/` or `.github/` needs the human to merge. needs: 3.3

**Done when:** both run in CI, and the interview-to-preview UI test passes against the local API.

## Slice 2: Sign in and save my plan

- [ ] 3.4 Email sign-in and save plan: the Save button on the preview signs in with a one-time code, then creates the
      plan; tokens in the Keychain, refresh on 401; a way to close the preview. needs: 3.3, 3.9

**Done when:** a UI test goes interview, preview, sign in, saved plan; device check: sign in with a real email code
and save a plan against the deployed API.

## Slice 3: See my plan

- [ ] 3.5 Next (DK-Next), Plan week (DK-Week), whole plan (DK-Whole); paces shown as `6:30/km`. needs: 3.4, 0.5

**Done when:** a UI test shows the saved plan on all three screens, with snapshot tests against the dark boards.

## Slice 4: Open and edit a session

- [ ] 2.21 Unlink an activity when its session or plan is deleted (left from 2.12; today the match is hidden and the
      activity stays `matched`, out of the inbox, until it is matched again or given a disposition). needs: 2.5
- [ ] 4.1 Session spec sheet and editor (DK-Session, DK-Editor): steps in watch-builder order with repeat groups,
      strength exercise checklist, copy or share as text, custom sessions, build a plan from blank, quick
      adjustments (shorter, easier, swap, skip) that mark the session user-owned, optional before-session check-in.
      Edits go straight to the API while online (offline edits are slice 5). needs: 3.5, 0.5

**Done when:** a UI test edits a session and the change is still there after relaunching the app.

## Slice 5: Edit offline

- [ ] 2.6 `POST /v1/sync` for the offline edit queue: idempotency keys, cursor, per-session revision conflicts,
      tombstones. The server processes as many operations as fit its per-request query budget (50 D1 queries on
      Workers Free) and the client resends the rest. needs: 2.5
- [ ] 3.6 Offline edit queue and sync: unit tests for the queue, keep-mine-or-theirs conflict prompt, tombstones,
      stale proposals. needs: 2.6, 4.1

**Done when:** a UI test edits offline, comes back online and the edit syncs; a conflicting edit asks keep mine or
theirs.

## Slice 6: Put it on my watch

- [ ] 4.2 Send to watch with WorkoutKit: Add to Watch preview, and scheduling a rolling window (up to 15 workouts).
      Manual-gate box: WorkoutKit and HealthKit work on the free Personal Team. needs: 4.1, 0.6

**Done when:** unit tests for the workout mapping pass; Gate D item: a session reaches the Apple Watch.

## Slice 7: Import runs and match them

- [ ] 2.12 Matches and check-ins: `PUT /v1/sessions/{id}/match`, `POST /v1/sessions/{id}/checkins`. Matches and check-ins
      are done (PUT and DELETE match, `PATCH /v1/activities/{id}`, `match` on listed activities, check-ins; the pain
      flag's urgent proposal comes with 2.14; unlinking on delete is 2.21). Left: `suggestedSessionId` in the upload
      results. needs: 2.5, 2.11
- [ ] 4.3 HealthKit import inbox and matching by local date (DK-Inbox, unit tests for local-date matching): running,
      strength and other workout types; extra runs, unmatched, two runs in one day, missed sessions; manual entry
      as a short fallback. needs: 2.12, 3.5, 0.5, 0.6

**Done when:** a UI test imports a run (manual entry) and confirms its match; Gate D item: a run recorded in Health
(Apple Watch, Garmin and Nike data) lands in the inbox and matches.

**Gate D (human, needs 0.6):** device checklist ticked: send-to-watch (slice 6) and HealthKit import (slice 7).

## Slice 8: Check in and see plan vs actual

- [ ] 4.4 Plan vs actual and check-in (DK-CheckIn); pain guidance shows whatever the review setting. needs: 4.3

**Done when:** a UI test checks in after a matched session and sees plan vs actual.

## Slice 9: Weekly review and proposals

- [ ] 2.18 Weekly review summary API: planned vs completed, distance and time against plan, key sessions, check-in
      feel and pain, inbox loose ends (§6.6a); computed on the backend so the web sees it too. The computation is
      done (`api/src/domain/insights.ts`, `computeWeeklyReview`). needs: 2.12, 2.17
- [ ] 2.14 Proposals API: generate, accept, dismiss; stale when the plan revision moves; re-running the interview
      regenerates future weeks only (property test: keeps past and user-owned sessions) and is delivered as a
      proposal. A pain flag in a check-in triggers an urgent proposal when the review setting is Weekly plus urgent
      (left from 2.12). needs: 2.12, 2.13
- [ ] 4.5 Weekly review and proposals (DK-Review), review frequency setting (default Weekly plus urgent).
      needs: 4.4, 2.18, 2.14

**Done when:** a UI test opens a due review and accepts a proposal, and the plan changes.

## Slice 10: Progress

- [ ] 2.15 `GET /v1/plans/{id}/progress`: adherence, volume trend, key and strength sessions completed, goal
      countdown. The computation is done (`api/src/domain/insights.ts`, `computeProgress`); the route and its store
      reads are left. needs: 2.12
- [ ] 4.6 Progress (DK-Progress). needs: 2.15, 0.5

**Done when:** a UI test shows progress for a plan with done and missed sessions.

## Slice 11: Goal and settings

- [ ] 2.20 Spec clarification for `PATCH /v1/profile` (own PR, human merge; found by the 2.17 review): say that
      `heartRate`, `scheduling` and `review` replace their whole section (the only way to clear a field), and decide
      whether ranges may be equal and sub-objects reject unknown keys, as the API does today. Also give
      `POST /v1/sessions/{id}/checkins` a 409 for an id reused with another body (as plan create has; the API answers
      400 `id_in_use` until then), and say in the schema that `effortFelt` is for after-session check-ins only.
      needs: 2.17. `any time`
- [ ] 2.16 Account data export (§10). needs: 2.12
- [ ] 3.7 Goal and settings: goal, re-run interview, review frequency and day, target display, account,
      privacy, data export. There is no DK board for it, so the plan proposes a layout from the existing tokens
      (no longer `ask first`: on 2026-10-30 the human agreed in a session to go ahead with that layout). needs: 3.4, 2.17, 2.14, 2.16

**Done when:** a UI test changes a setting and re-runs the interview, which arrives as a proposal.

## Slice 12: Polish and housekeeping

- [ ] 2.19 Prune expired rows: `email_codes`, `rate_limits` windows and expired or rotated `refresh_tokens` (a scheduled
      Worker or on write), found by the 2.4 review. needs: 2.4. `any time`
- [ ] 3.8 Dynamic Type: the interview and preview screens use fixed system font sizes (`.font(.system(size:))`), which
      do not scale (docs/design-notes.md asks for `Font.custom(_, size:, relativeTo:)`). Bundle the fonts, scale every
      size, let rows wrap instead of clipping, and re-run the snapshot tests at a large size. needs: 3.3. `any time`

## Human, not for agents

- [ ] H.1 Coach review of the presets, invariants and strength exercise library (§12.1)
- [ ] H.2 Apply for the Garmin Training API early (§12.3)
- [ ] H.3 Legal review of injury and plan-guidance wording, and a privacy policy (§10, §12.7)

## Later: needs the paid Apple Developer Program

- [ ] L.1 Sign in with Apple alongside email (API and iOS)
- [ ] L.2 App Attest: attest on iOS, verify on the API, then turn on `APP_ATTEST_REQUIRED` for activity uploads
- [ ] L.3 TestFlight build for wider testing

## Later: needs Garmin API access

- [ ] G.1 Push workouts to Garmin Connect through the Training API (backend)
- [ ] G.2 Import from the Garmin Activity API as a second route besides Apple Health

## Web companion (after slice 12)

- [ ] 5.1 Web app shell, adjust plan, view progress (no running-session uploads)

**Gate E (human):** revisit `docs/autonomy.md` before widening auto-merge.
