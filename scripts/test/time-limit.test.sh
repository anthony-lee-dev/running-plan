#!/usr/bin/env bash
# Tests run_with_time_limit in scripts/verify.sh: it stops a command that runs too long (macOS has no `timeout`),
# so a hung xcodebuild ends the run instead of leaving whatever waits on it waiting for ever.
set -uo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=/dev/null
source "$here/../verify.sh"

fails=0
check() { # name, expected exit code, command...
  local name="$1" want="$2"; shift 2
  local got=0
  "$@" >/dev/null 2>&1 || got=$?
  if [[ "$got" == "$want" ]]; then echo "ok   $name"; else echo "FAIL $name: exit $got, want $want"; fails=$((fails + 1)); fi
}

check "a command that finishes in time keeps its success" 0 run_with_time_limit 5 true
check "a command that finishes in time keeps its failure" 3 run_with_time_limit 5 bash -c 'exit 3'
check "arguments reach the command" 0 run_with_time_limit 5 test "a b" = "a b"

check "a command killed by a signal gives 128 + the signal" 143 run_with_time_limit 5 bash -c 'kill -TERM $$'
check "one argument is a program name, not shell code" 127 run_with_time_limit 5 'echo one; echo two'
check "a limit that isn't a number is refused" 2 run_with_time_limit soon true

start=$SECONDS
check "a command past its limit is stopped with 124" 124 run_with_time_limit 1 sleep 4
if (( SECONDS - start > 5 )); then echo "FAIL the stop took $((SECONDS - start))s"; fails=$((fails + 1)); else echo "ok   the stop is prompt"; fi

# xcodebuild cancels its test session on SIGTERM, so the limit asks with TERM before it forces KILL.
tmp="$(mktemp -d)"
check "a stopped command gets TERM first, so it can clean up" 124 \
  run_with_time_limit 1 bash -c "trap 'touch $tmp/cleaned; kill %1; exit 1' TERM; sleep 3 & wait"
if [[ -f "$tmp/cleaned" ]]; then echo "ok   its TERM handler ran"; else echo "FAIL its TERM handler didn't run"; fails=$((fails + 1)); fi

start=$SECONDS
check "a command that ignores TERM is killed after the grace period" 124 \
  env TIME_LIMIT_GRACE=1 bash -c "source '$here/../verify.sh'; run_with_time_limit 1 bash -c 'trap \"\" TERM; sleep 4'"
if (( SECONDS - start > 6 )); then echo "FAIL the kill took $((SECONDS - start))s"; fails=$((fails + 1)); else echo "ok   the kill is prompt"; fi
rm -rf "$tmp"

[[ $fails -eq 0 ]]
