#!/usr/bin/env bash
# Deletes local branches whose pull request has merged, and the worktrees they are checked out in.
# PRs are squash-merged, so `git branch -d` cannot tell; GitHub deletes the remote branch on merge instead, so a
# branch whose upstream is "[gone]" after `git fetch --prune` is done with. Run by the post-merge hook after a
# `git pull` on main; run it by hand if the hook did not.
# Never touches: main, the branch checked out in the current worktree, branches without an upstream (never pushed),
# branches with a live upstream, dirty worktrees, or the remote. Always exits 0 (it must never fail a pull).

# A git hook runs with GIT_DIR (and friends) set; they would point `git -C <worktree>` at this checkout instead.
unset GIT_DIR GIT_WORK_TREE GIT_INDEX_FILE GIT_PREFIX

prune_main() {
  # No origin, nothing to learn from: stay silent (also keeps repos without a remote quiet).
  git remote get-url origin >/dev/null 2>&1 || return 0
  if ! GIT_TERMINAL_PROMPT=0 git fetch --quiet --prune origin >/dev/null 2>&1; then
    echo "prune-merged: could not reach origin, skipping"
    return 0
  fi
  git worktree prune

  local current branch upstream track path
  current="$(git symbolic-ref --quiet --short HEAD 2>/dev/null || true)"

  while IFS=$'\t' read -r branch upstream track; do
    [[ "$track" == "[gone]" && -n "$upstream" ]] || continue
    [[ "$branch" == "main" || "$branch" == "$current" ]] && continue
    prune_branch "$branch"
  done < <(git for-each-ref --format='%(refname:short)%09%(upstream)%09%(upstream:track)' refs/heads)

  git worktree prune
}

# Prints "<path>\t<locked 0|1>" of the linked worktree that has $1 checked out, if any.
# The first entry is the main checkout: it is never removed, so a branch there is skipped by the caller.
worktree_of() {
  git worktree list --porcelain | awk -v want="refs/heads/$1" '
    function flush() { if (branch == want) { print path "\t" locked "\t" first; found = 1 } }
    /^worktree / { if (seen) flush(); seen = 1; path = substr($0, 10); branch = ""; locked = 0; first = (n++ == 0) }
    /^branch / { branch = substr($0, 8) }
    /^locked/ { locked = 1 }
    END { if (seen) flush() }
  '
}

prune_branch() {
  local branch="$1" info path locked first
  info="$(worktree_of "$branch")"
  if [[ -n "$info" ]]; then
    IFS=$'\t' read -r path locked first <<<"$info"
    if [[ "$first" == "1" ]]; then
      echo "prune-merged: skipped $branch (checked out in the main checkout)"
      return 0
    fi
    if [[ -n "$(git -C "$path" status --porcelain 2>/dev/null)" ]]; then
      echo "prune-merged: skipped $branch (worktree $path has uncommitted changes)"
      return 0
    fi
    # Clean now; a locked worktree needs the flag twice.
    if [[ "$locked" == "1" ]]; then
      git worktree remove -f -f "$path" >/dev/null 2>&1
    else
      git worktree remove "$path" >/dev/null 2>&1
    fi || { echo "prune-merged: skipped $branch (could not remove worktree $path)"; return 0; }
    echo "prune-merged: removed worktree $path"
  fi
  if git branch -D "$branch" >/dev/null 2>&1; then
    echo "prune-merged: removed branch $branch"
  else
    echo "prune-merged: skipped $branch (could not delete it)"
  fi
}

prune_main
exit 0
