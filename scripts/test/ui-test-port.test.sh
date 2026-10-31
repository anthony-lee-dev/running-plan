#!/usr/bin/env bash
# Tests that the UI-test API takes any free port and verify.sh reads it back, so two runs never collide on 8790.
set -uo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=/dev/null
source "$here/../verify.sh"
cd "$here/../.."

fails=0
ok() { echo "ok   $1"; }
bad() { echo "FAIL $1"; fails=$((fails + 1)); }

got="$(ui_test_api_url_from_log <<<'ui-test api (in-memory) on http://127.0.0.1:54321')"
[[ "$got" == "http://127.0.0.1:54321" ]] && ok "reads the URL from the log" || bad "reads the URL from the log: got '$got'"
got="$(ui_test_api_url_from_log <<<'starting up')"
[[ -z "$got" ]] && ok "no URL yet gives nothing" || bad "no URL yet gives nothing: got '$got'"

start_ui_test_api >/dev/null
first="$UI_TEST_API_URL"; first_pid="$UI_TEST_API_PID"
UI_TEST_API_PID="" UI_TEST_API_URL=""
start_ui_test_api >/dev/null
second="$UI_TEST_API_URL"
[[ -n "$first" && -n "$second" && "$first" != "$second" ]] && ok "two servers get different URLs" || bad "two servers get different URLs: '$first' '$second'"
curl -sf "$first/v1/health" >/dev/null && curl -sf "$second/v1/health" >/dev/null && ok "both answer" || bad "both answer"
stop_ui_test_api
UI_TEST_API_PID="$first_pid"; stop_ui_test_api
sleep 0.5
curl -sf "$first/v1/health" >/dev/null && bad "stopped servers are gone" || ok "stopped servers are gone"

if [[ $fails -gt 0 ]]; then echo "ui-test-port: $fails failed"; exit 1; fi
echo "ui-test-port: all passed"
