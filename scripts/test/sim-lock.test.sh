#!/usr/bin/env bash
# Tests the simulator lock in scripts/verify.sh: a live holder keeps others out, a dead one's lock is taken over.
set -uo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=/dev/null
source "$here/../verify.sh"

tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT
export TMPDIR="$tmp"
fails=0
check() { # name, expected exit code, command...
  local name="$1" want="$2" rc=0
  shift 2
  "$@" || rc=$?
  if [[ $rc -eq $want ]]; then echo "ok   $name"; else echo "FAIL $name: exit $rc, want $want"; fails=$((fails + 1)); fi
}

check "a free simulator is locked" 0 try_lock_sim AAAA
release_sim_lock
check "released simulator is free again" 0 try_lock_sim AAAA

# Another live process (this shell's parent-owned sleep) holds BBBB.
sleep 30 & holder=$!
mkdir "$(sim_lock_path BBBB)"; echo "$holder" >"$(sim_lock_path BBBB)/pid"
check "a simulator held by a live run is refused" 1 try_lock_sim BBBB
kill "$holder"; wait "$holder" 2>/dev/null || true # verify.sh's set -e applies once sourced
check "a dead run's lock is taken over" 0 try_lock_sim BBBB
release_sim_lock

exit $((fails > 0))
