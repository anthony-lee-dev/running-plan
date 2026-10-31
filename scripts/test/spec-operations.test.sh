#!/usr/bin/env bash
# spec/openapi.yaml defines every operation agreed for backlog 1.2, with the right auth:
#   none   = no security (public)
#   app    = bearer token with the "app" scope (any signed-in client)
#   native = bearer token with the "activities:write" scope (iOS and Android only, never web)
# A route change here is a contract change: update this list in the same spec PR.
# Also: no schema used inside allOf may set additionalProperties: false (it would reject the fields the
# other allOf parts add); put unevaluatedProperties: false on the composed schema instead.
set -uo pipefail
root="$(cd "$(dirname "$0")/../.." && pwd)"
tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT

expected="$tmp/expected"
cat >"$expected" <<'LIST'
GET /v1/health getHealth none
POST /v1/auth/email/start startEmailSignIn none
POST /v1/auth/email/verify verifyEmailSignIn none
POST /v1/auth/refresh refreshToken none
DELETE /v1/account deleteAccount app
POST /v1/account/export exportAccount app
GET /v1/profile getProfile app
PATCH /v1/profile updateProfile app
POST /v1/plans/generate generatePlan none
GET /v1/plans listPlans app
POST /v1/plans createPlan app
GET /v1/plans/{planId} getPlan app
PATCH /v1/plans/{planId} updatePlan app
DELETE /v1/plans/{planId} deletePlan app
POST /v1/plans/{planId}/sessions createSession app
PATCH /v1/sessions/{sessionId} updateSession app
DELETE /v1/sessions/{sessionId} deleteSession app
POST /v1/sync sync app
POST /v1/activities:batch importActivities native
GET /v1/activities listActivities app
PATCH /v1/activities/{activityId} updateActivity app
PUT /v1/sessions/{sessionId}/match putMatch app
DELETE /v1/sessions/{sessionId}/match deleteMatch app
POST /v1/sessions/{sessionId}/checkins createCheckIn app
POST /v1/plans/{planId}/proposals:generate generateProposals app
GET /v1/plans/{planId}/proposals listProposals app
POST /v1/proposals/{proposalId}:accept acceptProposal app
POST /v1/proposals/{proposalId}:dismiss dismissProposal app
GET /v1/plans/{planId}/progress getProgress app
GET /v1/plans/{planId}/reviews/{weekIndex} getWeeklyReview app
LIST

if ! (cd "$root" && npx --no-install redocly bundle spec/openapi.yaml --ext json -o "$tmp/spec.json" >/dev/null 2>&1); then
  echo "FAIL could not bundle spec/openapi.yaml"; exit 1
fi

node -e '
const spec = require(process.argv[1]);
const methods = ["get","put","post","patch","delete"];
const out = [];
for (const [path, item] of Object.entries(spec.paths || {})) {
  for (const m of methods) {
    const op = item[m]; if (!op) continue;
    const sec = op.security ?? spec.security ?? [];
    let auth = "none";
    if (sec.some(s => (s.bearerAuth || []).includes("activities:write"))) auth = "native";
    else if (sec.some(s => (s.bearerAuth || []).includes("app"))) auth = "app";
    else if (sec.length && !sec.some(s => Object.keys(s).length === 0)) auth = "other";
    out.push(`${m.toUpperCase()} ${path} ${op.operationId} ${auth}`);
  }
}
console.log(out.sort().join("\n"));
' "$tmp/spec.json" >"$tmp/actual"

strict="$(node -e '
const s = require(process.argv[1]).components.schemas;
for (const [name, schema] of Object.entries(s))
  for (const part of schema.allOf || [])
    if (part.$ref && s[part.$ref.split("/").pop()].additionalProperties === false)
      console.log(`${name} -> ${part.$ref.split("/").pop()}`);
' "$tmp/spec.json")"
if [[ -n "$strict" ]]; then
  echo "FAIL schemas with additionalProperties: false used inside allOf:"; sed 's/^/    /' <<<"$strict"; exit 1
fi
echo "ok   no strict schema inside allOf"

LC_ALL=C sort "$expected" -o "$expected"
if diff -u "$expected" "$tmp/actual" >"$tmp/diff"; then
  echo "ok   spec has the $(wc -l <"$expected" | tr -d ' ') agreed operations with the right auth"
else
  echo "FAIL spec operations differ from the agreed list (- expected, + spec):"
  sed 's/^/    /' "$tmp/diff"; exit 1
fi
