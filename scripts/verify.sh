#!/usr/bin/env bash
# One verification entry point for agents, the Stop hook and CI.
# Usage: bash scripts/verify.sh <api|spec|ios|all> [more packages...]
set -euo pipefail

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

# Known vulnerabilities in npm packages. High or critical in runtime dependencies fails;
# in dev tooling it warns, so a new upstream advisory does not block unrelated work.
# Offline on the Mac it skips with a note; in CI (CI=true) an unreachable registry fails.
verify_deps() {
  echo "== deps: audit"
  local offline='ENOTFOUND|ECONNREFUSED|ECONNRESET|ETIMEDOUT|EAI_AGAIN'
  local out rc=0
  out="$(npm audit --omit=dev --audit-level=high 2>&1)" || rc=$?
  if [[ $rc -ne 0 ]]; then
    if grep -qE "$offline" <<<"$out"; then
      if [[ -n "${CI:-}" ]]; then echo "$out"; return 1; fi
      echo "== deps: skipped (npm registry unreachable); CI runs it"; return 0
    fi
    echo "$out"
    if grep -qE 'found [0-9]+ vulnerabilit' <<<"$out"; then
      echo "== deps: high or critical vulnerability in runtime dependencies; fix it or ask the human" >&2
    else
      echo "== deps: npm audit failed (see the output above)" >&2
    fi
    return 1
  fi
  rc=0
  out="$(npm audit --audit-level=high 2>&1)" || rc=$?
  if [[ $rc -ne 0 ]] && grep -qE 'found [0-9]+ vulnerabilit' <<<"$out"; then
    echo "== deps: WARNING high or critical advisory in dev tooling; run 'npm audit' and add a backlog task"
  fi
}

verify_scripts() {
  echo "== scripts: tests"
  local t
  for t in scripts/test/*.test.sh; do bash "$t"; done
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

main() {
  local targets=("$@")
  [[ ${#targets[@]} -eq 0 || "${targets[0]}" == "all" ]] && targets=(spec api ios)

  for t in "${targets[@]}"; do
    case "$t" in
      api) verify_api; verify_scripts ;;
      spec) verify_spec ;;
      ios) verify_ios ;;
      *) echo "unknown package: $t" >&2; exit 2 ;;
    esac
  done
  # One lockfile for the repo, so audit once when any npm package was checked.
  if [[ " ${targets[*]} " =~ \ (api|spec)\  ]]; then verify_deps; fi
  echo "== verify: all green (${targets[*]})"
}

# Sourcing the file (as scripts/test/ does) only defines the functions.
if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then cd "$(dirname "$0")/.." && main "$@"; fi
