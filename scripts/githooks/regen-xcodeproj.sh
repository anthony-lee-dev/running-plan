#!/usr/bin/env bash
# Regenerates ios/RunningPlan.xcodeproj after a pull, merge, rebase or branch switch that adds, deletes or renames
# an iOS app or test file, or changes ios/project.yml. The project is gitignored and lists every file by name, so a
# pull alone leaves it stale and Xcode fails with "cannot find ... in scope".
# Called by the hooks in this folder (turned on with `git config core.hooksPath scripts/githooks`) as:
#   regen-xcodeproj.sh <old commit> <new commit>
# Never fails the git command that ran it.

# Reads `git diff --name-status` output on stdin; succeeds when the Xcode project needs regenerating.
# Files in the APIClient package don't count: Xcode reads that package's own Package.swift.
ios_project_stale() {
  awk -F '\t' '
    function target(p) { return p ~ /^ios\/(RunningPlan|RunningPlanTests|RunningPlanUITests)\// }
    $2 == "ios/project.yml" || $3 == "ios/project.yml" { found = 1 }
    $1 ~ /^[ADRC]/ && (target($2) || target($3)) { found = 1 }
    END { exit found ? 0 : 1 }
  '
}

regen_main() {
  local old="$1" new="$2" root
  [[ "$old" =~ ^0+$ || -z "$old" || -z "$new" || "$old" == "$new" ]] && return 0
  root="$(git rev-parse --show-toplevel)" || return 0
  # Only refresh a project that was generated here before; verify.sh generates it where it's missing.
  [[ -d "$root/ios/RunningPlan.xcodeproj" ]] || return 0
  # quotepath=off keeps non-ASCII paths unquoted; --no-ext-diff ignores a user's external diff tool.
  git -c core.quotepath=off diff --no-ext-diff --name-status "$old" "$new" -- ios 2>/dev/null |
    ios_project_stale || return 0
  if ! command -v xcodegen >/dev/null 2>&1; then
    echo "githooks: iOS files changed; run 'cd ios && xcodegen generate' (xcodegen not found)" >&2
    return 0
  fi
  echo "githooks: iOS files changed, regenerating ios/RunningPlan.xcodeproj"
  (cd "$root/ios" && xcodegen generate --quiet) ||
    echo "githooks: xcodegen failed; run 'cd ios && xcodegen generate' to see why" >&2
  return 0
}

# Sourcing the file (as scripts/test/ does) only defines the functions.
if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then regen_main "${1:-}" "${2:-}"; fi
