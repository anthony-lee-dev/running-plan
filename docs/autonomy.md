# Autonomy level

Current level: **0** (set in `autonomy.json`). Agents stop at a ready PR with green checks; the human merges.

| Level | Auto-merge allowed for | Notes |
| --- | --- | --- |
| 0 | Nothing | The human merges every PR |
| 1 | `docs/**`, `api/test/**`, `api/src/domain/**` | Suggested after about 10 merged agent PRs that needed no rework |
| 2 | `docs/**`, `api/**` | After contract tests have caught a real drift |
| 3 | Level 2 plus `ios/**`, `designs/**` | Unticked manual-gate boxes still block |

Never auto-merged at any level: `spec/**`, `autonomy.json`, `.claude/**`, `.github/**`, and the merge and setup scripts.

## Changing the level

Edit `"level"` in `autonomy.json` and merge that PR yourself. The level is always read from `main`, so a PR
cannot raise its own level.

## What enforces what

- **GitHub (server side, cannot be bypassed):** the ruleset on `main` requires a PR, requires the `api` and `ios`
  checks from GitHub Actions, and blocks force pushes and deletion. Auto-merge only fires once those checks pass.
- **`scripts/request-merge.py` (local):** decides whether to request auto-merge at all, from the level on `main`,
  the changed paths and the manual-gate boxes.
- **`.claude/settings.json` (local guard rail):** denies `gh pr merge`, `gh api`, `gh repo edit`, pushes to `main`,
  force pushes and deploys, so agents go through the script.

Agents act with your GitHub login, so GitHub sees their merges as yours: it cannot tell you and an agent apart.
The local layers are what separate the two. For a hard human gate, give agents their own GitHub account with write
access and set `required_approving_review_count` to 1 in `scripts/github/ruleset-main.json`.
