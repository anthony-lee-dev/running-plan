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

# The loads the runner reports, one per look; the last repeats. No real waiting.
loads=(); looks=0
runner_load_now() { local i=$looks; (( i < ${#loads[@]} )) || i=$(( ${#loads[@]} - 1 )); echo "${loads[$i]}"; }
settle_pause() { looks=$((looks + 1)); }
run() { looks=0; out="$(wait_for_runner_to_settle "$@" 2>&1)"; rc=$?; }
# The function runs in a subshell above, so count its looks from its report instead.

loads=(433.04 215.3 92.4 23.9); run 600 24
[[ $rc -eq 0 && "$out" == *"settled after 30s"* && "$out" == *"load 23.9"* ]] && ok "waits until the load is at the limit" || bad "falling load: rc=$rc out='$out'"

loads=(3.2); run 600 24
[[ $rc -eq 0 && "$out" == *"settled after 0s"* ]] && ok "a calm runner does not wait" || bad "calm: rc=$rc out='$out'"

loads=(300 280 260); run 20 24
[[ $rc -eq 0 && "$out" == *"still busy after 20s"* && "$out" == *"load 260"* ]] && ok "gives up after the time allowed, and never fails the run" || bad "busy: rc=$rc out='$out'"

loads=(300); run 0 24
[[ $rc -eq 0 && -z "$out" ]] && ok "0 seconds allowed means no wait and no report" || bad "off: rc=$rc out='$out'"

exit $((fails > 0))
