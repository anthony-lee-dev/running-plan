#!/usr/bin/env bash
# Tests pick_ios_sim in scripts/verify.sh: first iPhone on the newest iOS runtime, by id.
set -uo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=/dev/null
source "$here/../verify.sh"

fails=0
check() { # name, expected output, input
  local got; got="$(pick_ios_sim <<<"$3")"
  if [[ "$got" == "$2" ]]; then echo "ok   $1"; else echo "FAIL $1: got '$got', want '$2'"; fails=$((fails + 1)); fi
}

check "newest runtime wins" "BBBB-2222" "== Devices ==
-- iOS 26.4 --
    iPhone 17 Pro (AAAA-1111) (Shutdown) 
-- iOS 27.0 --
    iPad Air (CCCC-3333) (Shutdown) 
    iPhone 18 Pro (BBBB-2222) (Shutdown) 
-- watchOS 27.0 --
    Apple Watch Series 12 (46mm) (DDDD-4444) (Shutdown) "

check "version sorts numerically" "EEEE-5555" "-- iOS 27.10 --
    iPhone 18 (EEEE-5555) (Booted) 
-- iOS 27.9 --
    iPhone 18 (FFFF-6666) (Shutdown) "

check "runtime with no iPhone is skipped" "AAAA-1111" "-- iOS 26.4 --
    iPhone 17 (AAAA-1111) (Shutdown) 
-- iOS 27.0 --
    iPad (CCCC-3333) (Shutdown) "

check "no iPhone at all" "" "-- iOS 27.0 --
    iPad (CCCC-3333) (Shutdown) "

[[ $fails -eq 0 ]]
