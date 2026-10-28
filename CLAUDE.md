# Running Planner

A running **planner** (not a tracker): users set a goal, get a suggested X-week plan they can edit at any time,
set up each session on their watch by hand, then import results and review. Live tracking happens in other apps.

## Layout

- `api/` TypeScript API on Cloudflare Workers (Hono) with D1. See `api/CLAUDE.md`.
- `ios/` SwiftUI app, iOS 17 minimum, phase 1 focus. See `ios/CLAUDE.md`.
- `web/` phase 2 planning companion. Empty for now.
- `spec/openapi.yaml` the API contract. The only place endpoints are defined.
- `designs/` source of truth for behaviour and looks:
  - `designs/Running Planner — System Design v1.0.md` behaviour, data model, endpoints (what to build).
  - `designs/Running Planner Agent Build Workflow.md` phases, gates, test approach per layer, review loop,
    autonomy dial and Day-1 setup (how to build).
  - `designs/dark/DK-*.dc.html` the 11 dark-theme screens (HTML source with exact colours and spacing).
  - `docs/design-notes.md` tokens and the screen-to-endpoint map pulled from those screens.
- `docs/backlog.md` the task list agents pick from. `autonomy.json` and `docs/autonomy.md` what may auto-merge.
- The repo is **public**: never commit secrets (`.dev.vars` is gitignored; GitHub push protection also blocks known secret formats).

## Rules that apply everywhere

- Write the failing test first, then the code. Every PR adds or changes tests.
- Contract first: a change to an endpoint is a PR to `spec/openapi.yaml` on its own, before any code using it.
- Portability: nothing outside `api/src/adapters/cloudflare/` and `api/src/index.ts` may reference Cloudflare
  (`cloudflare:`, `@cloudflare/`, `D1Database`, `KVNamespace`, `R2Bucket`). Domain code is pure functions, no I/O.
- Pace is minutes per km, shown as `6:30/km`. Sessions are stored as local calendar dates (`YYYY-MM-DD`) and
  matched by local date. Rule-generated plans start conservative and are always suggestions.
- Dependencies: `verify.sh` audits npm packages (high or critical fails for runtime packages, warns for dev
  tooling) and CI's dependency review blocks PRs that add a vulnerable package. Before adding a package, check
  whether an existing one covers it; after adding one, `npm audit` must stay clean. A dev-tooling warning becomes
  a backlog task, not a fix inside an unrelated PR.
- Sign-in is email (one-time code) for now. Sign in with Apple and App Attest wait for the paid Apple account
  (backlog "Later"); keep App Attest behind `APP_ATTEST_REQUIRED`, default off.
- The unsaved preview draft lives on the device for 24 hours. The `plans/generate` endpoint is stateless and unauthenticated.
- Ignore the light and alternative-direction screens in the design canvas; only `DK-*` boards count.

## Definition of done

1. `bash scripts/verify.sh <package>` exits 0 for every package you touched (`api`, `spec`, `ios`).
2. Work is on a branch named `agent/<short-task>` with a PR opened by `/ship`, marked ready for review.
3. Manual-gate items (real device, Apple account) are listed as unticked boxes in the PR body, never faked.
4. **Never run `gh pr merge`.** `/ship` calls `python3 scripts/request-merge.py`, which requests auto-merge only when
   `autonomy.json` on `main` allows it (level **0** today: the human merges). Never edit `autonomy.json` to get a merge.

## Working style

- One PR = one endpoint group, one rule-engine behaviour, or one screen. Past about 400 changed lines, split it.
- Pick work from `docs/backlog.md` (`/next-task`); tick it off in the same PR.
- Never report a backlog task as done without ticking it in `docs/backlog.md` in the same change. That covers
  work done outside `/next-task` too (Phase 0 setup, checks run in a normal session). When the work has no PR
  of its own, tick it, say in your reply that the tick is uncommitted, and ask the human whether to ship it now
  or fold it into the next PR. A task that is only partly done stays unticked; say what is left.
- When the human corrects you, add the correction to the relevant `CLAUDE.md` in the same PR.
