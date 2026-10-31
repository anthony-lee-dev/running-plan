#!/usr/bin/env bash
# Tests scripts/prune-merged.sh and its post-merge hook in scratch repos: a bare repo is `origin`, no network.
# A branch is "merged" when its upstream is gone after a fetch --prune, which is what GitHub's delete-on-merge leaves.
set -uo pipefail
here="$(cd "$(dirname "$0")/.." && pwd)"
script="$here/prune-merged.sh"
hooks="$here/githooks"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@example.com GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@example.com
export GIT_TERMINAL_PROMPT=0

fails=0
pass() { echo "ok   $1"; }
fail() { echo "FAIL $1"; fails=$((fails + 1)); }
has_branch() { git -C "$tmp/repo" show-ref --verify --quiet "refs/heads/$1"; }
expect_branch() { if has_branch "$2"; then pass "$1"; else fail "$1: branch $2 is missing"; fi; }
expect_no_branch() { if has_branch "$2"; then fail "$1: branch $2 still exists"; else pass "$1"; fi; }
expect_dir() { if [[ -d "$2" ]]; then pass "$1"; else fail "$1: $2 is missing"; fi; }
expect_no_dir() { if [[ -d "$2" ]]; then fail "$1: $2 still exists"; else pass "$1"; fi; }

# origin.git (bare) and repo (a clone on main, tracking origin/main).
fresh() {
  rm -rf "$tmp/origin.git" "$tmp/repo" "$tmp/other" "$tmp/wt"
  mkdir -p "$tmp/wt"
  git init -q --bare -b main "$tmp/origin.git"
  git clone -q "$tmp/origin.git" "$tmp/repo" 2>/dev/null
  cd "$tmp/repo" || exit 1
  git switch -q -c main 2>/dev/null || true
  echo base >README.md
  git add -A && git commit -q -m base && git push -q -u origin main
}
# A pushed branch with an upstream and one commit.
pushed_branch() {
  git -C "$tmp/repo" switch -q -c "$1" main
  echo "$1" >"$tmp/repo/$1.txt"
  git -C "$tmp/repo" add -A && git -C "$tmp/repo" commit -q -m "$1"
  git -C "$tmp/repo" push -q -u origin "$1" 2>/dev/null
  git -C "$tmp/repo" switch -q main
}
# What GitHub does after a squash merge: the branch vanishes on origin; the local clone only learns on fetch.
merge_on_origin() { git -C "$tmp/origin.git" branch -q -D "$1"; }
run() { (cd "$tmp/repo" && bash "$script" 2>&1); }

[[ -f "$script" ]] || { echo "FAIL scripts/prune-merged.sh is missing"; exit 1; }

fresh
pushed_branch feat && merge_on_origin feat
out="$(run)"; rc=$?
expect_no_branch "gone branch is deleted" feat
[[ $rc -eq 0 ]] && pass "exits 0" || fail "exit code $rc"
[[ "$out" == *"feat"* ]] && pass "prints a line for the removal" || fail "no output line naming feat: $out"

fresh
pushed_branch live
run >/dev/null
expect_branch "branch with a live upstream is kept" live

fresh
git switch -q -c local-only && echo x >x.txt && git add -A && git commit -q -m x && git switch -q main
run >/dev/null
expect_branch "never-pushed branch is kept" local-only

fresh
git push -q origin main:other-default 2>/dev/null
git branch -q -u origin/other-default main
merge_on_origin other-default
git switch -q -c elsewhere
run >/dev/null
expect_branch "main is kept" main

fresh
pushed_branch feat && merge_on_origin feat
git switch -q feat
run >/dev/null
expect_branch "branch checked out in the current worktree is kept" feat

fresh
pushed_branch feat
git worktree add -q "$tmp/wt/feat" feat
merge_on_origin feat
out="$(run)"
expect_no_dir "gone branch with a clean worktree: worktree removed" "$tmp/wt/feat"
expect_no_branch "gone branch with a clean worktree: branch removed" feat

fresh
pushed_branch feat
git worktree add -q "$tmp/wt/feat" feat
echo dirty >"$tmp/wt/feat/untracked.txt"
merge_on_origin feat
out="$(run)"
expect_dir "dirty worktree is kept" "$tmp/wt/feat"
expect_branch "dirty worktree: branch is kept" feat
[[ "$out" == *"feat"* && "$out" == *"uncommitted"* ]] && pass "dirty worktree is reported" || fail "dirty worktree not reported: $out"

fresh
pushed_branch feat
git worktree add -q "$tmp/wt/feat" feat
git worktree lock "$tmp/wt/feat"
merge_on_origin feat
run >/dev/null
expect_no_dir "locked clean worktree: worktree removed" "$tmp/wt/feat"
expect_no_branch "locked clean worktree: branch removed" feat

fresh
pushed_branch feat
git worktree add -q "$tmp/wt/feat" feat
git worktree lock "$tmp/wt/feat"
echo dirty >>"$tmp/wt/feat/feat.txt"
merge_on_origin feat
run >/dev/null
expect_dir "locked dirty worktree is kept" "$tmp/wt/feat"
expect_branch "locked dirty worktree: branch is kept" feat

fresh
pushed_branch feat && merge_on_origin feat
git fetch -q --prune origin
git remote set-url origin "$tmp/does-not-exist.git"
out="$(run)"; rc=$?
[[ $rc -eq 0 ]] && pass "offline: exits 0" || fail "offline: exit code $rc"
expect_branch "offline: nothing is deleted" feat
[[ -n "$out" ]] && pass "offline: prints a note" || fail "offline: no note printed"

fresh
git remote remove origin
out="$(run)"; rc=$?
[[ $rc -eq 0 && -z "$out" ]] && pass "no origin remote: silent and exit 0" || fail "no origin: exit $rc, output '$out'"

# Hook: a pull that merges on main runs the script; one on another branch does not.
hook_setup() {
  fresh
  git config core.hooksPath "$hooks"
  pushed_branch feat && merge_on_origin feat
  git clone -q "$tmp/origin.git" "$tmp/other" 2>/dev/null
  (cd "$tmp/other" && echo more >>README.md && git commit -qam more && git push -q origin main)
}

hook_setup
out="$(cd "$tmp/repo" && git pull -q 2>&1)"; rc=$?
[[ $rc -eq 0 ]] && pass "hook: pull succeeds" || fail "hook: pull exit $rc: $out"
expect_no_branch "hook: pull on main prunes the gone branch" feat

hook_setup
git switch -q -c work && git push -q -u origin work 2>/dev/null
(cd "$tmp/other" && git fetch -q && git switch -q work 2>/dev/null && echo w >w.txt && git add -A && git commit -qm w && git push -q origin work)
(cd "$tmp/repo" && git pull -q >/dev/null 2>&1)
expect_branch "hook: pull on another branch leaves the gone branch" feat

# The hook's git environment (GIT_DIR) must not make a dirty worktree look clean.
fresh
git config core.hooksPath "$hooks"
pushed_branch feat
git worktree add -q "$tmp/wt/feat" feat
echo dirty >"$tmp/wt/feat/untracked.txt"
merge_on_origin feat
git clone -q "$tmp/origin.git" "$tmp/other" 2>/dev/null
(cd "$tmp/other" && echo more >>README.md && git commit -qam more && git push -q origin main)
(cd "$tmp/repo" && git pull -q >/dev/null 2>&1)
expect_dir "hook: dirty worktree survives a pull" "$tmp/wt/feat"
expect_branch "hook: dirty worktree's branch survives a pull" feat

[[ $fails -eq 0 ]]
