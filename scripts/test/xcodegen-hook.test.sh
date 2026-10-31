#!/usr/bin/env bash
# Tests ios_project_stale in scripts/githooks/regen-xcodeproj.sh: given `git diff --name-status` output, regenerate
# the Xcode project only when an iOS file was added, deleted or renamed, or ios/project.yml changed.
set -uo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=/dev/null
source "$here/../githooks/regen-xcodeproj.sh"

fails=0
check() { # name, expected (yes|no), name-status input
  local got=no
  if ios_project_stale <<<"$3"; then got=yes; fi
  if [[ "$got" == "$2" ]]; then echo "ok   $1"; else echo "FAIL $1: got $got, want $2"; fails=$((fails + 1)); fi
}

check "added Swift file" yes "A	ios/RunningPlan/Features/Session/SessionView.swift"
check "deleted test file" yes "D	ios/RunningPlanTests/OldTests.swift"
check "renamed iOS file" yes "R100	ios/RunningPlan/A.swift	ios/RunningPlan/B.swift"
check "project.yml edited" yes "M	ios/project.yml"
check "added asset" yes "A	ios/RunningPlan/Assets.xcassets/Icon.imageset/Contents.json"
check "only edits to existing Swift files" no "M	ios/RunningPlan/App/RootView.swift
M	ios/RunningPlanTests/PlanStoreTests.swift"
check "added file outside ios" no "A	api/src/routes/sync.ts
M	docs/backlog.md"
check "added under APIClient package" no "A	ios/APIClient/Sources/APIClient/Generated/Client.swift"
check "nothing changed" no ""

[[ $fails -eq 0 ]]
