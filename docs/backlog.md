# Backlog

Agents take the first unticked task whose phase gate has passed (`/next-task`). One task = one PR.
`ask first` = post the plan and wait for the human before writing code.

## Phase 1: Foundations

- [x] 1.1 Monorepo scaffold, CLAUDE.md files, verify scripts, Stop hook, reviewer, `/ship`, api-ci
- [ ] 1.2 `ask first` Derive the full `spec/openapi.yaml` from the system design (all 15 endpoints, schemas, auth). Spec only, no code.
- [ ] 1.3 iOS bootstrap: `ios/project.yml` (XcodeGen), SwiftUI app shell with the four tabs, Swift Testing target, `verify.sh ios` green
- [ ] 1.4 Design handoff: extend `docs/design-notes.md` with component states and a screen-to-endpoint map
- [ ] 1.5 D1 schema: first migration from the system design data model, D1 adapter tests with `@cloudflare/vitest-pool-workers`

**Gate A (human):** approve and merge 1.2 line by line. Everything below builds on it.

## Phase 2: API and plan engine (needs gate A)

- [ ] 2.1 Rule engine: 5K preset, table-driven tests over interview answers, property tests for conservative start
- [ ] 2.2 Rule engine: 10K and half-marathon presets, strength sessions included
- [ ] 2.3 `POST /v1/plans/generate` (stateless, no auth)
- [ ] 2.4 `ask first` Auth: email sign-in with a one-time code, refresh tokens, account delete. Sending email goes through an `EmailSender` port; the dev adapter logs the code, and the task proposes a provider
- [ ] 2.5 Plans and sessions CRUD; regenerate future weeks keeps past and user-owned sessions
- [ ] 2.6 `POST /v1/sync` for the offline edit queue
- [ ] 2.7 Contract tests from `spec/openapi.yaml`, run against both the Workers and the Node entry

**Gate B:** contract tests green on both entries.

## Phase 3: iOS shell and onboarding (needs 1.3, gate B for networked parts)

- [ ] 3.1 Generated API client from the spec
- [ ] 3.2 Interview screen (DK-Interview)
- [ ] 3.3 Preview with no account, 24-hour local draft (DK-Preview)
- [ ] 3.4 Email sign-in and save plan
- [ ] 3.5 Next (DK-Next), Plan week (DK-Week), whole plan (DK-Whole)
- [ ] 3.6 Offline edit queue and sync

**Gate C:** snapshot tests match the dark boards; interview-to-preview UI test passes with no account.

## Phase 4: iOS training loop

- [ ] 4.1 Session spec sheet and editor (DK-Session, DK-Editor)
- [ ] 4.2 Send to watch with WorkoutKit
- [ ] 4.3 HealthKit import inbox and matching by local date (DK-Inbox)
- [ ] 4.4 Plan vs actual and check-in (DK-CheckIn)
- [ ] 4.5 Weekly review and proposals (DK-Review), review frequency setting
- [ ] 4.6 Progress (DK-Progress)

**Gate D (human):** device checklist ticked: send-to-watch, HealthKit import.

## Later: needs the paid Apple Developer Program

- [ ] L.1 Sign in with Apple alongside email (API and iOS)
- [ ] L.2 App Attest: attest on iOS, verify on the API, then turn on `APP_ATTEST_REQUIRED` for activity uploads
- [ ] L.3 TestFlight build for wider testing

## Phase 5: Web companion

- [ ] 5.1 Web app shell, adjust plan, view progress (no running-session uploads)

**Gate E (human):** revisit `docs/autonomy.md` before widening auto-merge.
