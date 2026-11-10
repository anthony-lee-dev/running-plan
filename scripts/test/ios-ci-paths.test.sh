#!/usr/bin/env bash
# Pins the path filter in .github/workflows/ios-ci.yml ("Decide whether to build"): which changed files make the
# iOS job build. Runs the workflow's own pathspec in a scratch git repository.
set -uo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
wf="$here/../../.github/workflows/ios-ci.yml"
# The words between `git diff --quiet "$BASE" HEAD -- \` and the `; then`, minus the line continuations.
spec="$(awk '/git diff --quiet/{p=1; next} p{print} p&&/; then/{exit}' "$wf" | sed 's/\\$//; s/ 2>\/dev\/null; then$//')"
[[ -n "$spec" ]] || { echo "FAIL could not read the pathspec from the workflow"; exit 1; }
eval "paths=($spec)"

tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT
cd "$tmp" && git init -q && git config user.email t@t && git config user.name t
for f in ios/RunningPlan/A.swift ios/CLAUDE.md spec/openapi.yaml designs/dark/png/DK-Next.png api/src/app.ts api/wrangler.toml \
  api/CLAUDE.md api/test/wrangler-config.test.ts api/test/ui-server/app.ts api/migrations/0001.sql api/package.json package-lock.json \
  scripts/verify.sh scripts/generate-api-client.sh .github/workflows/ios-ci.yml web/src/a.ts web/README.md; do
  mkdir -p "$(dirname "$f")"; echo a >"$f"
done
git add -A && git commit -qm base

fails=0
check() { # want (build|skip), file
  echo b >>"$2"
  if git diff --quiet HEAD -- "${paths[@]}" 2>/dev/null; then got=skip; else got=build; fi
  git checkout -q -- .
  if [[ "$got" == "$1" ]]; then echo "ok   $2 -> $got"; else echo "FAIL $2: $got, want $1"; fails=$((fails + 1)); fi
}
for f in ios/RunningPlan/A.swift spec/openapi.yaml designs/dark/png/DK-Next.png api/src/app.ts api/test/ui-server/app.ts api/migrations/0001.sql \
  api/package.json package-lock.json scripts/verify.sh scripts/generate-api-client.sh .github/workflows/ios-ci.yml; do check build "$f"; done
for f in ios/CLAUDE.md api/wrangler.toml api/CLAUDE.md api/test/wrangler-config.test.ts web/src/a.ts web/README.md; do check skip "$f"; done
exit $((fails > 0))
