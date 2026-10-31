# Running Planner

Monorepo for the Running Planner iOS app, its API and (later) the web companion. Agents work here with
Claude Code on the Mac; start with `CLAUDE.md`. The task list is the repo's GitHub issues (a milestone per slice).

## Prerequisites (Mac)

- Node 22 or later and npm
- Xcode with an iPhone simulator, and `brew install xcodegen`
- GitHub CLI: `brew install gh`, then `gh auth login`
- Claude Code

## First run

```bash
npm install
bash scripts/verify.sh all
```

## Daily loop

```bash
claude                            # one session works through the open issues
# inside Claude:  /next-task        picks tasks and hands each PR to a worker subagent in its own worktree
```

`/ship` stops at a reviewed, green PR. You merge.
