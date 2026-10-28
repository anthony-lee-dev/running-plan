# Running Planner

Monorepo for the Running Planner iOS app, its API and (later) the web companion. Agents work here with
Claude Code on the Mac; start with `CLAUDE.md` and `docs/backlog.md`.

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
claude --worktree <task-name>     # one isolated session per task
# inside Claude:  /next-task        picks, builds and ships the next backlog item
```

`/ship` stops at a reviewed, green PR. You merge.
