#!/usr/bin/env bash
# Configures the GitHub repo for the agent workflow. Safe to re-run.
# Needs the GitHub CLI signed in as the repo owner (gh auth login).
set -euo pipefail
cd "$(dirname "$0")/.."
REPO="${REPO:-anthony-lee-dev/running-plan}"

echo "== merge settings: squash only, auto-merge allowed, delete merged branches"
gh api -X PATCH "repos/$REPO" --silent \
  -F allow_auto_merge=true -F delete_branch_on_merge=true \
  -F allow_squash_merge=true -F allow_merge_commit=false -F allow_rebase_merge=false

echo "== security: secret scanning with push protection, Dependabot alerts"
gh api -X PATCH "repos/$REPO" --silent --input - <<'JSON'
{"security_and_analysis": {"secret_scanning": {"status": "enabled"},
                           "secret_scanning_push_protection": {"status": "enabled"}}}
JSON
gh api -X PUT "repos/$REPO/vulnerability-alerts" --silent

echo "== security: Dependabot security update PRs"
gh api -X PUT "repos/$REPO/automated-security-fixes" --silent

echo "== ruleset on main: PR required, api and ios checks required, no force push or delete"
existing="$(gh api "repos/$REPO/rulesets" --jq '.[] | select(.name=="main") | .id' || true)"
if [[ -n "$existing" ]]; then
  gh api -X PUT "repos/$REPO/rulesets/$existing" --silent --input scripts/github/ruleset-main.json
else
  gh api -X POST "repos/$REPO/rulesets" --silent --input scripts/github/ruleset-main.json
fi
echo "GitHub settings applied."
