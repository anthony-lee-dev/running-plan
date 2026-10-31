#!/usr/bin/env bash
# Creates the labels, milestones and open-task issues listed in scripts/github/issues.json. Safe to re-run:
# labels are updated, milestones and issues (matched by the "[id] " title prefix) are only created when missing,
# and each "Blocked by" line and link is added only when absent.
# Needs the GitHub CLI signed in with repo access (gh auth login) and jq.
set -euo pipefail
cd "$(dirname "$0")/.."
REPO="${REPO:-anthony-lee-dev/running-plan}"
DATA=scripts/github/issues.json

echo "== labels"
jq -c '.labels[]' "$DATA" | while read -r l; do
  gh label create "$(jq -r .name <<<"$l")" --repo "$REPO" --force \
    --color "$(jq -r .color <<<"$l")" --description "$(jq -r .description <<<"$l")" </dev/null >/dev/null
done

echo "== milestones"
existing_ms="$(gh api "repos/$REPO/milestones?state=all&per_page=100" --jq '.[].title')"
jq -c '.milestones[]' "$DATA" | while read -r m; do
  title="$(jq -r .title <<<"$m")"
  if grep -qxF "$title" <<<"$existing_ms"; then continue; fi
  gh api -X POST "repos/$REPO/milestones" -f title="$title" -f description="$(jq -r .description <<<"$m")" --silent </dev/null
  echo "created milestone: $title"
done

issues_json() { gh issue list --repo "$REPO" --state all --limit 500 --json number,title; }

echo "== issues"
current="$(issues_json)"
jq -c '.issues[]' "$DATA" | while read -r i; do
  id="$(jq -r .id <<<"$i")"
  if jq -e --arg p "[$id] " 'any(.[]; .title | startswith($p))' <<<"$current" >/dev/null; then continue; fi
  args=(--repo "$REPO" --title "[$id] $(jq -r .title <<<"$i")" --body "$(jq -r .body <<<"$i")"
        --milestone "$(jq -r .milestone <<<"$i")")
  while read -r lbl; do args+=(--label "$lbl"); done < <(jq -r '.labels[]' <<<"$i")
  gh issue create "${args[@]}" </dev/null
done

echo "== blocked-by links"
# Every dependency gets a "Blocked by: #n" line in the issue body (agents read that with gh issue view), and, when
# the repo supports it, a real "blocked by" link as well.
current="$(issues_json)"
num_of() { jq -r --arg p "[$1] " '.[] | select(.title | startswith($p)) | .number' <<<"$current"; }
jq -c '.issues[] | select(.blocked_by | length > 0)' "$DATA" | while read -r i; do
  id="$(jq -r .id <<<"$i")"
  n="$(num_of "$id")"
  refs=""
  for b in $(jq -r '.blocked_by[]' <<<"$i"); do
    bn="$(num_of "$b")"
    if [ -z "$n" ] || [ -z "$bn" ]; then echo "missing issue for $id or $b; skipped"; continue; fi
    refs="${refs:+$refs, }#$bn"
    linked="$(gh api "repos/$REPO/issues/$n/dependencies/blocked_by" --jq '.[].number' 2>/dev/null </dev/null || true)"
    if ! grep -qx "$bn" <<<"$linked"; then
      bid="$(gh api "repos/$REPO/issues/$bn" --jq .id </dev/null)"
      if gh api -X POST "repos/$REPO/issues/$n/dependencies/blocked_by" -F issue_id="$bid" --silent 2>/dev/null </dev/null; then
        echo "#$n blocked by #$bn (link)"
      else
        echo "#$n: dependencies API unavailable or already linked for #$bn"
      fi
    fi
  done
  [ -n "$refs" ] || continue
  body="$(gh issue view "$n" --repo "$REPO" --json body --jq .body </dev/null)"
  if ! grep -q '^Blocked by:' <<<"$body"; then
    gh issue edit "$n" --repo "$REPO" --body "$body"$'\n\n'"Blocked by: $refs" </dev/null >/dev/null
    echo "#$n body line: Blocked by: $refs"
  fi
done
echo "done"
