#!/usr/bin/env bash
# Regenerates ios/APIClient/Sources/APIClient/Generated from spec/openapi.yaml with Apple's swift-openapi-generator.
# Usage: bash scripts/generate-api-client.sh [--check]   (--check fails if the committed code is out of date)
set -euo pipefail
cd "$(dirname "$0")/.."

out=ios/APIClient/Sources/APIClient/Generated
target="$out"
log="$(mktemp)"
trap 'rm -f "$log"; [[ "$target" == "$out" ]] || rm -rf "$target"' EXIT
if [[ "${1:-}" == "--check" ]]; then target="$(mktemp -d)"; fi

swift run --package-path ios/APIClientGenerator swift-openapi-generator generate spec/openapi.yaml \
  --config ios/APIClient/openapi-generator-config.yaml --output-directory "$target" >"$log" 2>&1 \
  || { cat "$log" >&2; echo "generator failed (output above)" >&2; exit 1; }

if [[ "${1:-}" == "--check" ]]; then
  diff -r "$out" "$target" >/dev/null || { echo "ios/APIClient is out of date: run bash scripts/generate-api-client.sh" >&2; exit 1; }
  echo "api client up to date"
fi
