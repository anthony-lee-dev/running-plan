#!/usr/bin/env python3
"""Ask GitHub to auto-merge a PR, but only if the autonomy level on main allows it.

Usage: python3 scripts/request-merge.py <pr-number>

GitHub then merges by itself once the required checks (api, ios) pass; the ruleset on main
enforces that part server-side. This script enforces the rest locally:
  - the level is read from autonomy.json on origin/main, never from the PR branch
  - every changed file must match the globs allowed at that level
  - PRs that touch the workflow's own controls never auto-merge
  - a change to spec/openapi.yaml may ride along only when it adds to the contract and removes or alters
    nothing (scripts/spec-additive.mjs decides); any other spec change waits for the human
  - unticked boxes under "## Manual gates" block the merge. A device check is not one of them: it is an
    issue of its own (see /ship), listed under "## Device check", and never holds the PR open
Exit 0 = auto-merge requested, 3 = left for the human (not an error).
"""
import fnmatch
import json
import re
import os
import subprocess
import sys
import tempfile

PROTECTED = [
    "autonomy.json", ".claude/**", ".github/**", "scripts/request-merge.py",
    "scripts/setup-github.sh", "scripts/github/**", "scripts/spec-additive.mjs",
]
SPEC_FILE = "spec/openapi.yaml"
# Regenerated from the spec, so it changes whenever the spec does; the rest of web/ follows the level.
SPEC_GENERATED = ["web/src/api/schema.d.ts"]


def run(*args):
    return subprocess.run(args, check=True, capture_output=True, text=True).stdout


def matches(path, patterns):
    for p in patterns:
        if p.endswith("/**") and (path == p[:-3] or path.startswith(p[:-2])):
            return True
        if fnmatch.fnmatch(path, p):
            return True
    return False


def decide(files, body, allowed, spec_additive):
    """Why the PR is left for the human, or None when it may ask for auto-merge.

    files: changed paths. body: the PR body. allowed: the globs of the level on main (empty at level 0).
    spec_additive: True when the change to spec/openapi.yaml only adds, False when it removes or alters
    something, None when it was not compared.
    """
    if not allowed:
        return "the autonomy level allows nothing"
    guarded = [f for f in files if matches(f, PROTECTED)]
    if guarded:
        return f"it changes workflow controls: {', '.join(guarded)}"

    spec = [f for f in files if matches(f, ["spec/**"])]
    if spec:
        if spec != [SPEC_FILE]:
            return f"it changes spec files other than {SPEC_FILE}: {', '.join(spec)}"
        if spec_additive is not True:
            return "it removes or alters part of the contract (a spec PR of its own, for the human)"
        if "api/**" not in allowed:
            return "this level does not cover API code, so it does not cover contract changes"
        allowed = [*allowed, SPEC_FILE, *SPEC_GENERATED]

    outside = [f for f in files if not matches(f, allowed)]
    if outside:
        return f"the level does not cover: {', '.join(outside)}"

    gates = re.split(r"^##\s+Manual gates.*$", body or "", flags=re.M | re.I)
    if len(gates) > 1 and re.search(r"^\s*[-*]\s+\[ \]", gates[1].split("\n## ")[0], flags=re.M):
        return "manual-gate boxes are still unticked"
    return None


def spec_is_additive(head_ref, head_oid):
    """Compares spec/openapi.yaml on the PR head with the commit it branched from on main."""
    here = os.path.dirname(os.path.abspath(__file__))
    try:
        run("git", "fetch", "--quiet", "origin", head_ref)
        base = run("git", "merge-base", "origin/main", head_oid).strip()
        with tempfile.TemporaryDirectory() as tmp:
            for name, rev in (("base.yaml", base), ("head.yaml", head_oid)):
                with open(os.path.join(tmp, name), "w") as f:
                    f.write(run("git", "show", f"{rev}:{SPEC_FILE}"))
            r = subprocess.run(
                ["node", os.path.join(here, "spec-additive.mjs"), os.path.join(tmp, "base.yaml"), os.path.join(tmp, "head.yaml")],
                capture_output=True, text=True, cwd=os.path.dirname(here),
            )
    except (subprocess.CalledProcessError, OSError) as e:
        print(f"Could not compare the spec ({e}); treating the change as not additive.")
        return False
    if r.returncode != 0:
        print("The spec change is not additive:\n" + (r.stdout + r.stderr).strip())
    return r.returncode == 0


def leave(reason):
    print(f"Not auto-merging: {reason}. Leaving the PR for the human.")
    sys.exit(3)


def main():
    if len(sys.argv) != 2 or not sys.argv[1].isdigit():
        print(__doc__)
        sys.exit(2)
    pr = sys.argv[1]

    run("git", "fetch", "--quiet", "origin", "main")
    config = json.loads(run("git", "show", "origin/main:autonomy.json"))
    level = str(config.get("level", 0))
    allowed = config.get("levels", {}).get(level, [])
    if level == "0" or not allowed:
        leave(f"autonomy level is {level}")

    info = json.loads(run("gh", "pr", "view", pr, "--json", "files,body,isDraft,baseRefName,headRefName,headRefOid"))
    if info["baseRefName"] != "main":
        leave("PR does not target main")
    if info["isDraft"]:
        leave("PR is a draft")

    files = [f["path"] for f in info["files"]]
    additive = spec_is_additive(info["headRefName"], info["headRefOid"]) if SPEC_FILE in files else None
    reason = decide(files, info.get("body") or "", allowed, additive)
    if reason:
        leave(f"{reason} (level {level})")

    run("gh", "pr", "merge", pr, "--auto", "--squash", "--delete-branch")
    print(f"Auto-merge requested for PR #{pr} at level {level}. GitHub merges once api and ios pass.")


if __name__ == "__main__":
    main()
