#!/usr/bin/env bash
# docs/design-notes.md "Screen-to-endpoint map" stays in step with spec/openapi.yaml and the DK boards:
#   - every DK-*.dc.html board has a row in the map
#   - every operationId named in the section (a bare `camelCase` word in backticks) exists in the spec
#   - every spec operation is named somewhere in the section (a screen, or "Not called from a screen")
# A renamed or added endpoint therefore fails here until the map is updated.
set -uo pipefail
root="$(cd "$(dirname "$0")/../.." && pwd)"
notes="$root/docs/design-notes.md"
tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT
fail=0

section="$tmp/section"
awk '/^## Screen-to-endpoint map/ { on = 1; next } on && /^## / { exit } on' "$notes" >"$section"
if [[ ! -s "$section" ]]; then
  echo "FAIL docs/design-notes.md has no '## Screen-to-endpoint map' section"; exit 1
fi

missing_boards=""
for f in "$root"/designs/dark/DK-*.dc.html; do
  b="$(basename "$f" .dc.html)"
  grep -qE "^\| *[^|]*\b${b}\b" "$section" || missing_boards+=" $b"
done
if [[ -n "$missing_boards" ]]; then
  echo "FAIL boards with no row in the screen-to-endpoint map:$missing_boards"; fail=1
else
  echo "ok   every DK board has a row in the screen-to-endpoint map"
fi

if ! (cd "$root" && npx --no-install redocly bundle spec/openapi.yaml --ext json -o "$tmp/spec.json" >/dev/null 2>&1); then
  echo "FAIL could not bundle spec/openapi.yaml"; exit 1
fi
node -e '
const spec = require(process.argv[1]);
for (const item of Object.values(spec.paths || {}))
  for (const op of Object.values(item)) if (op && op.operationId) console.log(op.operationId);
' "$tmp/spec.json" | sort -u >"$tmp/spec-ops"

# Bare words in backticks that look like operation ids: camelCase, or any lowercase word the spec uses as
# an id (such as `sync`). Sync kinds like `session.update`, file names and tokens like `card` are skipped.
grep -oE '`[a-z][A-Za-z]*`' "$section" | tr -d '`' | sort -u >"$tmp/words"
{ grep -E '[A-Z]' "$tmp/words"; grep -vE '[A-Z]' "$tmp/words" | grep -Fxf "$tmp/spec-ops"; } | sort -u >"$tmp/named"

unknown="$(comm -23 "$tmp/named" "$tmp/spec-ops")"
if [[ -n "$unknown" ]]; then
  echo "FAIL operationIds in the map that the spec does not define:"; sed 's/^/    /' <<<"$unknown"; fail=1
else
  echo "ok   every operationId in the map exists in the spec"
fi

unmapped="$(comm -13 "$tmp/named" "$tmp/spec-ops")"
if [[ -n "$unmapped" ]]; then
  echo "FAIL spec operations missing from the map (add them to a screen or 'Not called from a screen'):"
  sed 's/^/    /' <<<"$unmapped"; fail=1
else
  echo "ok   all $(wc -l <"$tmp/spec-ops" | tr -d ' ') spec operations appear in the map"
fi
exit "$fail"
