#!/usr/bin/env bash
# Tests .claude/hooks/stop-gate.py in a scratch repo with a stub verify.sh that logs each run:
# it runs once per distinct state of the changed packages and not again until the code changes.
set -uo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
hook="$here/../../.claude/hooks/stop-gate.py"

fails=0
ok() { echo "ok   $1"; }
bad() { echo "FAIL $1"; fails=$((fails + 1)); }

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
export VERIFY_LOG="$work/verify.log"
export VERIFY_EXIT=0
: >"$VERIFY_LOG"
git init -q -b main "$work/repo"
cd "$work/repo" || exit 1
git config user.email t@example.com
git config user.name t
mkdir -p scripts api ios docs
printf '#!/usr/bin/env bash\necho "$*" >> "$VERIFY_LOG"\nexit "${VERIFY_EXIT:-0}"\n' >scripts/verify.sh
echo a >api/a.ts
echo a >docs/d.md
git add -A && git commit -qm base
git update-ref refs/remotes/origin/main HEAD
git switch -q -c agent/x

session="stop-gate-test-$$"
rm -f "${TMPDIR:-/tmp}/running-plan-stop-gate-$session"*
run_hook() { printf '{"cwd":"%s","session_id":"%s"}' "$PWD" "$session" | python3 "$hook"; }
runs() { wc -l <"$VERIFY_LOG" | tr -d ' '; }
expect_runs() { # name, count
  if [[ "$(runs)" == "$2" ]]; then ok "$1"; else bad "$1: $(runs) runs, want $2"; fi
}

run_hook >/dev/null
expect_runs "nothing changed: no run" 0

echo b >>api/a.ts
run_hook >/dev/null
expect_runs "first edit runs verify" 1
[[ "$(tail -1 "$VERIFY_LOG")" == "api" ]] && ok "runs the touched package" || bad "runs the touched package"

run_hook >/dev/null
expect_runs "same state after a green run: skipped" 1

git add -A && git commit -qm "commit the same edit"
run_hook >/dev/null
expect_runs "committing the same content: skipped" 1

echo c >>api/a.ts
run_hook >/dev/null
expect_runs "another edit runs again" 2

echo new >api/new.ts
run_hook >/dev/null
expect_runs "a new untracked file runs again" 3

echo d >>docs/d.md
run_hook >/dev/null
expect_runs "a docs-only edit: skipped" 3

echo e >>api/a.ts
VERIFY_EXIT=1 run_hook >"$work/out" 2>&1
expect_runs "a failing run happened" 4
grep -q '"decision": "block"' "$work/out" && ok "failure blocks" || bad "failure blocks"
VERIFY_EXIT=1 run_hook >"$work/out" 2>&1
expect_runs "unchanged after a failure: runs again" 5

run_hook >/dev/null
expect_runs "green again after a fix: runs once" 6
run_hook >/dev/null
expect_runs "and is then skipped" 6

rm -f "${TMPDIR:-/tmp}/running-plan-stop-gate-$session"*
if [[ $fails -gt 0 ]]; then echo "stop-gate: $fails failed"; exit 1; fi
echo "stop-gate: all passed"
