#!/usr/bin/env bash
# One verification entry point for agents, the Stop hook and CI.
# Usage: bash scripts/verify.sh <api|spec|web|ios|all> [more packages...]
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
  echo "== spec: operations"
  bash scripts/test/spec-operations.test.sh
  echo "== spec: design notes endpoint map"
  bash scripts/test/design-notes.test.sh
}

verify_web() {
  echo "== web: api types match the spec"
  local tmp
  tmp="$(mktemp)"
  (cd web && npx --no-install openapi-typescript ../spec/openapi.yaml -o "$tmp" >/dev/null 2>&1) \
    || { echo "could not generate the web api types" >&2; rm -f "$tmp"; return 1; }
  if ! diff -q "$tmp" web/src/api/schema.d.ts >/dev/null; then
    rm -f "$tmp"
    echo "web/src/api/schema.d.ts is out of date: run npm run generate:types -w web" >&2
    return 1
  fi
  rm -f "$tmp"
  echo "== web: typecheck"
  npm run typecheck -w web --silent
  echo "== web: tests"
  npm test -w web --silent
  echo "== web: build"
  npm run build -w web --silent
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

# Reads `xcrun simctl list devices available` on stdin and prints the id of the first iPhone
# on the newest iOS runtime that has one (nothing if there is none).
pick_ios_sim() {
  awk '
    /^-- iOS [0-9.]+ --/ { split($3, v, "."); rt = sprintf("%05d%05d%05d", v[1], v[2], v[3]); next }
    /^-- / { rt = ""; next }
    rt != "" && /^ +iPhone/ && !(rt in first) {
      if (match($0, /\(([0-9A-Fa-f-]+)\) \([A-Za-z ]+\) *$/)) {
        s = substr($0, RSTART + 1); first[rt] = substr(s, 1, index(s, ")") - 1)
      }
    }
    END { best = ""; for (r in first) if (r > best) best = r; if (best != "") print first[best] }
  '
}

# Runs a command, stopping it after $1 seconds; returns 124 when it ran out of time (as GNU timeout does), 127 when
# the command can't start, 128 + n when signal n killed it. macOS has no `timeout`, so perl runs the command as a
# child: at the limit it sends TERM (xcodebuild then cancels its test session and the simulator's test runner), and
# KILL if the command is still there TIME_LIMIT_GRACE seconds later. A TERM, INT or HUP sent to the run (TaskStop,
# Ctrl-C) is passed on, so the command never outlives it.
run_with_time_limit() {
  local secs="$1"
  shift
  if [[ ! "$secs" =~ ^[1-9][0-9]*$ ]]; then echo "run_with_time_limit: '$secs' is not a number of seconds" >&2; return 2; fi
  # shellcheck disable=SC2016 # perl code, not shell
  perl -e '
    use POSIX ":sys_wait_h";
    my ($secs, $grace) = (shift, $ENV{TIME_LIMIT_GRACE} || 15);
    my $pid = fork() // die "fork failed: $!\n";
    if ($pid == 0) { exec { $ARGV[0] } @ARGV or do { print STDERR "cannot run $ARGV[0]: $!\n"; POSIX::_exit(127) } }
    sub status { my $s = shift; ($s & 127) ? 128 + ($s & 127) : $s >> 8 }
    sub stop { # TERM, then KILL after the grace period; returns the wait status
      kill "TERM", $pid;
      for (1 .. $grace * 10) { return $? if waitpid($pid, WNOHANG) == $pid; select(undef, undef, undef, 0.1) }
      kill "KILL", $pid; waitpid($pid, 0); return $?;
    }
    $SIG{$_} = sub { kill $_[0], $pid } for qw(TERM INT HUP);
    $SIG{ALRM} = sub { stop(); print STDERR "stopped after ${secs}s\n"; exit 124 };
    alarm $secs;
    while (waitpid($pid, 0) != $pid) { die "lost the child: $!\n" unless $!{EINTR} } # a forwarded signal interrupts the wait
    alarm 0;
    exit status($?);
  ' "$secs" "$@"
}

UI_TEST_API_URL=""
UI_TEST_API_PID=""

# Reads the UI-test API's log on stdin and prints the URL it announced (nothing until it has started).
ui_test_api_url_from_log() {
  sed -n 's/^ui-test api (in-memory) on //p' | head -n 1
}

# The in-memory API the iOS UI tests run against (api/test/ui-server), on any free port the OS picks, so a
# second run (the Stop hook's, say) never collides with this one or talks to a stale server.
start_ui_test_api() {
  local log
  log="$(mktemp "${TMPDIR:-/tmp}/ui-test-api.XXXXXX")"
  (cd api && UI_TEST_PORT=0 exec ../node_modules/.bin/tsx test/ui-server/main.ts) >"$log" 2>&1 &
  UI_TEST_API_PID=$!
  trap 'stop_ui_test_api; release_sim_lock' EXIT # the only EXIT trap in this script; chain it if another is added
  for _ in $(seq 1 60); do
    UI_TEST_API_URL="$(ui_test_api_url_from_log <"$log")"
    if [[ -n "$UI_TEST_API_URL" ]] && curl -sf "$UI_TEST_API_URL/v1/health" >/dev/null; then
      echo "== ios: UI-test API on $UI_TEST_API_URL"
      return 0
    fi
    sleep 0.5
  done
  echo "== ios: the UI-test API did not start; see $log" >&2
  return 1
}

stop_ui_test_api() {
  [[ -n "$UI_TEST_API_PID" ]] || return 0
  # tsx runs the server in a child node process, which holds the port.
  pkill -P "$UI_TEST_API_PID" 2>/dev/null || true
  kill "$UI_TEST_API_PID" 2>/dev/null || true
  UI_TEST_API_PID=""
}

# Reads the UI-test API's /__test/stats on stdin; succeeds when it generated at least one plan.
stats_show_generate() {
  grep -qE '"POST /v1/plans/generate": ?[1-9]'
}

# Fails when no UI test asked the local API for a plan: the app fell back to the deployed API, or the test skipped.
check_ui_tests_used_local_api() {
  local stats
  stats="$(curl -sf "$UI_TEST_API_URL/__test/stats")" || { echo "== ios: could not read the UI-test API stats" >&2; return 1; }
  if ! stats_show_generate <<<"$stats"; then
    echo "== ios: no UI test reached the local API ($stats)" >&2
    return 1
  fi
}

# Prints the xcodebuild test-selection flags, one per line, for IOS_TEST_SCOPE (empty or "full" = the whole suite,
# which is what CI runs; "quick" (what workers and the Stop hook run) = the unit tests plus the UI test classes named in IOS_UI_TESTS,
# separated by commas or spaces). A name without a "/" is a class of RunningPlanUITests; one with a "/" is used as given
# (a whole target, a class or Class/testMethod). Fails on any other scope.
ios_test_filters() {
  local scope="${IOS_TEST_SCOPE:-full}" name
  case "$scope" in
    full) ;;
    quick)
      echo "-only-testing:RunningPlanTests"
      for name in ${IOS_UI_TESTS//,/ }; do
        [[ "$name" == */* ]] || name="RunningPlanUITests/$name"
        echo "-only-testing:$name"
      done
      ;;
    *) echo "IOS_TEST_SCOPE must be 'full' or 'quick', not '$scope'" >&2; return 2 ;;
  esac
}

# Two iOS test runs on one simulator disturb each other (snapshot and UI tests fail at random, both run slower), and
# several workers verifying at once is normal. So a run claims its simulator with a lock directory holding its pid;
# a lock whose pid is gone is stale and taken over. Not used when IOS_SIM_DEST names the simulator.
SIM_LOCK_DIR=""

sim_lock_path() { echo "${TMPDIR:-/tmp}/running-plan-sim-$1.lock"; }

# Succeeds, and records the lock in SIM_LOCK_DIR, when this run now holds the simulator $1.
try_lock_sim() {
  local dir pid
  dir="$(sim_lock_path "$1")"
  if ! mkdir "$dir" 2>/dev/null; then
    pid="$(cat "$dir/pid" 2>/dev/null || true)"
    if [[ -n "$pid" ]] && kill -0 "$pid" 2>/dev/null; then return 1; fi
    rm -rf "$dir"
    mkdir "$dir" 2>/dev/null || return 1
  fi
  echo $$ >"$dir/pid"
  SIM_LOCK_DIR="$dir"
}

release_sim_lock() {
  [[ -n "$SIM_LOCK_DIR" ]] || return 0
  rm -rf "$SIM_LOCK_DIR"
  SIM_LOCK_DIR=""
}

# Sets CLAIMED_SIM to a simulator no other run holds, and locks it: $1 (the one pick_ios_sim chose) if free, else a clone
# of it named "RunningPlan verify <n>", made once and reused afterwards.
claim_ios_sim() {
  local base="$1" n name id list
  if try_lock_sim "$base"; then CLAIMED_SIM="$base"; return 0; fi
  for n in 2 3 4 5 6; do
    name="RunningPlan verify $n"
    list="$(xcrun simctl list devices available)"
    id="$(sed -n "s/^ *${name} (\([0-9A-Fa-f-]*\)) (.*/\1/p" <<<"$list" | head -n 1)"
    if [[ -z "$id" ]]; then
      id="$(xcrun simctl clone "$base" "$name")" || continue
    fi
    if try_lock_sim "$id"; then
      echo "== ios: $base is in use by another run; using the clone '$name' ($id)" >&2
      CLAIMED_SIM="$id"
      return 0
    fi
  done
  echo "== ios: every simulator is in use by another run; wait for one to finish or set IOS_SIM_DEST" >&2
  return 1
}

verify_ios() {
  if [[ "$(uname)" != "Darwin" ]]; then
    echo "== ios: skipped (needs macOS with Xcode)"; return 0
  fi
  if [[ ! -f ios/project.yml ]]; then
    echo "== ios: skipped (no ios/project.yml yet, see docs/backlog.md task 1.3)"; return 0
  fi
  local filters=() f scope="${IOS_TEST_SCOPE:-full}"
  ios_test_filters >/dev/null || return 2
  while IFS= read -r f; do filters+=("$f"); done < <(ios_test_filters)
  echo "== ios: api client matches the spec"
  bash scripts/generate-api-client.sh --check
  echo "== ios: generate project"
  (cd ios && xcodegen generate --quiet)
  local dest="${IOS_SIM_DEST:-}"
  if [[ -z "$dest" ]]; then
    # First iPhone on the newest iOS runtime; older runtimes may not match the installed Xcode.
    local id
    id="$(xcrun simctl list devices available | pick_ios_sim)"
    if [[ -z "$id" ]]; then
      echo "== ios: no iPhone simulator available; install one in Xcode > Settings > Components" >&2
      return 1
    fi
    claim_ios_sim "$id" || return 1
    id="$CLAIMED_SIM"
    dest="platform=iOS Simulator,id=${id}"
  fi
  start_ui_test_api
  if [[ "$scope" == quick ]]; then
    echo "== ios: QUICK scope (${filters[*]}); the rest of the UI suite runs in CI, and 'bash scripts/verify.sh ios' runs it all"
  fi
  echo "== ios: test on ${dest}"
  # A hung simulator can stall xcodebuild for ever, and with it anything waiting on this run, so it gets a limit
  # (IOS_TEST_TIMEOUT seconds, default 45 minutes; a full run takes 16-18 minutes locally and 18-28 in CI, where
  # ios-ci.yml sets 35 so the job's own 45-minute limit doesn't cut the run off first).
  local limit="${IOS_TEST_TIMEOUT:-2700}" rc=0
  # TEST_RUNNER_ variables reach the UI test process without the prefix.
  run_with_time_limit "$limit" env TEST_RUNNER_LOCAL_API_URL="$UI_TEST_API_URL" \
    xcodebuild test -project ios/RunningPlan.xcodeproj -scheme RunningPlan -destination "$dest" ${filters[@]+"${filters[@]}"} -quiet || rc=$?
  if [[ $rc -eq 124 ]]; then
    echo "== ios: xcodebuild test ran past ${limit}s and was stopped (a hung simulator?); run verify again" >&2
  fi
  [[ $rc -eq 0 ]] || return "$rc"
  # Only the full suite is sure to ask the API for a plan; a quick run may name no UI test, or one that doesn't.
  [[ "$scope" == quick ]] || check_ui_tests_used_local_api
  stop_ui_test_api
}

main() {
  local targets=("$@")
  [[ ${#targets[@]} -eq 0 || "${targets[0]}" == "all" ]] && targets=(spec api web ios)

  for t in "${targets[@]}"; do
    case "$t" in
      api) verify_api; verify_scripts ;;
      spec) verify_spec ;;
      web) verify_web ;;
      ios) verify_ios ;;
      *) echo "unknown package: $t" >&2; exit 2 ;;
    esac
  done
  # One lockfile for the repo, so audit once when any npm package was checked.
  if [[ " ${targets[*]} " =~ \ (api|spec|web)\  ]]; then verify_deps; fi
  echo "== verify: all green (${targets[*]})"
}

# Sourcing the file (as scripts/test/ does) only defines the functions.
if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then cd "$(dirname "$0")/.." && main "$@"; fi
