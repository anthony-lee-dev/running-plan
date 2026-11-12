#!/usr/bin/env bash
# Renders the dark boards (designs/dark/DK-*.dc.html) to designs/dark/png/DK-<Name>.png with Playwright's chrome-headless-shell:
# 390 pt wide at @3x (1170 px), as tall as the board. Fonts come from Google Fonts, so it needs the network.
# The boards were written for the canvas runtime (support.js), which is not in the repo; they are plain HTML with
# inline styles, so a browser renders them without it. Re-run after re-exporting the boards from the canvas.
# Usage: bash scripts/export-boards.sh [DK-Name ...]   (default: all boards)
set -euo pipefail
cd "$(dirname "$0")/.."

# A browser this script owns: Playwright's chrome-headless-shell, never the user's Google Chrome (launching that
# wakes its updater, and macOS asks for "App Management" permission). CHROME=/path overrides it.
chrome="${CHROME:-}"
if [[ -z "$chrome" ]]; then
  case "$(uname -s)" in
    Darwin) cache="$HOME/Library/Caches/ms-playwright" ;;
    *) cache="$HOME/.cache/ms-playwright" ;;
  esac
  cache="${PLAYWRIGHT_BROWSERS_PATH:-$cache}"
  chrome="$(find "$cache" -path '*/chromium_headless_shell-*/*' -type f -name chrome-headless-shell 2>/dev/null | sort | tail -n 1 || true)"
fi
if [[ -z "$chrome" || ! -x "$chrome" ]]; then
  echo "chrome-headless-shell not found. Install it once with:" >&2
  echo "  npx playwright install chromium-headless-shell" >&2
  echo "(or set CHROME=/path/to/a/headless/chromium)" >&2
  exit 1
fi

dark=designs/dark
out="$dark/png"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
mkdir -p "$out"

names=("$@")
if [[ ${#names[@]} -eq 0 ]]; then
  for f in "$dark"/DK-*.dc.html; do names+=("$(basename "$f" .dc.html)"); done
fi

run_chrome() { "$chrome" --headless --disable-gpu --hide-scrollbars --no-first-run --no-default-browser-check \
  --user-data-dir="$work/profile" --virtual-time-budget=8000 "$@" 2>/dev/null; }

for name in "${names[@]}"; do
  src="$dark/$name.dc.html"
  [[ -f "$src" ]] || { echo "no board $src" >&2; exit 1; }
  page="$work/$name.html"
  # Drop the missing runtime script; once fonts are in, write the board's height into the DOM.
  sed 's#<script src="./support.js"></script>##' "$src" >"$page"
  cat >>"$page" <<'JS'
<script>
document.fonts.ready.then(function () {
  var b = document.querySelector('div[style*="width:390px"]');
  document.body.setAttribute('data-board-height', Math.ceil(b.getBoundingClientRect().height));
});
</script>
JS
  height="$(run_chrome --window-size=390,1000 --dump-dom "file://$page" \
    | grep -oE 'data-board-height="[0-9]+"' | grep -oE '[0-9]+' || true)"
  [[ -n "$height" ]] || { echo "$name: could not measure the board" >&2; exit 1; }
  run_chrome --force-device-scale-factor=3 --window-size="390,$height" \
    --screenshot="$PWD/$out/$name.png" "file://$page" >/dev/null
  echo "$name: 390x$height pt -> $out/$name.png"
done
