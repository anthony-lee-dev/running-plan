#!/usr/bin/env bash
# Tests launch_timeout_failures in scripts/verify.sh: it names the failed tests to run again only when EVERY failure is
# "Timed out while launching application via Xcode" in a UI test; any other failure, or no failure, gives nothing.
set -uo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=/dev/null
source "$here/../verify.sh"

fails=0
ok() { echo "ok   $1"; }
bad() { echo "FAIL $1"; fails=$((fails + 1)); }

LAUNCH="Failed to launch <XCUIApplicationImpl: 0x1 ca.anthonylee.runningplan.dev at /x/RunningPlan.app> via Xcode: Timed out while launching application via Xcode."
# One failed or passed test case in the shape `xcresulttool get test-results tests` prints.
case_json() { # class method result [message...]
  local class="$1" method="$2" result="$3" target="${CASE_TARGET:-RunningPlanUITests}" children="" m
  shift 3
  for m in "$@"; do children+="{\"nodeType\":\"Failure Message\",\"name\":$(printf '%s' "$m" | jq -Rs .)},"; done
  printf '{"nodeType":"Test Case","name":"%s()","nodeIdentifier":"%s/%s()","nodeIdentifierURL":"test://com.apple.xcode/RunningPlan/%s/%s/%s","result":"%s","children":[%s]}' \
    "$method" "$class" "$method" "$target" "$class" "$method" "$result" "${children%,}"
}
wrap() { # case... -> a whole result
  local IFS=,
  printf '{"testNodes":[{"nodeType":"Test Plan","children":[{"nodeType":"UI test bundle","children":[{"nodeType":"Test Suite","name":"S","children":[%s]}]}]}]}' "$*"
}
got() { printf '%s' "$1" | launch_timeout_failures; }

out="$(got "$(wrap "$(case_json InboxUITests testA Failed "$LAUNCH")" "$(case_json InboxUITests testB Passed)")")"
[[ "$out" == "RunningPlanUITests/InboxUITests/testA()" ]] && ok "a launch timeout is named for -only-testing" || bad "launch timeout: got '$out'"

out="$(got "$(wrap "$(case_json InboxUITests testA Failed "$LAUNCH")" "$(case_json GoalUITests testB Failed "$LAUNCH" "$LAUNCH")")")"
[[ "$(printf '%s\n' "$out" | wc -l | tr -d ' ')" == 2 ]] && ok "two launch timeouts are both named" || bad "two launch timeouts: got '$out'"

out="$(got "$(wrap "$(case_json InboxUITests testA Failed "$LAUNCH")" "$(case_json GoalUITests testB Failed "XCTAssertTrue failed")")")"
[[ -z "$out" ]] && ok "a launch timeout next to a real failure retries nothing" || bad "mixed failures: got '$out'"

out="$(got "$(wrap "$(case_json InboxUITests testA Failed "$LAUNCH" "XCTAssertTrue failed")")")"
[[ -z "$out" ]] && ok "one test with a launch timeout and another failure retries nothing" || bad "mixed messages: got '$out'"

out="$(got "$(wrap "$(case_json InboxUITests testA Failed "Failed to tap Button: Timed out while synthesizing event.")")")"
[[ -z "$out" ]] && ok "a hang inside a test (synthesizing) is not retried" || bad "synthesizing: got '$out'"

out="$(got "$(wrap "$(case_json InboxUITests testA Failed)")")"
[[ -z "$out" ]] && ok "a failure with no message retries nothing" || bad "no message: got '$out'"

out="$(got "$(wrap "$(case_json InboxUITests testA Passed)")")"
[[ -z "$out" ]] && ok "no failure retries nothing" || bad "no failure: got '$out'"

out="$(CASE_TARGET=RunningPlanTests; unit="$(case_json SomeTests testA Failed "$LAUNCH")"; got "$(wrap "$unit")")"
[[ -z "$out" ]] && ok "only UI tests are retried" || bad "unit test: got '$out'"

[[ $fails -eq 0 ]] || { echo "$fails failed"; exit 1; }
