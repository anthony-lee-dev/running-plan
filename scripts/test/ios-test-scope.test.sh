#!/usr/bin/env bash
# Tests ios_test_filters in scripts/verify.sh: the full suite is the default; IOS_TEST_SCOPE=quick runs the unit
# tests plus the UI test classes named in IOS_UI_TESTS; anything else is refused.
set -uo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=/dev/null
source "$here/../verify.sh"

fails=0
check() { # name, expected output, scope, ui tests
  local got rc=0
  got="$(IOS_TEST_SCOPE="$3" IOS_UI_TESTS="$4" ios_test_filters 2>/dev/null)" || rc=$?
  if [[ "$got" == "$2" ]]; then echo "ok   $1"; else echo "FAIL $1: got '$got' (rc $rc), want '$2'"; fails=$((fails + 1)); fi
}

check "unset scope is the full suite (no filters)" "" "" ""
check "full ignores IOS_UI_TESTS" "" "full" "GoalUITests"
check "quick with no UI tests is the unit tests only" "-only-testing:RunningPlanTests" "quick" ""
check "bare class name goes under RunningPlanUITests" "-only-testing:RunningPlanTests
-only-testing:RunningPlanUITests/GoalUITests" "quick" "GoalUITests"
check "qualified names are used as given, commas and spaces split" "-only-testing:RunningPlanTests
-only-testing:RunningPlanUITests/RunDetailsTests
-only-testing:RunningPlanUITests/GoalUITests/testSave
-only-testing:RunningPlanUITests/InboxUITests" "quick" "RunningPlanUITests/RunDetailsTests, RunningPlanUITests/GoalUITests/testSave InboxUITests"

rc=0; IOS_TEST_SCOPE=fast ios_test_filters >/dev/null 2>&1 || rc=$?
if [[ $rc -eq 2 ]]; then echo "ok   unknown scope is refused"; else echo "FAIL unknown scope: rc $rc, want 2"; fails=$((fails + 1)); fi

exit $((fails > 0))
