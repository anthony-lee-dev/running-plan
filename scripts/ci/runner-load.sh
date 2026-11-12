#!/usr/bin/env bash
# Prints one line every 20 s until killed: UTC time, the load averages (1, 5 and 15 minutes) and the five busiest
# processes as name=%cpu. ios-ci.yml runs it beside each test shard, so a UI test that waited in vain on a starved
# simulator can be told from one that waited on the app or the API (issue #171). Portable ps and uptime only, so it
# runs the same on the macOS runners and on Linux.
sample() {
  local load top
  load="$(uptime | sed -E 's/.*load averages?: *//; s/,//g')"
  top="$(ps -Ao pcpu=,comm= | sort -rn | head -5 | awk '{ n = split($NF, part, "/"); printf "%s=%s ", part[n], $1 }')"
  echo "$(date -u +%H:%M:%S) load $load | $top"
}
if [[ "${1:-}" == "--once" ]]; then sample; exit 0; fi
echo "cores: $(getconf _NPROCESSORS_ONLN)"
while :; do sample; sleep 20; done
