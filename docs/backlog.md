# Backlog

Agents take the first unticked task whose phase gate has passed and whose `needs` are ticked (`/next-task`).
One task = one PR. `ask first` = post the plan and wait for the human before writing code.
Task numbers are stable IDs, not order: work top to bottom within a phase. Tasks without a shared `needs` can run
side by side, one worktree each (`claude --worktree <name>`); two or three at once is a sensible limit.

Sources: § points to `designs/Running Planner — System Design v1.0.md` (what to build). The test approach per layer,
gates and manual-gate rules come from `designs/Running Planner Agent Build Workflow.md` (how to build).

## Phase 0: Setup on the Mac (human)

From the workflow doc's Day-1 checklist. Each line says what it unblocks.

- [x] 0.1 Tools installed, email hidden, `bash scripts/bootstrap.sh` ended with "main is protected"
- [x] 0.2 On GitHub, `api` and `ios` ran green on `main`, and Settings, Rules shows the `main` ruleset (before any PR)
- [x] 0.3 Test the Stop hook once: break a pace test in a worktree, ask Claude to finish, check it keeps going
      (before the first agent task)
- [x] 0.4 `npx wrangler login`, `npx wrangler d1 create running-plan` from `api/`, put the id in `api/wrangler.toml`
      as a small PR (before any deploy; 1.5 tests run locally without it)
- [x] 0.5 Export the 11 dark boards as PNGs into `designs/dark/png/` (needed by the snapshot tests in phase 3 and 4)
- [x] 0.6 Sign in to Xcode with the Apple account so the Personal Team can run the app on the iPhone (needed for gate D)
- [x] 0.7 Re-run `bash scripts/setup-github.sh` after 1.6 merges, to turn on Dependabot security update PRs
      (agents may not run it)

## Phase 1: Foundations

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

**Gate A (human):** approve and merge 1.2 line by line. Everything below builds on it.

## Phase 2: API and plan engine (needs gate A)

Engine tasks (2.8, 2.9, 2.1, 2.2, 2.10) are pure domain code with table-driven and property tests: the safest
first hand-offs. 2.8 is free to start at once; 2.9 is `ask first`, and 2.1 waits for both.

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
- [x] 2.3 `POST /v1/plans/generate` (stateless, no auth) with the §7 abuse controls: rate limit by IP and device,
      strict schema bounds, no persistence, no logging of interview answers, bounded compute and response size.
      Rate limiting goes through a `RateLimiter` port; the Workers implementation lives in `adapters/cloudflare/`.
      needs: 2.1
- [x] 2.4 `ask first` Auth: email sign-in with a one-time code, refresh tokens with client-type scopes, account
      delete. Sending email goes through an `EmailSender` port; the dev adapter logs the code, and the task
      proposes a provider. needs: 1.5
- [x] 2.5 Plans and sessions CRUD, including blank plans and user-owned custom sessions; edits carry the base
      revision. needs: 2.4
- [ ] 2.6 `POST /v1/sync` for the offline edit queue: idempotency keys, cursor, per-session revision conflicts,
      tombstones. needs: 2.5
- [x] 2.11 Activities: `POST /v1/activities:batch` (native clients only, by token scope; App Attest is L.2) and
      `GET /v1/activities`; dedupe on start time, duration and distance, not only the external id. needs: 2.4
- [ ] 2.12 Matches and check-ins: `PUT /v1/sessions/{id}/match`, `POST /v1/sessions/{id}/checkins`. Matches are done
      (PUT and DELETE match, `PATCH /v1/activities/{id}`, `match` on listed activities). Left: check-ins (the pain
      flag's urgent proposal waits for 2.14), `suggestedSessionId` in the upload results, and unlinking an activity
      when its session or plan is deleted (today the match is hidden and the activity stays `matched`, out of the
      inbox, until it is matched again or given a disposition, which clears the old match). needs: 2.5, 2.11
- [x] 2.13 Proposal engine `propose_adjustments` (§6.6): missed key session is dropped not rescheduled, harder than
      planned eases next week, pain flag reduces load, consistently easy progresses; never edits the plan;
      user-owned sessions locked; off for blank plans unless opted in. needs: 2.1
- [ ] 2.14 Proposals API: generate, accept, dismiss; stale when the plan revision moves; re-running the interview
      regenerates future weeks only (property test: keeps past and user-owned sessions) and is delivered as a
      proposal. needs: 2.12, 2.13
- [ ] 2.15 `GET /v1/plans/{id}/progress`: adherence, volume trend, key and strength sessions completed, goal
      countdown. The computation is done (`api/src/domain/insights.ts`, `computeProgress`); the route and its store
      reads are left. needs: 2.12
- [ ] 2.16 Account data export (§10). needs: 2.12
- [x] 2.17 Profile API: target display, derived pace ranges and their provenance, scheduling preferences, review
      frequency and day (§5, §6.6a). needs: 2.4
- [ ] 2.20 Spec clarification for `PATCH /v1/profile` (own PR, found by the 2.17 review): say that `heartRate`,
      `scheduling` and `review` replace their whole section (the only way to clear a field), and decide whether
      ranges may be equal and sub-objects reject unknown keys, as the API does today. needs: 2.17
- [ ] 2.18 Weekly review summary API: planned vs completed, distance and time against plan, key sessions, check-in
      feel and pain, inbox loose ends (§6.6a); computed on the backend so the web sees it too. needs: 2.12, 2.17
- [ ] 2.19 Prune expired rows: `email_codes`, `rate_limits` windows and expired or rotated `refresh_tokens` (a scheduled
      Worker or on write), found by the 2.4 review. needs: 2.4
- [ ] 2.7 Contract tests from `spec/openapi.yaml`, run against both the Workers and the Node entry. Request
      validation must enforce `unevaluatedProperties: false` (Swift's generator ignores it). needs: every
      other phase 2 task

**Gate B:** contract tests green on both entries.

## Phase 3: iOS shell and onboarding (needs 1.3, gate B for networked parts)

Logic is tested with Swift Testing; each screen gets a snapshot test against `designs/dark/png/` (needs 0.5).

- [x] 3.1 Generated API client from the spec with Apple's swift-openapi-generator, run by
      `scripts/generate-api-client.sh` with the output committed (the build plugin needs a human to trust it in
      Xcode and `xcodebuild` skips that only with a safety flag). `verify.sh ios` fails if it is stale. needs: 1.3
- [x] 3.2 Interview screen (DK-Interview): Appendix B questions, one per screen, skippable with defaults.
      needs: 1.3, 0.5
- [x] 3.3 Preview with no account (DK-Preview): whole plan, week 1, a sample session, assumptions and warnings;
      changing an answer regenerates; draft kept on the device for 24 hours (unit test for expiry).
      needs: 3.1, 3.2, 0.5
- [ ] 3.4 Email sign-in and save plan. needs: 3.3
- [ ] 3.5 Next (DK-Next), Plan week (DK-Week), whole plan (DK-Whole); paces shown as `6:30/km`. needs: 3.4, 0.5
- [ ] 3.6 Offline edit queue and sync: unit tests for the queue, keep-mine-or-theirs conflict prompt, tombstones,
      stale proposals. needs: 3.4
- [ ] 3.7 `ask first` Goal and settings: goal, re-run interview, review frequency and day, target display, account,
      privacy, data export. There is no DK board for it, so the plan proposes a layout from the existing tokens.
      needs: 3.4, 2.17
- [ ] 3.8 Dynamic Type: the interview and preview screens use fixed system font sizes (`.font(.system(size:))`), which
      do not scale (docs/design-notes.md asks for `Font.custom(_, size:, relativeTo:)`). Bundle the fonts, scale every
      size, let rows wrap instead of clipping, and re-run the snapshot tests at a large size. needs: 3.3

**Gate C:** snapshot tests match the dark boards; the interview-to-preview UI test passes with no account.

## Phase 4: iOS training loop (needs gate C)

PRs that touch WorkoutKit or HealthKit list the device checks as unticked boxes; agents never tick them.
Every screen task here also needs 0.5 for its snapshot test.

- [ ] 4.1 Session spec sheet and editor (DK-Session, DK-Editor): steps in watch-builder order with repeat groups,
      strength exercise checklist, copy or share as text, custom sessions, build a plan from blank, quick offline
      adjustments (shorter, easier, swap, skip) that mark the session user-owned, optional before-session check-in.
      needs: 0.5
- [ ] 4.2 Send to watch with WorkoutKit: Add to Watch preview, and scheduling a rolling window (up to 15 workouts).
      Manual-gate box: WorkoutKit and HealthKit work on the free Personal Team. needs: 4.1, 0.6
- [ ] 4.3 HealthKit import inbox and matching by local date (DK-Inbox, unit tests for local-date matching): running,
      strength and other workout types; extra runs, unmatched, two runs in one day, missed sessions; manual entry
      as a short fallback. needs: 0.5, 0.6
- [ ] 4.4 Plan vs actual and check-in (DK-CheckIn); pain guidance shows whatever the review setting. needs: 4.3
- [ ] 4.5 Weekly review and proposals (DK-Review), review frequency setting (default Weekly plus urgent).
      needs: 4.4, 2.18
- [ ] 4.6 Progress (DK-Progress). needs: 0.5

**Gate D (human, needs 0.6):** device checklist ticked: send-to-watch, HealthKit import (check Apple Watch, Garmin
and Nike data).

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

## Phase 5: Web companion

- [ ] 5.1 Web app shell, adjust plan, view progress (no running-session uploads)

**Gate E (human):** revisit `docs/autonomy.md` before widening auto-merge.
