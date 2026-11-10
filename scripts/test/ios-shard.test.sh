#!/usr/bin/env bash
# Tests ios_shard_filters in scripts/verify.sh: CI's shards together run the unit tests and every UI test class
# exactly once, however many shards there are; bad shard names are refused.
set -uo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=/dev/null
source "$here/../verify.sh"
cd "$here/../.."

fails=0
ok() { echo "ok   $1"; }
bad() { echo "FAIL $1"; fails=$((fails + 1)); }

want="$( { echo "-only-testing:RunningPlanTests"
  grep -h '^final class .*: XCTestCase' ios/RunningPlanUITests/*.swift | sed 's/^final class \([A-Za-z0-9_]*\):.*/-only-testing:RunningPlanUITests\/\1/'; } | sort)"
for n in 1 2 3 5 8 20; do
  all=""
  for i in $(seq 1 "$n"); do all+="$(ios_shard_filters "$i/$n")"$'\n'; done
  got="$(printf '%s' "$all" | grep -v '^$' | sort)"
  if [[ "$got" == "$want" ]]; then ok "shards */$n cover the unit tests and each UI class once"; else bad "shards */$n: got '$got', want '$want'"; fi
done

for i in 1 2 3 4 5; do
  [[ -n "$(ios_shard_filters "$i/5")" ]] && ok "shard $i/5 has tests" || bad "shard $i/5 is empty"
done

for s in "" all unit ui:1/3 0/3 4/3 a/b 1/0; do
  rc=0; ios_shard_filters "$s" >/dev/null 2>&1 || rc=$?
  [[ $rc -eq 2 ]] && ok "shard '$s' is refused" || bad "shard '$s': rc $rc, want 2"
done

exit $((fails > 0))
