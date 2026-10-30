#!/usr/bin/env bash
# Tests stats_show_generate in scripts/verify.sh: verify fails unless a UI test generated a plan on the local API.
set -uo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=/dev/null
source "$here/../verify.sh"

fails=0
check() { # name, expected (yes/no), stats JSON
  local got=no
  if stats_show_generate <<<"$3"; then got=yes; fi
  if [[ "$got" == "$2" ]]; then echo "ok   $1"; else echo "FAIL $1: got $got, want $2"; fails=$((fails + 1)); fi
}

check "one generate passes" yes '{"requests":{"GET /v1/health":2,"POST /v1/plans/generate":1}}'
check "several generates pass" yes '{"requests":{"POST /v1/plans/generate":12}}'
check "no requests fails" no '{"requests":{}}'
check "only health fails" no '{"requests":{"GET /v1/health":3}}'
check "zero generates fails" no '{"requests":{"POST /v1/plans/generate":0}}'

if [[ $fails -gt 0 ]]; then echo "ui-test-api: $fails failed"; exit 1; fi
echo "ui-test-api: all passed"
