#!/usr/bin/env bash
# Fails if Cloudflare-specific code leaks outside the adapter folder and the Workers entry.
set -euo pipefail
cd "$(dirname "$0")/.."

pattern='cloudflare:|@cloudflare/|D1Database|KVNamespace|R2Bucket|ExecutionContext|ExportedHandler'
hits="$(grep -rnE "$pattern" api/src --include='*.ts' \
  | grep -v '^api/src/adapters/cloudflare/' \
  | grep -v '^api/src/index.ts:' || true)"

if [[ -n "$hits" ]]; then
  echo "Cloudflare references outside api/src/adapters/cloudflare/ or api/src/index.ts:" >&2
  echo "$hits" >&2
  exit 1
fi
echo "boundaries ok"
