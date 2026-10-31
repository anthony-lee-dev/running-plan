# Worker brief

The orchestrator copies the block below into the worker's prompt. It fills in each `<...>`, and writes `none`
where a placeholder doesn't apply. A worker starts with no memory of the orchestrator's conversation, so
everything it needs is in the brief or in the repo.

```text
You are building one Running Planner backlog task, end to end, as one pull request in your own git worktree. You
start fresh: the repo and this brief are all you have.

Task: <id and the backlog line's text, word for word>
Branch: <agent/... name the orchestrator chose>
Done so far: <the merged contract PR for this task and what was left, or none>
Existing PR: <none, or "#n: fix <the failing check or conflict>" when you carry on an open PR on Branch>
From the human: <corrections or choices from the conversation that apply, or none>

## Set up
1. Run `git fetch origin main`. Then:
   - With no existing PR, run `git switch -c <Branch> origin/main`.
   - With an existing PR, run `git switch <Branch>`. After step 2, go straight to "How to work" step 6 and fix
     what "Existing PR" names.
2. Run `npm ci`. Its warning that install scripts were blocked (esbuild, fsevents, workerd) is expected, and the
   tests pass without them. If it asks you to approve anything, don't approve it. Stop and report what it asked.

## How to work
1. Read `CLAUDE.md`, the `CLAUDE.md` of each package you'll touch, and what the task points to:
   `spec/openapi.yaml`, the § sections of the system design, and the `designs/dark/DK-*` boards.
2. Plan the whole task as one PR, carrying on from "Done so far". There is no size limit: finish the task here
   rather than leaving parts for another worker, who would have to learn the code again.
   - If the task needs an endpoint added or changed and "Done so far" has no contract PR, this PR is only that
     `spec/openapi.yaml` change (repo rule: contract first). Leave the task unticked and list the rest under
     "Left".
   - If the task is marked `ask first`, stop and report your plan instead of building.
3. Write failing tests first and run them to see them fail. Then write the code until they pass.
4. Tick the task in `docs/backlog.md` in this PR, unless it is only the contract change.
5. If the human corrected something in "From the human", add the correction to the relevant `CLAUDE.md` in
   this PR.
6. Read `.claude/skills/ship/SKILL.md` and follow it step by step, including the CI watch. Start the reviewer
   with the Agent tool (`subagent_type: "reviewer"`). Put your worktree's absolute path (`pwd`) in its prompt, and
   tell it to run git as `git -C <path>` and to read files by absolute path. Otherwise it may review the main
   checkout, where your branch isn't checked out, and find an empty diff.
   - The repo's Stop hook doesn't run for you. You aren't done until `bash scripts/verify.sh <packages>`
     exits 0.
   - If your branch conflicts with `main`, run `git merge origin/main`, fix the conflict, commit, then run
     `git push origin <Branch>`. A bare `git push` is denied. Never rebase a pushed branch or force-push.
   - Never run `gh pr merge`, never edit `autonomy.json`, never tick a `## Manual gates` box, and never
     commit secrets.

## Report
Reply with only this, in at most 10 lines:
PR: <url, or "none: why" if you stopped before opening one>
CI: <passing | failing: which check | running>
Merge: <auto-merge queued | waiting for the human: why>
Task ticked: <yes | no>
Left: <after a contract-only PR, the rest of the task; otherwise none>
Manual gates: <the boxes in the PR body, or none>
Notes: <anything the orchestrator must know, in one or two lines, or none>
```
