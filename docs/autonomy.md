# Autonomy level

Current level: **2** (set in `autonomy.json`). Agents request auto-merge for `docs/**`, `api/**` and `ios/**` PRs with green checks; everything else waits for the human.

| Level | Auto-merge allowed for | Notes |
| --- | --- | --- |
| 0 | Nothing | The human merges every PR |
| 1 | `docs/**`, `api/test/**`, `api/src/domain/**` | Suggested after about 10 merged agent PRs that needed no rework |
| 2 | `docs/**`, `api/**`, `ios/**` | After contract tests have caught a real drift |
| 3 | Level 2 plus `designs/**` | Unticked manual-gate boxes still block; device checks never do (they are issues) |

Never auto-merged at any level: `autonomy.json`, `.claude/**`, `.github/**`, the merge and setup scripts
(`scripts/spec-additive.mjs` included), and any change to `spec/**` that removes or alters part of the contract.

From level 2 (where `api/**` is covered), a change to `spec/openapi.yaml` that only adds may ride in its feature PR,
with the generated `web/src/api/schema.d.ts`. `scripts/spec-additive.mjs` compares the PR's spec with the commit it
branched from: new paths, methods, schemas, optional properties and parameters, response codes, enum values and
wording pass; a removal, a changed type or limit, a new `required`, or a new limit on something that exists does
not, and that PR waits for you. When it can't tell, it says no.

## Changing the level

Edit `"level"` in `autonomy.json` and merge that PR yourself. The level is always read from `main`, so a PR
cannot raise its own level.

## What enforces what

- **GitHub (server side, cannot be bypassed):** the ruleset on `main` requires a PR, requires the `api` and `ios`
  checks from GitHub Actions, and blocks force pushes and deletion. Auto-merge only fires once those checks pass.
- **`scripts/request-merge.py` (local):** decides whether to request auto-merge at all, from the level on `main`,
  the changed paths, whether a spec change only adds, and the manual-gate boxes.
- **`.claude/settings.json` (local guard rail):** denies `gh pr merge`, `gh api`, `gh repo edit`, pushes to `main`,
  force pushes and deploys, so agents go through the script.

Agents act with your GitHub login, so GitHub sees their merges as yours: it cannot tell you and an agent apart.
The local layers are what separate the two. For a hard human gate, give agents their own GitHub account with write
access and set `required_approving_review_count` to 1 in `scripts/github/ruleset-main.json`.
