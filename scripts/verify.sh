#!/usr/bin/env bash
# One verification entry point for agents, the Stop hook and CI.
# Usage: bash scripts/verify.sh <api|spec|ios|all> [more packages...]
set -euo pipefail
cd "$(dirname "$0")/.."

verify_api() {
  echo "== api: boundaries"
  bash scripts/check-boundaries.sh
  echo "== api: typecheck"
  npm run typecheck -w api --silent
  echo "== api: tests"
  npm test -w api --silent
}

verify_spec() {
  echo "== spec: lint"
  npx --no-install redocly lint spec/openapi.yaml
}

verify_ios() {
  if [[ "$(uname)" != "Darwin" ]]; then
    echo "== ios: skipped (needs macOS with Xcode)"; return 0
  fi
  if [[ ! -f ios/project.yml ]]; then
    echo "== ios: skipped (no ios/project.yml yet, see docs/backlog.md task 1.3)"; return 0
  fi
  echo "== ios: generate project"
  (cd ios && xcodegen generate --quiet)
  local dest="${IOS_SIM_DEST:-}"
  if [[ -z "$dest" ]]; then
    # First available iPhone simulator on this Mac.
    local name
    name="$(xcrun simctl list devices available | grep -m1 -oE 'iPhone[^()]*' | sed 's/ *$//' || true)"
    if [[ -z "$name" ]]; then
      echo "== ios: no iPhone simulator available; install one in Xcode > Settings > Components" >&2
      return 1
    fi
    dest="platform=iOS Simulator,name=${name}"
  fi
  echo "== ios: test on ${dest}"
  xcodebuild test -project ios/RunningPlan.xcodeproj -scheme RunningPlan -destination "$dest" -quiet
}

targets=("$@")
[[ ${#targets[@]} -eq 0 || "${targets[0]}" == "all" ]] && targets=(spec api ios)

for t in "${targets[@]}"; do
  case "$t" in
    api) verify_api ;;
    spec) verify_spec ;;
    ios) verify_ios ;;
    *) echo "unknown package: $t" >&2; exit 2 ;;
  esac
done
echo "== verify: all green (${targets[*]})"
