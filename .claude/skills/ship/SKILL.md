---
name: ship
description: Take the current branch from green tests to a reviewed pull request, fix review and CI feedback in a loop, request auto-merge if the autonomy level allows it, otherwise stop at an open PR for the human.
---

Run these steps in order. Never run `gh pr merge` yourself and never push to `main`.

1. **Branch.** If on `main`, create `agent/<short-task-name>` with `git switch -c`.
2. **Verify.** Run `bash scripts/verify.sh <packages you touched>`. Fix until it exits 0.
3. **Review.** Ask the `reviewer` subagent to review the branch. Fix every BLOCKER and SHOULD-FIX, then go back to step 2.
   Stop this loop after 3 rounds and list what is left in the PR body.
4. **Push and open the PR.** Check that every backlog item the PR closes is ticked in `docs/backlog.md` on this
   branch (`git diff origin/main -- docs/backlog.md`); tick it now if not. Commit, `git push -u origin <branch>`, then `gh pr create` with the repo's PR template filled in:
   - What changed and which `docs/backlog.md` item it closes.
   - The verify command you ran and its result.
   - Under `## Manual gates`: `None.`, or one unticked box per item needing a real device or the Apple account. Never tick them.
   - The reviewer's remaining NITs.
5. **Mark ready.** `gh pr ready`.
6. **Request merge.** Run `python3 scripts/request-merge.py <PR number>`. It reads `autonomy.json` on `main`:
   exit 0 means GitHub will merge by itself once the `api` and `ios` checks pass; exit 3 means the PR is left for the human.
   Either way, carry on to step 7. Never edit `autonomy.json` to change the outcome.
7. **Watch CI.** `gh pr checks --watch`. If a check fails, read its log (`gh run view --log-failed`), fix, push, repeat.
   Auto-merge, if requested, stays queued across pushes.
8. **Stop.** Post a one-line summary: PR link, checks status, and whether it is queued for auto-merge or waiting for the human.
