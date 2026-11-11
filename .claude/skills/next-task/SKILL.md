---
name: next-task
description: Work through the open GitHub issues (features and defects, grouped into slice milestones) by handing each pull request's worth of work to its own worker subagent in a git worktree (test-first, then /ship), while this session only picks tasks, waits for merges and reports. Use for "next task", "start slice N", "do 4.1", "keep going" or anything that continues the backlog.
---

# Next task

This session is the **orchestrator**. Workers build; you pick the work, start workers, wait for their PRs to merge
and report. A whole slice can take many PRs, and doing them all in one session fills its context. So keep yours
small: hold only the issue list, PR numbers and states, and each worker's short report. Don't read specs, design
boards or code yourself. Reading them is the worker's job, and its context is thrown away when it finishes.

## 1. Pick the task

First check that the main checkout is clean and on `main` (`git status --short --branch`). If it isn't, say what's
there and ask the human before starting any worker (see step 2 for why it matters).

The backlog is the repo's open GitHub issues. Slices are milestones (`Slice 5: ...`); each issue's title starts
with its stable task ID (`[2.6] ...`).

```bash
gh issue list --state open --limit 200 --json number,title,labels,milestone,body
```

An issue is **unblocked** when every `#n` on its body's `Blocked by:` line (if it has one) is closed, which is
the case when no such `#n` appears in the open-issue list above. Skip issues labelled `human-only` or `later`.

- Open `type: defect` issues come first (`priority: high` before `priority: normal`). A defect has no slice.
- Then pick the lowest-numbered unblocked feature in the earliest milestone that has open issues.
- Don't start a later slice until the current milestone has no open issues other than `[Device check]` ones and
  its **Done when** (the milestone's description) holds, apart from the device check. Open device checks don't
  hold the next slice back; they stop you calling the slice done (step 5). Judge that from the issues and the merged PRs' bodies (`gh pr view <n>`), not
  by reading code. Issues labelled `any-time` may be picked while the current slice waits on the human, or as the
  second worker (step 3).
- If the user named a task, use that one.
- If nothing is unblocked, say what is waiting on the human (a merge, a device check, a gate) and stop.
- For an `ask-first` issue, read what it points to, post the plan, and stop until the human answers. A worker can't
  wait for an answer. If the issue adds or reshapes a screen, the plan comes with its design, before any question:
  the review of how comparable apps do it and a mock, `designs/dark/DK-<name>.dc.html`, in the existing boards'
  tokens (`docs/design-notes.md`), on a branch with a PR the human can open. The questions come last and refer to
  the mock, so the human decides once. (On #131 the questions came first and two answers were reversed after the
  design review.) The merged mock is the worker's and the reviewer's reference.

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
were editing the main checkout, the hook would verify its half-done work and run the same iOS tests as the worker.

**One worker per backlog task.** The worker builds the whole task, end to end, in one PR of any size. Splitting a
task across workers would make each new worker learn the same code again. A contract change that only adds rides in
that PR as its first commit. The one exception is a change that removes or alters part of the existing contract
(`scripts/spec-additive.mjs` says so): then the worker's PR is only the `spec/openapi.yaml` change, and that PR waits
for the human. After it merges, start a worker for the rest of the task, with that PR's link and the worker's "Left"
list as the brief's "Done so far".

**Pass on what the human said.** Workers can't see this conversation. Put into the brief any correction or choice
the human made that the task needs. A correction also belongs in the relevant `CLAUDE.md` (repo rule), so ask the
worker to add it in its PR.

## 3. Two at a time, at most

Run workers one at a time by default. A second may run alongside the first only when all of these hold:

- the second task is in the current slice or labelled `any-time` (or is a defect), it is unblocked, and neither task needs
  the other or the other's PR;
- at most one of them touches `ios/` (label `area: ios`), because the iOS UI tests share the simulator, and a second iOS run slows both;
- they don't change the same files.

If the PR that merges second conflicts, step 4 spots this and sends it back to its worker, which merges
`origin/main` into its branch and pushes. A rebase would need a force-push, which is denied.

If the two are the last open issues of their milestone, each sees the other still open. Say in one brief's "From the
human" that its PR is the slice's last, so that PR lists the slice's device check.

## 4. Wait for the merge

When a worker reports, check its PR yourself:

```bash
gh pr view <n> --json state,mergedAt,autoMergeRequest,mergeable,mergeStateStatus,statusCheckRollup
```

Don't rely on the report alone. Also check that the worker left nothing running: its background commands outlive
it, and a wait loop whose run has ended waits for ever (the brief's "Commands that work in a worktree" says why).
List the app's background tasks for this session, or search the processes for ones naming that worker's worktree,
this session's folder (the directory of the Agent result's `output_file`, which holds `tasks/` and `scratchpad/`)
or its PR:

```bash
ps -ax -o pid,etime,command | grep -E "until |sleep [0-9]" | grep -E "<worktree path>|<session folder>|pr checks <n>"
```

Stop only that worker's loops (`kill <pid>`), and only once what they wait on has ended. Leave a running
`verify.sh` alone, since it may be the Stop hook's, and leave other sessions' processes alone. Then:

- **Merged:** check the issue closed (`gh issue view <n> --json state`; a `Refs` PR leaves it open on purpose),
  clean up (step 6) and go back to step 1.
- **Checks running, auto-merge queued:** run `gh pr checks <n> --watch` in the background and check again when it
  ends. GitHub merges within a minute or so of the checks passing.
- **A check failed, or `mergeable` is `CONFLICTING`:** send the failure or conflict to the same worker with
  SendMessage. It already has the context to fix it. It removed its worktree when it reported, so first re-create
  it at the same path (`git worktree add <path> <named branch>`) and say so in the message. If the worker can't be
  reached, remove any worktree it left but keep the branch (`git worktree unlock <path>`, then
  `git worktree remove <path>`), then start a new worker. Fill the brief's "Existing PR" field so the new worker
  carries on that branch instead of starting a fresh one. Either way the branch can't be checked out in the main
  checkout at the same time: if the human is verifying it there, ask them to switch away first.
- **Left for the human** (`request-merge.py` exited 3, or the PR has manual-gate boxes): stop (step 5). A
  `[Device check]` issue is not a reason to wait: the PR merges without it.

Never start a worker whose task needs an unmerged PR. Workers branch from `origin/main`, so they only see work
that has merged. A branch stacked on an unmerged one needs a rebase after the squash merge, and that rebase needs
a force-push, which is denied.

## 5. Stop at a human gate

Stop when the next step needs the human: a PR to merge, a manual-gate box, an `ask-first` plan, or nothing left
unblocked. Say plainly what is waiting and on whom, with PR links, and which issues the merged PRs closed.

Every time you stop, list the open device checks in one block, oldest first, so the human can do them in one
sitting (`gh issue list --state open --search "[Device check] in:title"`). Never call a slice done while one of
its device checks is open, and never close one yourself unless the human says they did it.

**Device checks never hold a PR.** A worker's `/ship` opens a `[Device check]` issue with the steps and the PR merges
on green CI (iOS CI is the full suite; workers only run the quick mode locally). The check needs the merged API to
be deployed, so when a merged PR touched `api/` and has a device check, do 5a before you list the check as ready.

## 5a. Deploy the API (only with the human's yes)

A merge doesn't deploy: the Worker and its D1 database only change when someone runs the migrations and
`wrangler deploy`. A device check against the deployed API then fails with 404s on routes that merged. So before you
list a device check as ready, or whenever merged PRs touched `api/` or `api/migrations/`, find out whether production
is behind. Neither command below changes production data (the smoke test only moves rate-limit counters). Run them
from `api/` on an up-to-date `main`; `wrangler.toml` lives there:

```bash
npm run smoke -w api
npx wrangler d1 migrations list running-plan --remote
```

If the smoke test fails on built operations, or migrations are pending, say so and ask the human in chat for **two
separate permissions**, naming what each will do:

1. `npx wrangler d1 migrations apply running-plan --remote` (list the pending names);
2. `npx wrangler deploy`.

Run a command only after the human says yes to that one; a yes to one doesn't cover the other, or a later deploy.
Run them in that order (migrations first: the new code reads the new columns), then run `npm run smoke -w api` at
once without asking again, and report what it says. Stop at the first failure.

`.claude/settings.json` denies `npx wrangler deploy *` and `npm run deploy *`, and a deny beats an allow, so a yes in
chat doesn't unblock the deploy: the human has to relax that rule, or run it themselves (give them the commands).
Migrations are allowed by the `npx wrangler *` rule, so the human's yes is the only gate on them; the permission
check may still block one, and then the human adds a rule. Never find another way to run a blocked command. Only the
`running-plan` database and this repo's Worker; secrets stay the human's (`wrangler secret put`).

## 6. Clean up worktrees

A worker removes its own worktree as soon as its PR is pushed and open (the brief's step 7), so the human can
check the branch out in the main checkout to verify it. Its report's "Worktree" line says whether it did. If it
says "kept", or a worktree for that branch still shows in `git worktree list`, remove it yourself right away,
without waiting for the merge (`git worktree unlock <path>` first if it is locked):

```bash
git worktree remove <path>
```

Once `gh pr view` shows the PR merged, delete both branches: the one you named in the brief, and the worktree's
original one, which the worker switched away from (the report's "Worktree" line, or the Agent result, names it).

```bash
git branch -D <named branch> <worktree's original branch>
```

The allow list covers `git branch -D agent/*` only, so deleting the worktree's original branch asks the human
first.

A `git pull` on main also runs `scripts/prune-merged.sh` (post-merge hook), which removes clean worktrees and local
branches whose remote branch is gone. It never deletes the worktree's original branch (never pushed), so that
`git branch -D` stays; run the script by hand if the hook did not.

If the human has the branch checked out in the main checkout, `git branch -D` refuses it: leave it, and say so.

## If workers aren't available

If the Agent tool is missing, or the human asks for the work to happen in this session, follow
[references/worker-brief.md](references/worker-brief.md) yourself, from "How to work", in a branch of the main
checkout.
