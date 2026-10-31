# Running Planner

A running **planner** (not a tracker): users set a goal, get a suggested X-week plan they can edit at any time,
set up each session on their watch by hand, then import results and review. Live tracking happens in other apps.

## Layout

- `api/` TypeScript API on Cloudflare Workers (Hono) with D1. See `api/CLAUDE.md`.
- `ios/` SwiftUI app, iOS 17 minimum, phase 1 focus. See `ios/CLAUDE.md`.
- `web/` phase 2 planning companion: React + Vite, hosted as Cloudflare Workers static assets. See `web/README.md`.
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

1. `bash scripts/verify.sh <package>` exits 0 for every package you touched (`api`, `spec`, `web`, `ios`).
2. Work is on a branch named `agent/<short-task>` with a PR opened by `/ship`, marked ready for review.
3. Manual-gate items (real device, Apple account) are listed as unticked boxes in the PR body, never faked.
4. **Never run `gh pr merge`.** `/ship` calls `python3 scripts/request-merge.py`, which requests auto-merge only when
   `autonomy.json` on `main` allows it (see `docs/autonomy.md` for what each level auto-merges). Never edit `autonomy.json` to get a merge.

## Working style

- One PR = one backlog task, end to end, with no size limit (the human's call: splitting a task across sessions
  loses context). The exception is a contract change, which is a `spec/openapi.yaml` PR of its own first.
- Build in vertical slices: `docs/backlog.md` groups tasks by feature, each with only the API and iOS work it needs
  and an end-to-end check (contract tests, a UI test against the local API, a device check) before the next slice.
- Pick work from `docs/backlog.md` (`/next-task`). Never report a backlog task as done without ticking it in
  `docs/backlog.md` in the same change, including work done outside `/next-task` (a check run in a normal
  session, say). When the work has no PR of its own, tick it, say in your reply that the tick is uncommitted,
  and ask the human whether to ship it now or fold it into the next PR. A task that is only partly done stays
  unticked; say what is left.
- Human-only items (Phase 0, gates, "Human, not for agents") are ticked only when you did the work yourself in
  the session, the human says they did it, or a read-only check shows it is done; never on inference. Ticking
  a backlog line never ticks the `## Manual gates` boxes in a PR body: those stay for the human.
- Branch from `origin/main`, never from an unmerged branch. A stacked branch needs a rebase after its base is
  squash-merged, and that rebase needs a force-push, which is denied. To bring `main` into a pushed branch, merge
  it in and push.
- `/next-task` hands each PR to its own worker subagent in a git worktree, so one session can run a whole slice
  without filling its context. Workers follow `.claude/skills/next-task/references/worker-brief.md`.
- When the human corrects you, add the correction to the relevant `CLAUDE.md` in the same PR.
