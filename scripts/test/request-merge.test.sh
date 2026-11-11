#!/usr/bin/env bash
# Tests the decision in scripts/request-merge.py (decide): which PRs may ask for auto-merge. No network: the
# function gets the changed files, the PR body, the allowed globs and whether the spec change only adds.
set -uo pipefail
here="$(cd "$(dirname "$0")" && pwd)"

python3 - "$here/../request-merge.py" <<'PY'
import importlib.util, sys

spec = importlib.util.spec_from_file_location("request_merge", sys.argv[1])
rm = importlib.util.module_from_spec(spec)
spec.loader.exec_module(rm)

L2 = ["docs/**", "api/**", "ios/**"]
L1 = ["docs/**", "api/test/**", "api/src/domain/**"]
GATE = "## Manual gates\n\n- [ ] Needs the paid Apple account\n\n## Reviewer notes\n"
CHECK = "## Manual gates\n\nNone.\n\n## Device check\n\n- [ ] #201: open Run details on the phone\n"
fails = 0


def check(name, want_merge, files, body="", allowed=L2, additive=None):
    global fails
    reason = rm.decide(files, body, allowed, additive)
    if (reason is None) == want_merge:
        print(f"ok   {name}")
    else:
        fails += 1
        print(f"FAIL {name}: {'merge' if reason is None else reason}")


check("api and ios at level 2", True, ["api/src/app.ts", "ios/RunningPlan/A.swift"])
check("web is outside level 2", False, ["web/src/App.tsx"])
check("workflow controls never merge", False, [".claude/settings.json"])
check("the merge script never merges itself", False, ["scripts/request-merge.py"])
check("the spec checker never merges itself", False, ["scripts/spec-additive.mjs", "api/src/app.ts"])
check("an unticked manual gate blocks", False, ["api/src/app.ts"], body=GATE)
check("a device check listed as an issue does not block", True, ["ios/RunningPlan/A.swift"], body=CHECK)

SPEC = ["spec/openapi.yaml", "api/src/app.ts", "ios/APIClient/Sources/APIClient/Generated/Types.swift",
        "web/src/api/schema.d.ts", "docs/design-notes.md"]
check("an additive spec change rides in the feature PR", True, SPEC, additive=True)
check("a spec change that alters the contract waits", False, SPEC, additive=False)
check("a spec change nobody compared waits", False, SPEC, additive=None)
check("an additive spec change alone", True, ["spec/openapi.yaml"], additive=True)
check("other spec files wait", False, ["spec/openapi.yaml", "spec/other.yaml"], additive=True)
check("the generated web types only ride with the spec", False, ["web/src/api/schema.d.ts"])
check("additive spec does not open the rest of web", False, SPEC + ["web/src/App.tsx"], additive=True)
check("level 1 does not take spec changes", False, ["spec/openapi.yaml"], allowed=L1, additive=True)
check("nothing allowed at level 0", False, ["docs/a.md"], allowed=[])

sys.exit(1 if fails else 0)
PY
