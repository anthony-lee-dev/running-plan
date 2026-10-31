# Backlog (archive)

The task list now lives in **GitHub issues**: one issue = one task = one PR, a milestone per slice (its description
holds the slice's **Done when**), labels `type: feature` / `type: defect` / `type: chore`, `area: *`, `ask-first`,
`any-time`, `human-only` and `later`. Issue titles keep the old task ID (`[2.6] ...`), so references such as
"backlog 2.15" in code and docs still resolve. `/next-task` picks open defects first, then the earliest unblocked
feature. See `scripts/setup-issues.sh` and `scripts/github/issues.json` for how they were created.

This file keeps the tasks finished before the move, as a record, and the end-to-end check every slice follows.
Sources: § points to `designs/Running Planner — System Design v1.0.md` (what to build); test approach and
manual-gate rules come from `designs/Running Planner Agent Build Workflow.md` (how to build).

**End-to-end check for every slice** (from slice 1 on):
1. API contract tests for the slice's endpoints pass on the Workers and the Node entry.
2. An iOS UI test runs the slice's flow in the simulator against the local Node API (in memory, no network).
3. The slice's last PR lists a device check against the deployed API as an unticked `## Manual gates` box for the
   human; WorkoutKit and HealthKit checks are Gate D items. Agents never tick these boxes.
4. After each deploy, `npm run smoke -w api` passes against the deployed API (task 2.22).

Every screen task also needs 0.5 (the dark-board PNGs) for its snapshot test.

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

- [x] 2.7 Contract tests from `spec/openapi.yaml`, run against both the Workers and the Node entry, for every
      endpoint that exists today (generate, auth, profile, plans and sessions, activities, matches, check-ins).
      Request validation must enforce `unevaluatedProperties: false` (Swift's generator ignores it). Later slices
      add their endpoints to it. needs: 2.3, 2.4, 2.5, 2.11, 2.17
- [x] 3.9 iOS UI tests against a local API: start the Node entry (in-memory stores) for the UI test target and point
      the app at it with `API_BASE_URL`; port the interview-to-preview UI test to it. Signing in from a UI test needs
      a known code: an email sender for the Node entry that only runs in tests, never in the Workers entry. The CI
      change in `scripts/` or `.github/` needs the human to merge. needs: 3.3

- [x] 2.22 Smoke test for the deployed API (`npm run smoke -w api`, any URL with `SMOKE_URL`): health, a generate
      from the engine version on `main`, every built signed-in operation answering 401 rather than 404, and an unknown
      path under a signed-in prefix answering 404 (so plan and session routes check their token per route). Read-only,
      no account. Also runs in-process in verify so it stays correct. needs: 2.7

**Done when:** both run in CI, and the interview-to-preview UI test passes against the local API.

## Slice 2: Sign in and save my plan

- [x] 3.4 Email sign-in and save plan: the Save button on the preview signs in with a one-time code, then creates the
      plan; tokens in the Keychain, refresh on 401; a way to close the preview. needs: 3.3, 3.9

**Done when:** a UI test goes interview, preview, sign in, saved plan; device check: sign in with a real email code
and save a plan against the deployed API.

## Slice 3: See my plan

- [x] 3.5 Next (DK-Next), Plan week (DK-Week), whole plan (DK-Whole); paces shown as `6:30/km`. needs: 3.4, 0.5

**Done when:** a UI test shows the saved plan on all three screens, with snapshot tests against the dark boards.

## Slice 4: Open and edit a session

- [x] 2.21 Unlink an activity when its session or plan is deleted (left from 2.12; today the match is hidden and the
      activity stays `matched`, out of the inbox, until it is matched again or given a disposition). needs: 2.5
- [x] 4.1 Session spec sheet and editor (DK-Session, DK-Editor): steps in watch-builder order with repeat groups,
      strength exercise checklist, copy or share as text, custom sessions, build a plan from blank, quick
      adjustments (shorter, easier, swap, skip) that mark the session user-owned, optional before-session check-in.
      Edits go straight to the API while online (offline edits are slice 5). needs: 3.5, 0.5

**Done when:** a UI test edits a session and the change is still there after relaunching the app.

## Slice 6: Put it on my watch

- [x] 4.2 Send to watch with WorkoutKit: Add to Watch preview, and scheduling a rolling window (up to 15 workouts).
      Manual-gate box: WorkoutKit and HealthKit work on the free Personal Team. needs: 4.1, 0.6

**Done when:** unit tests for the workout mapping pass; Gate D item: a session reaches the Apple Watch.

## Slice 7: Import runs and match them

- [x] 2.12 Matches and check-ins: `PUT /v1/sessions/{id}/match`, `POST /v1/sessions/{id}/checkins`. Matches and check-ins
      are done (PUT and DELETE match, `PATCH /v1/activities/{id}`, `match` on listed activities, check-ins, and
      `suggestedSessionId` in the upload results; the pain flag's urgent proposal comes with 2.14; unlinking on delete
      is 2.21). needs: 2.5, 2.11
- [x] 4.3 HealthKit import inbox and matching by local date (DK-Inbox, unit tests for local-date matching): running,
      strength and other workout types; extra runs, unmatched, two runs in one day, missed sessions; manual entry
      as a short fallback. needs: 2.12, 3.5, 0.5, 0.6

**Done when:** a UI test imports a run (manual entry) and confirms its match; Gate D item: a run recorded in Health
(Apple Watch, Garmin and Nike data) lands in the inbox and matches.

**Gate D (human, needs 0.6):** device checklist ticked: send-to-watch (slice 6) and HealthKit import (slice 7).

Open work (slices 5 and 8 to 12, the human-only items, the `Later` sections, the web companion, and Gates D and E)
is in GitHub issues.
