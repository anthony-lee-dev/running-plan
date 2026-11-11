---
name: ship
description: Take the current branch from green tests to a reviewed pull request, fix review and CI feedback in a loop, request auto-merge if the autonomy level allows it, otherwise stop at an open PR for the human.
---

Run these steps in order. Never run `gh pr merge` yourself and never push to `main`.

1. **Branch.** If on `main`, create `agent/<short-task-name>` with `git switch -c`.
2. **Verify.** Run `bash scripts/verify.sh <packages you touched>`. Fix until it exits 0. For `ios`, a worker runs
   the quick mode, `IOS_TEST_SCOPE=quick IOS_UI_TESTS="<UI test classes for the screens you touched>" bash scripts/verify.sh ios`
   (unit tests plus those classes); CI runs the full suite and the PR doesn't merge until its `ios` check passes.
   Other packages always run in full.
3. **Review.** Ask the `reviewer` subagent to review the branch. Fix every BLOCKER and SHOULD-FIX, then go back to step 2.
   For the second and third rounds, don't start a new reviewer, which would read everything again: send the same one
   a message (SendMessage) naming the commit it reviewed and asking it to check only your fixes. If you can't reach
   it, start a new one, paste the earlier findings into its prompt and ask for the same narrow check.
   Stop this loop after 3 rounds and list what is left in the PR body.
4. **Push and open the PR.** Find the issue this branch does (`gh issue list --search "<task id>"`, or the number
   you were given). Commit, `git push -u origin <branch>`, then `gh pr create` with the repo's PR template filled in:
   - What changed, and `Closes #<n>` for the issue (`Refs #<n>` for a PR that leaves the task open).
     Work with no issue (tooling, say) says so instead.
   - `## Contract`: `None.`, or what the spec change adds. A spec change must be the branch's first commit and only add
     (`node scripts/spec-additive.mjs <the spec on origin/main, saved to a file> spec/openapi.yaml` exits 0). If it
     doesn't, stop: that change is a spec PR of its own for the human.
   - The verify command you ran and its result.
   - `## Manual gates`: `None.`, or one unticked box per thing that must happen before the merge (the Apple account).
     Never tick them. A device check does not go here.
   - The reviewer's remaining NITs.
5. **Device check, as an issue.** If the work needs the human on a device (the issue says so, it changes a screen or
   Health or watch behaviour, or it closes a slice), open an issue and put `- #<issue>: <one line>` under
   `## Device check` in the PR body:
   `gh issue create --title "[Device check] <PR title>" --label human-only --milestone "<the issue's milestone>" --body "<PR link, then the steps to follow on the device, then what the API needs deployed>"`.
   Leave `--milestone` out when the issue has none. The check does not hold the PR open: it merges on green CI, and
   the human does the check when they next pick up the device. What they find becomes a defect issue.
6. **Mark ready.** `gh pr ready`.
7. **Request merge.** Run `python3 scripts/request-merge.py <PR number>`. It reads `autonomy.json` on `main`:
   exit 0 means GitHub will merge by itself once the `api` and `ios` checks pass; exit 3 means the PR is left for the
   human, and it prints why (a spec change that is not additive, a path the level does not cover, a manual gate).
   Either way, carry on to step 8. Never edit `autonomy.json` to change the outcome.
8. **Watch CI.** `gh pr checks --watch`. If a check fails, read its log (`gh run view --log-failed`), fix, push, repeat.
   Auto-merge, if requested, stays queued across pushes.
9. **Stop.** Post a one-line summary: PR link, checks status, whether it is queued for auto-merge or waiting for the
   human, and the device-check issue if there is one.
