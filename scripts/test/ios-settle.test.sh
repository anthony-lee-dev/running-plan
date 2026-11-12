#!/usr/bin/env bash
# Tests wait_for_runner_to_settle in scripts/verify.sh: after the simulator boots it waits until the runner's 1-minute
# load average is at or under the limit, or until the time allowed runs out, and says which (issue #171).
set -uo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=/dev/null
source "$here/../verify.sh"

fails=0
ok() { echo "ok   $1"; }
bad() { echo "FAIL $1"; fails=$((fails + 1)); }

# The loads the runner reports ("<1-minute> <5-minute>"), one per look; the last repeats. No real waiting.
loads=(); looks=0
runner_load_now() { local i=$looks; (( i < ${#loads[@]} )) || i=$(( ${#loads[@]} - 1 )); echo "${loads[$i]}"; }
settle_pause() { looks=$((looks + 1)); }
run() { looks=0; out="$(wait_for_runner_to_settle "$@" 2>&1)"; rc=$?; }

loads=("433.04 180" "215.3 250" "92.4 200"); run 600 150
[[ $rc -eq 0 && "$out" == *"settled after 20s"* && "$out" == *"load 92.4"* ]] && ok "waits until the load is at the limit" || bad "falling load: rc=$rc out='$out'"

# Seen in CI: the first look came just after the boot, with the load at 145 and climbing to 206 a minute later.
loads=("145.77 67.88" "206 90" "300 180" "140 250"); run 600 150
[[ $rc -eq 0 && "$out" == *"settled after 30s"* && "$out" == *"load 140"* ]] && ok "a load under the limit but still rising is not settled" || bad "rising: rc=$rc out='$out'"

loads=("3.2 4.0"); run 600 150
[[ $rc -eq 0 && "$out" == *"settled after 0s"* ]] && ok "a calm runner does not wait" || bad "calm: rc=$rc out='$out'"

loads=("300 200" "280 220" "260 240"); run 20 150
[[ $rc -eq 0 && "$out" == *"still busy after 20s"* && "$out" == *"load 260"* ]] && ok "gives up after the time allowed, and never fails the run" || bad "busy: rc=$rc out='$out'"

loads=("" "" ""); run 20 150
[[ $rc -eq 0 && "$out" == *"still busy after 20s"* ]] && ok "a load that can't be read is not settled, and does not fail the run" || bad "unreadable: rc=$rc out='$out'"

loads=("300 200"); run 0 150
[[ $rc -eq 0 && -z "$out" ]] && ok "0 seconds allowed means no wait and no report" || bad "off: rc=$rc out='$out'"
for odd in abc 08 4.8 ""; do
  run "$odd" 150
  [[ $rc -eq 0 && -z "$out" ]] && ok "'$odd' seconds allowed means no wait" || bad "odd max '$odd': rc=$rc out='$out'"
done

exit $((fails > 0))
