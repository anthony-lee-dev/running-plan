# Running Planner: Agent Build Workflow

Oct 28, 2026 · @Anthony

## Decisions locked in

Everything runs on your MacBook Air for now: one monorepo in `~/Dev/running-plan`, synced to `anthony-lee-dev/running-plan`, a TypeScript API on Cloudflare Workers with D1, and agents that stop at an open PR.

| Decision | Choice | What it means for the workflow |
| --- | --- | --- |
| Backend | Hono on Workers, TypeScript | Domain code is pure; Cloudflare code lives only in `api/src/adapters/cloudflare/` and `api/src/index.ts`, checked on every verify run |
| Database | D1 (SQLite), migration risk accepted | SQL kept to portable basics; moving to Azure later means a new storage adapter plus a data export |
| Repo | One monorepo, **public** on GitHub Free | Free Actions minutes on standard runners, macOS included, so iOS gets a CI check; a ruleset can lock `main`; auto-merge is available for the autonomy dial. Never commit secrets |
| Where agents run | Claude Code on your Mac only, one git worktree per task | Hooks, the reviewer subagent and the `/ship` and `/next-task` skills in `.claude/` all load; no cloud sessions |
| Claude plan | Pro | Managed Code Review (Team and Enterprise only) is out, so review is a local subagent |
| Xcode | 27.1 | `verify.sh ios` picks the first available iPhone simulator, so no device name is hard-coded; iOS 17 minimum stays |
| Apple account | Free account (signed up); app is for your own use first | Covers the simulator and your own iPhone (re-install weekly). Sign-in is email with a one-time code; Sign in with Apple, App Attest and TestFlight sit in a backlog section for when you pay |
| Autonomy | Level 0, set in `autonomy.json` | Agents never merge; you merge every PR until you raise the level |

## Repo and local folder

The scaffold is already in `~/Dev/running-plan`. One script you run in Terminal finishes setup and pushes the first commit; after that the folder and GitHub stay in sync through normal git.

**Why a script.** Neither my sandbox nor the one on your Mac can reach GitHub or the npm registry, and remote tools are not allowed to write into `.claude/` or `.github/`. So those files wait in `setup/` until you run:

```bash
cd ~/Dev/running-plan
bash scripts/bootstrap.sh
```

It runs four steps:

1. Moves `setup/` into `.claude/` and `.github/`.
2. Runs `npm install` and `verify.sh spec api`.
3. Commits and pushes `main`. Before committing it shows the email your commits will carry and stops unless it is a GitHub noreply address (or you confirm). GitHub's repo holds only its auto-generated first commit (a README and a Node `.gitignore`, authored with your Gmail), so the script replaces that commit with the scaffold, once, before `main` is locked. If it ever finds real history there instead, it merges it and keeps the scaffold's version of each file.
4. Runs `scripts/setup-github.sh`, which turns on squash-only merges, auto-merge and branch clean-up, secret scanning with push protection and Dependabot alerts, and creates the ruleset on `main`.

It needs Node 22 or later and the GitHub CLI signed in as you (`gh auth login`).

**What is in the folder.**

| Path | What it holds |
| --- | --- |
| `CLAUDE.md` | Root rules: product scope, portability rule, pace and date conventions, definition of done, public-repo rule |
| `autonomy.json` | The autonomy level and the paths each level may auto-merge |
| `api/` | Hono app with a Workers entry and a Node entry, D1 health probe, pace formatting, two test files |
| `spec/openapi.yaml` | Only `/v1/health` so far; backlog task 1.2 derives the rest |
| `designs/` | Your System Design v1.0 file as is, plus the 11 dark boards as HTML source in `designs/dark/` |
| `docs/` | `backlog.md` (archive of the tasks finished before the move to GitHub issues, plus the per-slice end-to-end check), `design-notes.md` (dark tokens and screens), `autonomy.md` (how the dial works) |
| `scripts/` | `verify.sh`, `check-boundaries.sh`, `request-merge.py`, `setup-github.sh` with `github/ruleset-main.json`, and `bootstrap.sh` (removes itself) |
| `.claude/` | `settings.json` (permissions and the Stop hook), `hooks/stop-gate.py`, `agents/reviewer.md`, skills `ship` and `next-task` |
| `.github/` | `api-ci` and `ios-ci` workflows, and a PR template with a manual-gates section |

`ios/` holds only its `CLAUDE.md` for now, because I cannot build Xcode projects here; backlog task 1.3 creates the app on your Mac with XcodeGen, so the generated `.xcodeproj` never causes merge conflicts between worktrees.

**What I could and could not check.** Checked here: shell syntax, every JSON and YAML file parses, the boundary check catches a planted Cloudflare reference, the pace logic passes its test cases, and the Stop hook blocks five times on a failing verify, then lets Claude stop and stays quiet when green. Not run yet: `npm install`, typecheck, Vitest and the spec lint, since the npm registry is blocked here. The bootstrap script runs them first; if one fails, run `claude` in the folder and paste the error.

## Design and API as source of truth

Agents read the design and the API contract from files in the repo, never from claude.ai, so every session on your Mac sees the same thing.

**Design.** The 11 dark boards from your Claude Design canvas are committed as HTML in `designs/dark/DK-*.dc.html`. The exact colours, spacing, type and copy are in their inline styles. `docs/design-notes.md` summarises them: the palette (background `#1C1A15`, card `#27241D`, accent `#C9411B`), Bricolage Grotesque for headings with Inter for body, radii of 12 to 24, and 44 pt touch targets. The root `CLAUDE.md` tells agents to ignore the light and alternative-direction boards. The canvas stays the master: if you change it, re-export the `DK-*` files.

One gap remains: the boards need the canvas runtime to render, so I could not turn them into images. Export the 11 boards as PNGs from the canvas into `designs/dark/png/`; iOS snapshot tests compare against those.

**Behaviour.** Your `designs/Running Planner — System Design v1.0.md` is committed unchanged and referenced from `CLAUDE.md`.

**API contract first.** The system design lists 19 operations: sign-in and refresh, account delete, `plans/generate` (stateless, no auth), plan list, create, get, patch and delete, session patch and match, check-ins, `sync`, activity batch upload and list, proposal generate, accept and dismiss, and plan progress. Backlog task 1.2 (`ask first`) turns them into `spec/openapi.yaml`, and you review that PR line by line. The spec is linted with Redocly on every verify run; later tasks generate the Swift client (swift-openapi-generator) and run contract tests against both API entries.

## Task breakdown

Five phases, each ending in a gate you can check, all run on your Mac. The task list is the repo's GitHub issues, a milestone per slice; `/next-task` picks open defects first, then the first unblocked feature, so the issues are how you steer.

The finished phases and gates are archived in `docs/backlog.md`; the open slices, gates and human-only items are milestones and issues.

Read it top to bottom: a phase does not start until the gate above it passes, and the first gate is the one worth your closest attention, since everything else is built on that spec.

**Sizing a task** (rules of thumb):

- One PR is one endpoint group, one rule-engine behaviour, or one screen. Past about 400 changed lines, split it.
- Every task gets a plan, failing tests, then code; the `next-task` skill enforces that order, and issues labelled `ask-first` wait for your OK on the plan.
- A spec change gets its own PR before any code that uses it.
- A task is done only when its issue is closed: the PR body says `Closes #n`. For work with no PR of its own (a check run in a normal session, say), the agent closes the issue with a comment saying what was checked. Human-only issues are closed only when the agent did the work itself, you say you did it, or a read-only check shows it; PR manual-gate boxes always stay for you (root `CLAUDE.md` has the exact rule).
- Run tasks side by side with one worktree each: `claude --worktree 2-8-validators` in one terminal, `claude --worktree 3-2-interview` in another. Two or three at once is a sensible start: every session draws on the same Pro usage limits, and Xcode builds compete for the Air's CPU.
- Start with rule-engine tasks (validators 2.8 first, then 2.1 and 2.2 once the pace model in 2.9 is agreed): "green" is fully testable there, so they are the safest first hand-offs once the spec is merged.

## TDD and verification per layer

`bash scripts/verify.sh <api|spec|ios>` is the single definition of green. The Stop hook, `/ship` and CI all call it, so an agent cannot be "done" by one measure and red by another.

| Layer | Tests written first | Green means | Checked by |
| --- | --- | --- | --- |
| Rule engine (`api/src/domain`) | Table-driven cases for the 5K, 10K and half-marathon presets across interview answers; property tests for conservative start, bounded weekly load growth, strength sessions present, regenerate keeps past and user-owned sessions | Vitest passes | Stop hook, `api-ci` |
| API routes and adapters | Route tests through `app.request` on in-memory adapters; D1 adapter tests in the Workers test pool (task 1.5) | Boundary check, typecheck, Vitest | Stop hook, `api-ci` |
| Contract | Spec lint now; contract tests from `openapi.yaml` against the Workers and Node entries (task 2.7) | Redocly lint, contract suite | Stop hook, `api-ci` |
| iOS logic | Swift Testing for the offline edit queue, 24-hour draft expiry, min/km pace, local-date matching | `xcodebuild test` passes | Stop hook, ios-ci |
| iOS screens | Snapshot tests against `designs/dark/png/`; one UI test for interview, then preview, with no account | Snapshots within tolerance | Stop hook, ios-ci |
| Dependencies | Nothing to write; `npm audit` runs inside `verify.sh`, dependency review runs on every PR, Dependabot opens weekly update and security PRs | No high or critical advisory in runtime packages; no PR adds a vulnerable package | Stop hook, `api-ci`, reviewer subagent |

**Two required checks on `main`.** `api` (Ubuntu) runs spec lint and the API checks on every PR. `ios` (macOS, the newest Xcode on the runner) builds and tests only when `ios/`, `spec/` or the verify script changed, and passes in seconds otherwise. Both run on every PR without path filters, because a required check that never reports would block a PR forever. The runner's Xcode can differ from your 27.1, so the iOS deployment target stays at 17.

**Manual gates agents cannot close.** Send-to-watch (WorkoutKit), HealthKit import, Sign in with Apple and App Attest need a real device or your Apple account. The PR template lists them as unticked boxes, and agents never tick them.

**How the loop keeps going without you.**

- **Stop hook (`.claude/hooks/stop-gate.py`).** When Claude tries to finish, it runs `verify.sh` for the packages the branch changed. On red it returns a block decision with the last 60 lines of output, so Claude keeps fixing. After five blocks in one session it lets Claude stop with a message, so a problem it cannot fix (a missing simulator, say) never loops forever.
- **Definition of done** is in the root `CLAUDE.md`, so every session reads it: verify green, PR opened by `/ship` and marked ready, manual gates listed, never merge.
- **Test the hook once** before trusting it: in a worktree, break a pace test, ask Claude to finish, and check it keeps going. I verified the script's logic here, but the block format follows the hooks docs as I could read them, not a live Claude Code run.
- **Cost of the hook:** it runs on every stop, and with iOS changes that means a simulator build each time. It also fires when Claude stops to ask you something, so with red tests it pushes on up to five times before the question reaches you. If either gets in the way, limit the hook to `api spec` and leave iOS to `/ship`.

## PR review loop and the autonomy dial

`/ship` runs the whole loop on your Mac. At level 0 it stops at a reviewed, green PR for you to merge; at a higher level it hands the merge to GitHub, which merges only when the required checks pass.

1. **Verify:** `verify.sh` for the touched packages, fixed until green.
2. **Fresh-eyes review:** the `reviewer` subagent reads only the diff and the repo, not the conversation that wrote it, and returns BLOCKER, SHOULD-FIX and NIT findings. Claude fixes and re-verifies, for at most three rounds; anything left goes in the PR body.
3. **Push and open:** branch `agent/<task>`, `gh pr create` with the template (what changed, verify result, manual gates, remaining NITs), then `gh pr ready`.
4. **Request merge:** `python3 scripts/request-merge.py <PR>`. At level 0 it leaves the PR for you; otherwise it turns on GitHub auto-merge if the PR qualifies.
5. **Watch CI:** `gh pr checks --watch`; on a failure it reads `gh run view --log-failed`, fixes and pushes again. A queued auto-merge waits through this.
6. **Stop:** a one-line summary saying whether the PR is queued to merge or waiting for you.

**When you leave review comments,** reopen the PR in its own worktree with `claude --worktree "#<PR number>"` and ask it to address them; `/ship` then runs again.

**What this needs on your Mac:** the GitHub CLI signed in (`brew install gh`, `gh auth login`). Agents push with your credentials, so commits and PRs show as yours, with Claude's co-author line.

**Left out for now, and why.** Cloud auto-fix and Projects run in cloud sessions, which you have ruled out for now. Managed Code Review needs a Team or Enterprise plan. The Claude GitHub Action could add a second reviewer that runs on GitHub with a `CLAUDE_CODE_OAUTH_TOKEN` from your Pro plan, without your Mac being awake; add it when local review stops being enough.

**The autonomy dial** is one number in `autonomy.json`. Raise it in a PR you merge yourself; the merge script always reads the level from `main`, so a PR can never raise its own level.

| Level | May auto-merge | Move up when |
| --- | --- | --- |
| 0 (now) | Nothing; you merge every PR | Starting point |
| 1 | `docs/`, `api/test/`, `api/src/domain/` | About 10 merged agent PRs needed no rework |
| 2 | `docs/`, all of `api/` | Contract tests have caught a real drift |
| 3 | Level 2 plus `ios/`, `designs/` | You trust the snapshot tests; unticked manual-gate boxes still block |

Never auto-merged at any level: `spec/`, `autonomy.json`, `.claude/`, `.github/`, and the merge and setup scripts.

**What enforces what.**

- **GitHub, server side:** the ruleset on `main` requires a PR, requires the `api` and `ios` checks from GitHub Actions, and blocks force pushes and branch deletion. Nobody can push to `main` directly, you included, and auto-merge cannot fire before the checks pass.
- **`scripts/request-merge.py`, on your Mac:** decides whether to ask for auto-merge at all, from the level on `main`, the changed paths and any unticked manual-gate boxes.
- **`.claude/settings.json`, guard rail:** denies `gh pr merge`, `gh api`, `gh repo edit`, pushes to `main`, force pushes and deploys, so agents go through the script.

Decided for now: agents use your GitHub login, so GitHub cannot tell their merges from yours, and the ruleset requires no approval (you cannot approve your own PRs). Keeping agents from merging at level 0 therefore rests on the two local layers. For a gate GitHub enforces too, give agents their own GitHub account with write access and set the required approvals to 1 in `scripts/github/ruleset-main.json`.

## Which skill, tool or command at each step

With everything local, almost every step is a Claude Code command or a CLI on your Mac; no connector or GitHub App is needed to start.

| Step | Use | Notes |
| --- | --- | --- |
| Pick and build a task | `/next-task` skill in the repo | Reads the open GitHub issues, plans, writes failing tests, codes, then runs `/ship` |
| Review, PR, CI loop | `/ship` skill and `reviewer` subagent | Built-in `/code-review` (any plan) is a second opinion when you want one |
| Keep going until green | Stop hook in `.claude/settings.json` | Up to five blocks per session |
| Run tasks in parallel | `claude --worktree <name>` | One branch and folder per session under `.claude/worktrees/`; `.worktreeinclude` copies `.dev.vars` |
| Follow a session from your phone | `/remote-control` inside a running session | Answer its questions from the Claude app while it keeps running on the Mac; check that your Pro plan offers it |
| Read the dark designs | `designs/dark/DK-*.dc.html` and `docs/design-notes.md` | The canvas link is for you; agents use the files |
| Design handoff (task 1.4) and accessibility checks | `design:design-handoff` and `design:accessibility-review` skills | Both are in this chat; I have not confirmed they load in Claude Code on your Mac |
| Cloudflare setup | `npx wrangler login`, `wrangler d1 create`, `wrangler d1 migrations` | Agents are denied `wrangler deploy`; you deploy with `npm run deploy -w api` |
| Cloudflare look-ups | Cloudflare connector in this chat | Its own notice says it is deprecated in favour of the Cloudflare API MCP server at `https://mcp.cloudflare.com/mcp` |
| GitHub | `gh` CLI with your login | PRs, checks, CI logs |
| iOS build and test | `xcodegen`, `xcodebuild`, `xcrun simctl` through `verify.sh ios` | XcodeBuildMCP (community) is optional; start with the script |
| Phase 2 web checks | A browser for screenshots against the design | Later |

One habit across all of it: when you correct an agent, tell it to add the correction to the relevant `CLAUDE.md` in the same PR. That file is the only memory every session shares.

## Day-1 checklist and open items

The scaffold is done and the repo is public; these steps on your Mac get you to the first agent PR.

- [x] Scaffold written to `~/Dev/running-plan`
- [x] Repo made public
- [x] Free Apple Developer account
- [x] Install the tools: Node 22 or later, `brew install gh xcodegen`, then `gh auth login`
- [x] Hide your email (steps below), then run `bash scripts/bootstrap.sh`; it should end with "main is protected"
- [ ] On GitHub, check that `api` and `ios` ran green on `main` and that Settings, Rules shows the `main` ruleset
- [ ] Sign in to Xcode with your Apple account (Xcode, Settings, Accounts), so your Personal Team can run the app on your iPhone
- [ ] `npx wrangler login`, then `npx wrangler d1 create running-plan` from `api/`; put the id in `api/wrangler.toml` (your first small PR)
- [ ] Export the 11 dark boards as PNGs into `designs/dark/png/`
- [ ] Test the Stop hook once with a deliberately broken test
- [ ] `claude --worktree spec`, then `/next-task`: task 1.2, the full `openapi.yaml`; review it line by line and merge (gate A)
- [ ] At the same time, `claude --worktree ios-bootstrap`, then `/next-task 1.3` for the Xcode project and app shell

**Hiding your email (before the bootstrap).**

1. On github.com: profile picture, Settings, Emails.
2. Turn on **Keep my email addresses private**. GitHub then shows your noreply address, like `12345678+anthony-lee-dev@users.noreply.github.com`; copy it.
3. Turn on **Block command line pushes that expose my email**, so a push carrying your Gmail is refused.
4. In Terminal: `git config --global user.email "<the noreply address>"`, then check with `git config user.email`.

The bootstrap then replaces GitHub's first commit, the only one with your Gmail. GitHub may keep that old commit reachable by its direct link for a while, but it drops out of the history and the repo pages.

**Bundle ID (decided).**

- **Release ID:** `ca.anthonylee.runningplan`, from your domain anthonylee.ca. Kept unused until you pay, because an ID the free Personal Team registers can stay blocked for your paid team, with no self-service way to release it.
- **Free-team builds:** `ca.anthonylee.runningplan.dev`, set by a suffix in `ios/Signing.xcconfig`. If that one ever gets stuck, nothing is lost: the paid team uses the release ID.
- **Derived IDs:** `<bundle id>.watchkitapp`, `<bundle id>.widgets`, `group.<bundle id>`. Recorded in `ios/CLAUDE.md` for task 1.3.
