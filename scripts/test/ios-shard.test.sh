#!/usr/bin/env bash
# Tests ios_shard_filters in scripts/verify.sh: CI's shards together run every UI test class exactly once, plus the
# unit tests once, however many shards there are; bad shard names are refused.
set -uo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=/dev/null
source "$here/../verify.sh"
cd "$here/../.."

fails=0
ok() { echo "ok   $1"; }
bad() { echo "FAIL $1"; fails=$((fails + 1)); }

[[ "$(ios_shard_filters unit)" == "-only-testing:RunningPlanTests" ]] && ok "unit shard is the unit test target" || bad "unit shard"

classes="$(grep -h '^final class .*: XCTestCase' ios/RunningPlanUITests/*.swift | sed 's/^final class \([A-Za-z0-9_]*\):.*/-only-testing:RunningPlanUITests\/\1/' | sort)"
for n in 1 2 3 4 7; do
  all=""
  for i in $(seq 1 "$n"); do all+="$(ios_shard_filters "ui:$i/$n")"$'\n'; done
  got="$(printf '%s' "$all" | grep -v '^$' | sort)"
  if [[ "$got" == "$classes" ]]; then ok "ui:*/$n covers each UI test class once"; else bad "ui:*/$n: got '$got', want '$classes'"; fi
done

for s in "" all ui ui:0/3 ui:4/3 ui:a/b; do
  rc=0; ios_shard_filters "$s" >/dev/null 2>&1 || rc=$?
  [[ $rc -eq 2 ]] && ok "shard '$s' is refused" || bad "shard '$s': rc $rc, want 2"
done

exit $((fails > 0))
