#!/usr/bin/env bash
# Every dark board (designs/dark/DK-*.dc.html) has a reference PNG for the iOS snapshot tests:
# designs/dark/png/DK-<Name>.png, a real PNG, 1170 px wide (the 390 pt board at @3x), and no stray PNGs.
# Re-export with scripts/export-boards.sh.
set -uo pipefail
root="$(cd "$(dirname "$0")/../.." && pwd)"
dark="$root/designs/dark"
want_width=1170

fails=0
fail() { echo "FAIL $1"; fails=$((fails + 1)); }

# Width from the PNG IHDR chunk (bytes 16 to 19, big-endian).
png_width() { od -An -tu1 -v -j16 -N4 "$1" | tr -s ' \n' ' ' | awk '{print ($1*16777216)+($2*65536)+($3*256)+$4}'; }
is_png() { [[ "$(od -An -tx1 -N8 "$1" | tr -d ' \n')" == "89504e470d0a1a0a" ]]; }

boards=0
for html in "$dark"/DK-*.dc.html; do
  boards=$((boards + 1))
  name="$(basename "$html" .dc.html)"
  png="$dark/png/$name.png"
  if [[ ! -f "$png" ]]; then fail "$name: missing designs/dark/png/$name.png"; continue; fi
  if ! is_png "$png"; then fail "$name: not a PNG"; continue; fi
  w="$(png_width "$png")"
  if [[ ! "$w" =~ ^[0-9]+$ ]]; then fail "$name: could not read the width"
  elif [[ "$w" -ne $want_width ]]; then fail "$name: width $w, want $want_width"; else echo "ok   $name"; fi
done
[[ $boards -eq 11 ]] || fail "expected 11 DK boards, found $boards"

for png in "$dark"/png/*.png; do
  [[ -e "$png" ]] || continue
  name="$(basename "$png" .png)"
  [[ -f "$dark/$name.dc.html" ]] || fail "$name.png has no matching board"
done

[[ $fails -eq 0 ]] || { echo "$fails design PNG check(s) failed; run bash scripts/export-boards.sh"; exit 1; }
