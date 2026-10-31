#!/usr/bin/env bash
# Tests the hooks in scripts/githooks/ end to end: a scratch repo with core.hooksPath pointing at them and a stub
# xcodegen on PATH that records each run. Checks which git commands regenerate the Xcode project, and how often.
set -uo pipefail
hooks="$(cd "$(dirname "$0")/../githooks" && pwd)"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

mkdir -p "$tmp/bin"
cat >"$tmp/bin/xcodegen" <<'EOF'
#!/usr/bin/env bash
echo run >>"$XCODEGEN_LOG"
exit "${XCODEGEN_EXIT:-0}"
EOF
chmod +x "$tmp/bin/xcodegen"
export XCODEGEN_LOG="$tmp/xcodegen.log"
export PATH="$tmp/bin:$PATH"
export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@example.com GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@example.com

fails=0
runs() { if [[ -f "$XCODEGEN_LOG" ]]; then wc -l <"$XCODEGEN_LOG" | tr -d ' '; else echo 0; fi; }
check() { # name, expected runs
  local got; got="$(runs)"
  if [[ "$got" == "$2" ]]; then echo "ok   $1"; else echo "FAIL $1: xcodegen ran $got times, want $2"; fails=$((fails + 1)); fi
}

# A fresh repo per case: main has one app file; the project folder exists (gitignored) unless told otherwise.
fresh() {
  rm -rf "$tmp/repo" "$XCODEGEN_LOG"
  git init -q -b main "$tmp/repo"
  cd "$tmp/repo" || exit 1
  git config core.hooksPath "$hooks"
  mkdir -p ios/RunningPlan
  echo "ios/RunningPlan.xcodeproj/" >.gitignore
  echo "name: RunningPlan" >ios/project.yml
  echo "// a" >ios/RunningPlan/A.swift
  echo "readme" >README.md
  git add -A && git commit -q -m base
  [[ "${1:-}" == "no-project" ]] || mkdir -p ios/RunningPlan.xcodeproj
}
add_file() { echo "// $2" >"ios/RunningPlan/$2" && git add -A && git commit -q -m "$1"; }

fresh
git switch -q -c feature && add_file feature B.swift && rm -f "$XCODEGEN_LOG"
git switch -q main
check "branch switch that removes an app file" 1

fresh
git switch -q -c feature && echo "// edited" >ios/RunningPlan/A.swift && git commit -qam edit && git switch -q main
check "branch switch with only edits" 0

fresh no-project
git switch -q -c feature && add_file feature B.swift && git switch -q main
check "no generated project, nothing to refresh" 0

fresh
git switch -q -c feature && add_file feature B.swift && git switch -q main && rm -f "$XCODEGEN_LOG"
git merge -q --ff-only feature
check "fast-forward merge that adds an app file" 1

fresh
git switch -q -c feature && add_file feature B.swift && git switch -q main && echo "local" >>README.md && git commit -qam local
rm -f "$XCODEGEN_LOG"
git merge -q --no-edit feature
check "merge commit without conflicts runs once" 1

fresh
git switch -q -c feature && add_file feature B.swift && echo "theirs" >README.md && git commit -qam readme
git switch -q main && echo "ours" >README.md && git commit -qam readme && rm -f "$XCODEGEN_LOG"
git merge -q feature >/dev/null 2>&1
echo "merged" >README.md && git add README.md && git commit -q --no-edit
check "conflicted merge, then commit" 1

fresh
git switch -q -c feature && add_file feature B.swift && git switch -q main && echo "local" >>README.md && git commit -qam local
rm -f "$XCODEGEN_LOG"
git rebase -q feature >/dev/null 2>&1
check "rebase onto a branch that adds an app file runs once" 1

fresh
git switch -q -c feature && add_file feature B.swift && echo "theirs" >README.md && git commit -qam readme
git switch -q main && echo "ours" >README.md && git commit -qam readme && rm -f "$XCODEGEN_LOG"
git rebase -q feature >/dev/null 2>&1
git rebase --abort
check "aborted rebase leaves the project alone" 0

fresh
add_file second B.swift && rm -f "$XCODEGEN_LOG"
echo "// amended" >ios/RunningPlan/B.swift && git commit -q -a --amend --no-edit
check "commit --amend" 0

fresh
git switch -q -c feature && add_file feature B.swift && rm -f "$XCODEGEN_LOG"
if XCODEGEN_EXIT=1 git switch -q main 2>/dev/null; then echo "ok   failing xcodegen never fails git"
else echo "FAIL failing xcodegen failed the git switch"; fails=$((fails + 1)); fi

fresh
git switch -q -c feature && add_file feature B.swift
out="$(PATH="/usr/bin:/bin" git switch -q main 2>&1)"
rc=$?
if [[ $rc -eq 0 && "$out" == *"xcodegen generate"* ]]; then echo "ok   missing xcodegen says what to run"
else echo "FAIL missing xcodegen: exit $rc, output '$out'"; fails=$((fails + 1)); fi

[[ $fails -eq 0 ]]
