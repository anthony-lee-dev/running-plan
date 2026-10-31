---
name: next-task
description: Work through docs/backlog.md by handing each pull request's worth of work to its own worker subagent in a git worktree (test-first, then /ship), while this session only picks tasks, waits for merges and reports. Use for "next task", "start slice N", "do 4.1", "keep going" or anything that continues the backlog.
---

# Next task

This session is the **orchestrator**. Workers build; you pick the work, start workers, wait for their PRs to merge
and report. A whole slice can take many PRs, and doing them all in one session fills its context. So keep yours
small: hold only the backlog, PR numbers and states, and each worker's short report. Don't read specs, design
boards or code yourself. Reading them is the worker's job, and its context is thrown away when it finishes.

## 1. Pick the task

First check that the main checkout is clean and on `main` (`git status --short --branch`). If it isn't, say what's
there and ask the human before starting any worker (see step 2 for why it matters).

Read the backlog as it is on `main`, not as it is in this checkout: `git fetch origin main`, then
`git show origin/main:docs/backlog.md`.

- Pick the first unticked task in the first unfinished slice whose `needs` are ticked.
- Don't start a later slice until the current one's tasks are ticked and its **Done when** holds. Judge that from
  the backlog and the merged PRs' bodies (`gh pr view <n>`), not by reading code. Tasks marked `any time` may be
  picked while the current slice waits on the human, or as the second worker (step 3).
- If the user named a task, use that one.
- If nothing is unblocked, say what is waiting on the human (a merge, a device check, a gate) and stop.
- For an `ask first` task, read what it points to, post the plan, and stop until the human answers. A worker can't
  wait for an answer.

## 2. Start a worker

Say in one line which task you're starting. Then call the Agent tool with:

- `subagent_type: "general-purpose"` and `isolation: "worktree"`;
- the brief in [references/worker-brief.md](references/worker-brief.md), with its placeholders filled in;
- `model: "sonnet"` and `effort: "medium"`. The worker has the advisor tool for the hard calls, and the brief
  tells it when to use it. Leave both out (the worker then runs on this session's model) only for a screen
  task that has to match a DK board closely; say in your one line why.

Name the branch in the brief: `agent/<task id>-<few words>`. For the code PR after a contract PR (below), add
`-2`, so the two names differ.

Every worker gets its own worktree, even when only one runs. The main checkout has to stay clean on `main`:
whenever this session ends a turn, the repo's Stop hook runs `verify.sh` on whatever is checked out. If a worker
were editing the main checkout, the hook would verify its half-done work and fight it for port 8790.

**One worker per backlog task.** The worker builds the whole task, end to end, in one PR of any size. Splitting a
task across workers would make each new worker learn the same code again. The one exception is the repo's
contract-first rule: if the task changes an endpoint, the worker's PR is only the `spec/openapi.yaml` change, and
that PR waits for the human. After it merges, start a worker for the rest of the task, with that PR's link and the
worker's "Left" list as the brief's "Done so far".

**Pass on what the human said.** Workers can't see this conversation. Put into the brief any correction or choice
the human made that the task needs. A correction also belongs in the relevant `CLAUDE.md` (repo rule), so ask the
worker to add it in its PR.

## 3. Two at a time, at most

Run workers one at a time by default. A second may run alongside the first only when all of these hold:

- the second task is in the current slice or marked `any time`, its `needs` are ticked, and neither task needs
  the other or the other's PR;
- at most one of them touches `ios/`, because the iOS UI tests need port 8790 and the simulator;
- they don't change the same files, apart from their own lines in `docs/backlog.md`.

The PR that merges second may conflict on `docs/backlog.md`. Step 4 spots this and sends it back to its worker,
which merges `origin/main` into its branch and pushes. A rebase would need a force-push, which is denied.

If the two are the last tasks of their slice, each sees the other still unticked. Say in one brief's "From the
human" that its PR is the slice's last, so that PR lists the slice's device check.

## 4. Wait for the merge

When a worker reports, check its PR yourself:

```bash
gh pr view <n> --json state,mergedAt,autoMergeRequest,mergeable,mergeStateStatus,statusCheckRollup
```

Don't rely on the report alone. Then:

- **Merged:** clean up (step 6) and go back to step 1.
- **Checks running, auto-merge queued:** run `gh pr checks <n> --watch` in the background and check again when it
  ends. GitHub merges within a minute or so of the checks passing.
- **A check failed, or `mergeable` is `CONFLICTING`:** send the failure or conflict to the same worker with
  SendMessage. It already has the context to fix it. If it can't be reached, remove its worktree but keep the
  branch (`git worktree remove <path>`), then start a new worker. Fill the brief's "Existing PR" field so the new
  worker carries on that branch instead of starting a fresh one.
- **Left for the human** (`request-merge.py` exited 3, or the PR has manual-gate boxes): stop (step 5).

Never start a worker whose task needs an unmerged PR. Workers branch from `origin/main`, so they only see work
that has merged. A branch stacked on an unmerged one needs a rebase after the squash merge, and that rebase needs
a force-push, which is denied.

## 5. Stop at a human gate

Stop when the next step needs the human: a PR to merge, a manual-gate box, the slice's **Done when** device check,
an `ask first` plan, or nothing left unblocked. Say plainly what is waiting and on whom, with PR links, and
which backlog tasks the merged PRs ticked.

## 6. Clean up worktrees

A worker that committed keeps its worktree under `.claude/worktrees/`; the Agent result gives the path and the
branch the worktree was created on. Once `gh pr view` shows the PR merged, remove the worktree. Then delete both
branches: the one you named in the brief, and the worktree's original one, which the worker switched away from.

```bash
git worktree remove <path>
git branch -D <named branch> <worktree's original branch>
```

The allow list covers `git branch -D agent/*` only, so deleting the worktree's original branch asks the human
first.

Leave the worktree of an open PR in place: its worker may still be asked to fix something.

## If workers aren't available

If the Agent tool is missing, or the human asks for the work to happen in this session, follow
[references/worker-brief.md](references/worker-brief.md) yourself, from "How to work", in a branch of the main
checkout.
