#!/usr/bin/env bash
# Tests scripts/spec-additive.mjs: a contract change that only adds (exit 0) may ride in a feature PR; one that
# removes or alters anything existing (exit 1) stays a spec PR of its own for the human.
set -uo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
tool="$here/../spec-additive.mjs"

fails=0
tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT

cat >"$tmp/base.yaml" <<'YAML'
openapi: 3.1.0
info: { title: t, version: 1.0.0 }
tags:
  - name: plans
paths:
  /v1/plans:
    get:
      operationId: listPlans
      description: Lists plans.
      parameters:
        - name: limit
          in: query
          schema: { type: integer, maximum: 50 }
      responses:
        "200":
          description: ok
          content:
            application/json:
              schema: { $ref: "#/components/schemas/Plan" }
components:
  schemas:
    Plan:
      type: object
      required: [id]
      properties:
        id: { type: string }
        status: { type: string, enum: [draft, active] }
        content: { type: string, maxLength: 10 }
YAML

# name, want (additive|breaking), a yq-free edit: a sed script applied to base.yaml, or @file for a whole new head
check() {
  local name="$1" want="$2" got
  if node "$tool" "$tmp/base.yaml" "$tmp/head.yaml" >"$tmp/out" 2>&1; then got=additive; else got=breaking; fi
  if [[ "$got" == "$want" ]]; then echo "ok   $name"; else echo "FAIL $name: $got, want $want"; cat "$tmp/out"; fails=$((fails + 1)); fi
}
edit() { sed "$1" "$tmp/base.yaml" >"$tmp/head.yaml"; }
append() { cp "$tmp/base.yaml" "$tmp/head.yaml"; printf '%s\n' "$1" >>"$tmp/head.yaml"; }

cp "$tmp/base.yaml" "$tmp/head.yaml"; check "no change" additive

append '    Run:
      type: object
      required: [id]
      properties:
        id: { type: string }';                                         check "a new schema" additive
edit 's|^components:|  /v1/runs:\n    get:\n      operationId: listRuns\n      responses:\n        "200": { description: ok }\ncomponents:|'
                                                                       check "a new path" additive
edit 's|^    get:|    post:\n      operationId: createPlan\n      responses:\n        "201": { description: made }\n    get:|'
                                                                       check "a new method on a path" additive
append '        note: { type: string }';                               check "a new optional property" additive
edit 's|enum: \[draft, active\]|enum: [draft, active, done]|';         check "a new enum value" additive
edit 's|description: Lists plans.|description: Lists the plans of the account.|'
                                                                       check "a description edit" additive
edit 's|        "200":|        "429": { description: slow down }\n        "200":|'
                                                                       check "a new response code" additive
edit 's|          schema: { type: integer, maximum: 50 }|          schema: { type: integer, maximum: 50 }\n        - name: from\n          in: query\n          schema: { type: string }|'
                                                                       check "a new optional parameter" additive
edit 's|  - name: plans|  - name: plans\n  - name: runs|';             check "a new tag" additive
edit 's|version: 1.0.0|version: 1.1.0|';                               check "a version bump" additive

edit '/status: {/d';                                                   check "a removed property" breaking
edit '/^  \/v1\/plans:/,/Plan" }/d';                                   check "a removed path" breaking
edit 's|id: { type: string }|id: { type: integer }|';                  check "a changed type" breaking
edit 's|enum: \[draft, active\]|enum: [draft]|';                       check "a removed enum value" breaking
edit 's|required: \[id\]|required: [id, status]|';                     check "a newly required property" breaking
edit 's|maximum: 50|maximum: 20|';                                     check "a tighter limit" breaking
edit 's|id: { type: string }|id: { type: string, maxLength: 5 }|';     check "a new limit on an existing field" breaking
edit 's|operationId: listPlans|operationId: plans|';                   check "a renamed operation" breaking
edit 's|          schema: { type: integer, maximum: 50 }|          schema: { type: integer, maximum: 50 }\n        - name: from\n          in: query\n          required: true\n          schema: { type: string }|'
                                                                       check "a new required parameter" breaking
edit 's|      operationId: listPlans|      operationId: listPlans\n      requestBody: { content: {} }|'
                                                                       check "a request body on an existing operation" breaking
# A property that happens to be called "content" is a schema, not a map that may grow.
edit 's|content: { type: string, maxLength: 10 }|content: { type: string, maxLength: 10, pattern: "^a" }|'
                                                                       check "a new limit on a property named like a map" breaking
edit 's|          in: query|          in: header|';                    check "a moved parameter" breaking

echo "not: [yaml" >"$tmp/head.yaml";                                   check "a head that does not parse" breaking

[[ $fails -eq 0 ]] || exit 1
