# Worker brief

The orchestrator copies the block below into the worker's prompt. It fills in each `<...>`, and writes `none`
where a placeholder doesn't apply. A worker starts with no memory of the orchestrator's conversation, so
everything it needs is in the brief or in the repo.

```text
You are building one Running Planner GitHub issue (a feature, or a defect), end to end, as one pull request in your own git worktree. You
start fresh: the repo and this brief are all you have.

Issue: <#number, its title and its body (`gh issue view <n>`), word for word>
Branch: <agent/... name the orchestrator chose>
Done so far: <a merged contract PR for this task and what was left, or none>
Existing PR: <none, or "#n: fix <the failing check or conflict>" when you carry on an open PR on Branch>
From the human: <corrections or choices from the conversation that apply, or none>

## Set up
1. Run `git fetch origin main`. Then:
   - With no existing PR, run `git switch -c <Branch> origin/main`.
   - With an existing PR, run `git switch <Branch>`. After step 2, go straight to "How to work" step 6 and fix
     what "Existing PR" names, then remove your worktree (step 7). If git says Branch is already checked out
     elsewhere (the human may be verifying it in the main checkout), stop and report that.
2. Run `npm ci`. Its warning that install scripts were blocked (esbuild, fsevents, workerd) is expected, and the
   tests pass without them. If it asks you to approve anything, don't approve it. Stop and report what it asked.

## How to work
1. Read `CLAUDE.md` and the `CLAUDE.md` of each package you'll touch. Each package guide ends its opening with an
   index of feature notes (`api/docs/`, `ios/docs/`): read only the notes for the folders you'll change, and the
   notes of the screens that use any shared code you change. Then read what the task points to: the § sections of
   the system design and the `designs/dark/DK-*` boards. Don't read `spec/openapi.yaml` from top to bottom (it is
   about 25,000 tokens): search it for the operations and schemas you need and read those parts.
2. Plan the whole task as one PR, carrying on from "Done so far". There is no size limit: finish the task here
   rather than leaving parts for another worker, who would have to learn the code again.
   - If the task needs an endpoint added or changed (repo rule: contract first), change `spec/openapi.yaml` before
     any code, as the branch's first commit, then check it: `git show origin/main:spec/openapi.yaml` saved to a file
     in your scratch folder, then `node scripts/spec-additive.mjs <that file> spec/openapi.yaml`. Exit 0 (it only
     adds): carry on and build the whole task in this PR. Exit 1 (it removes or alters something existing): this PR
     is only that spec change, for the human to merge. Use `Refs #<n>` in its body, not `Closes`, and list the rest
     under "Left". Never reshape a change to get past the check, and never stack a branch on an unmerged one.
   - If the issue is labelled `ask-first`, stop and report your plan instead of building.
   - If the issue is a defect (`type: defect`), first write a regression test that reproduces it and watch it
     fail; the fix makes it pass.
   - Call the advisor tool once your plan is written, before you write code, and again before you start
     `/ship`. Call it too when the same error comes back twice.
3. Write failing tests first and run them to see them fail. Then write the code until they pass.
4. Put `Closes #<n>` in the PR body so the issue closes on merge (`Refs #<n>` for a contract-only PR). When the
   task taught you something the next worker on this feature needs, add it to that feature's note (`api/docs/`,
   `ios/docs/`), not to the package `CLAUDE.md`. Don't
   edit `docs/backlog.md`: it only archives the tasks finished before the move to issues.
5. If the human corrected something in "From the human", add the correction to the relevant `CLAUDE.md` in
   this PR.
6. Read `.claude/skills/ship/SKILL.md` and follow it step by step, including the CI watch. Start the reviewer
   with the Agent tool (`subagent_type: "reviewer"`). Put your worktree's absolute path (`pwd`) in its prompt, and
   tell it to run git as `git -C <path>` and to read files by absolute path. Otherwise it may review the main
   checkout, where your branch isn't checked out, and find an empty diff.
   - The repo's Stop hook doesn't run for you. You aren't done until `bash scripts/verify.sh <packages>`
     exits 0, with one difference for iOS: run it as
     `IOS_TEST_SCOPE=quick IOS_UI_TESTS="<classes>" bash scripts/verify.sh ios`. That checks the api client against
     the spec, builds, runs all the unit tests and only the UI test classes you name, for the screens you changed or
     added (`IOS_UI_TESTS="GoalUITests InboxUITests"`; names are `ios/RunningPlanUITests` classes, space or comma
     separated, `Class/testMethod` also works). It takes minutes, not the 16-18 of the full suite. Don't run the
     full `bash scripts/verify.sh ios` yourself: iOS CI runs the whole suite on the PR, and the PR doesn't merge
     until the required `ios` check passes. Every other package (`api`, `spec`, `web`) still runs its full
     `bash scripts/verify.sh <package>` locally. If a change touches shared iOS code (networking, navigation, app
     state), name more UI classes rather than fewer.
   - Other workers run iOS tests at the same time, and two runs on one simulator make each other fail at random
     (snapshot tests especially). Without `IOS_SIM_DEST`, `verify.sh` locks the simulator it uses and takes a clone
     (`RunningPlan verify <n>`) when another run holds it. If you set `IOS_SIM_DEST` yourself, pick a simulator
     nobody else is using. If a test fails that your change can't explain, rerun once before debugging.
   - If your branch conflicts with `main`, run `git merge origin/main`, fix the conflict, commit, then run
     `git push origin <Branch>`. A bare `git push` is denied. Never rebase a pushed branch or force-push.
   - Never run `gh pr merge`, never edit `autonomy.json`, never tick a `## Manual gates` box, and never
     commit secrets.
   - If this PR closes the last open feature issue in its milestone (or "From the human" says it is the slice's
     last), add the slice's journey UI test (the slice's flow across its screens, as the human walks it on the
     device) and have `/ship` step 5 open the slice's `[Device check]` issue for that flow against the deployed API
     (`docs/backlog.md`: "End-to-end check for every slice", item 3). The milestone's description has its **Done when**.
   - **Device check: an issue, not a wait.** If the work needs the human on a device, `/ship` step 5 opens a
     `[Device check]` issue with the steps and lists it in the PR. The PR merges on green CI without it; don't wait
     for the human and don't ask them to hurry. Put the issue number in your report.
7. Remove your worktree once `/ship` is finished: the PR is open and ready for review, and `git status` shows
   nothing to commit and says the branch is up to date with `origin/<Branch>`. The human checks branches out in the
   main checkout to verify them, and git refuses to check out a branch that a worktree still holds.
   - Note your worktree's path (`pwd`) and its original branch: in `git reflog`, the line
     `checkout: moving from <original branch> to <Branch>`.
   - From inside the worktree, run `git worktree unlock <worktree path>`, then `git worktree remove <worktree path>`.
     The unlock may say it isn't locked; that's fine. Never add `--force`: if git refuses because something is
     uncommitted, commit and push it first.
   - This must be your last command: your shell's folder is gone afterwards. Send the report next.
   - If a command is refused, leave the worktree and give the reason under "Worktree" in the report; the
     orchestrator removes it.
   - If the orchestrator later asks you to fix something on the PR, it re-creates the worktree at the same path
     first. `cd <worktree path>`, run `npm ci`, fix and push, then remove the worktree again as above.

## Commands that work in a worktree
In a worktree, a guard refuses any command it can't prove stays inside the worktree. These keep you clear of it,
and of the other blocks:
- Change files with the Edit and Write tools, not Python or `sed` scripts that rewrite them.
- Keep shell commands plain: spell file paths out, and don't hold them in shell variables.
- To wait on a long command (`bash scripts/verify.sh ios`, `gh pr checks <n> --watch`), start it once with the
  Bash tool's `run_in_background: true`, then do other work or end your turn: its completion notice wakes you
  when it ends, whether it passed, failed or was stopped, so there is nothing to poll. Send its output to a log
  if you want to read more than the notice shows.
- Write no wait loops and no timers, whether in Bash or in a Monitor: no `until` or `while` loops, no `sleep`.
  This overrides the Bash tool's own advice to wait with a Monitor until-loop. A loop keeps running after you
  move on: earlier workers left dozens running for hours, waiting on logs whose run had been stopped and on a
  `grep` pattern macOS doesn't support.
- A foreground command still running after about 3 minutes is moved to the background and keeps running. Treat
  that like any background command: wait for its notice, and never start the same command or wait again.
- If you stop a run of yours (TaskStop), stop anything of yours that waits on it in the same step.
- Never `pkill` or `kill` a process you didn't start: it may be another worker's tests or the Stop hook's
  `verify.sh`. Never wait with `pgrep -f "<command text>"` either: it also matches those runs.
- `verify.sh ios` stops a hung `xcodebuild` itself (after `IOS_TEST_TIMEOUT` seconds, default 45 minutes) and
  says so. Rerun it once; if it hangs again, stop and report it under Notes rather than trying a third time.
- Don't call the app's task-list or wrap-up tools (`mcp__ccd_turn__update_plan`, `mcp__ccd_turn__wrap_up`).
  Only the main session shows them.

## Report
Reply with only this, in at most 11 lines:
PR: <url, or "none: why" if you stopped before opening one>
CI: <passing | failing: which check | running>
Merge: <auto-merge queued | waiting for the human: why>
Issue closes on merge: <yes | no (Refs only)>
Left: <after a contract-only PR, the rest of the task; otherwise none>
Manual gates: <the boxes in the PR body, or none>
Device check: <#issue, or none>
Worktree: <removed (original branch <name>) | kept: why>
Notes: <anything the orchestrator must know, in one or two lines, or none>
```
