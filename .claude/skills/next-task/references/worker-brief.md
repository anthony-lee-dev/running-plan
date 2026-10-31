# Worker brief

The orchestrator copies the block below into the worker's prompt. It fills in each `<...>`, and writes `none`
where a placeholder doesn't apply. A worker starts with no memory of the orchestrator's conversation, so
everything it needs is in the brief or in the repo.

```text
You are building one pull request of the Running Planner backlog, in your own git worktree. You start fresh:
the repo and this brief are all you have.

Task: <id and the backlog line's text, word for word>
Branch: <agent/... name the orchestrator chose>
Done so far: <earlier PR links for this task and the list of what was left, or none>
From the human: <corrections or choices from the conversation that apply, or none>

## Set up
1. Your worktree starts on a branch of its own. Give it the name above and start it from the latest `main`:
   `git fetch origin main`, `git branch -m <Branch>`, then `git reset --hard origin/main`. The worktree is fresh, so
   nothing is lost.
2. Run `npm ci`. Its warning that install scripts were blocked (esbuild, fsevents, workerd) is expected, and the
   tests pass without them. If it asks you to approve anything, don't approve it. Stop and report what it asked.

## How to work
1. Read `CLAUDE.md`, the `CLAUDE.md` of each package you'll touch, and what the task points to:
   `spec/openapi.yaml`, the § sections of the system design, and the `designs/dark/DK-*` boards.
2. Plan one PR of about 400 changed lines or fewer, carrying on from "Done so far".
   - If the task is bigger, choose one coherent part (tests included) for now and leave its backlog line unticked.
   - If the task needs an endpoint added or changed, this PR is only that `spec/openapi.yaml` change (repo rule:
     contract first). The code using it comes in a later PR.
   - If the task is marked `ask first`, stop and report your plan instead of building.
3. Write failing tests first and run them to see them fail. Then write the code until they pass.
4. Tick the task in `docs/backlog.md` only if this PR finishes it.
5. If the human corrected something in "From the human", add the correction to the relevant `CLAUDE.md` in
   this PR.
6. Read `.claude/skills/ship/SKILL.md` and follow it step by step, including the CI watch. Start the reviewer
   with the Agent tool (`subagent_type: "reviewer"`); it reviews your branch from your worktree.
   - The repo's Stop hook doesn't run for you. You aren't done until `bash scripts/verify.sh <packages>`
     exits 0.
   - If `docs/backlog.md` conflicts with `main`, merge `origin/main` into your branch and push. Never rebase
     a pushed branch or force-push.
   - Never run `gh pr merge`, never edit `autonomy.json`, never tick a `## Manual gates` box, and never
     commit secrets.

## Report
Reply with only this, in at most 10 lines:
PR: <url, or "none: why" if you stopped before opening one>
CI: <passing | failing: which check | running>
Merge: <auto-merge queued | waiting for the human: why>
Task ticked: <yes | no>
Left: <what's left of the task for the next PR, or none>
Manual gates: <the boxes in the PR body, or none>
Notes: <anything the orchestrator must know, in one or two lines, or none>
```
