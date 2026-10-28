#!/usr/bin/env python3
"""Ask GitHub to auto-merge a PR, but only if the autonomy level on main allows it.

Usage: python3 scripts/request-merge.py <pr-number>

GitHub then merges by itself once the required checks (api, ios) pass; the ruleset on main
enforces that part server-side. This script enforces the rest locally:
  - the level is read from autonomy.json on origin/main, never from the PR branch
  - every changed file must match the globs allowed at that level
  - PRs that touch the workflow's own controls never auto-merge
  - unticked manual-gate boxes block the merge
Exit 0 = auto-merge requested, 3 = left for the human (not an error).
"""
import fnmatch
import json
import re
import subprocess
import sys

PROTECTED = [
    "autonomy.json", ".claude/**", ".github/**", "scripts/request-merge.py",
    "scripts/setup-github.sh", "scripts/github/**", "spec/**",
]


def run(*args):
    return subprocess.run(args, check=True, capture_output=True, text=True).stdout


def matches(path, patterns):
    for p in patterns:
        if p.endswith("/**") and (path == p[:-3] or path.startswith(p[:-2])):
            return True
        if fnmatch.fnmatch(path, p):
            return True
    return False


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

    info = json.loads(run("gh", "pr", "view", pr, "--json", "files,body,isDraft,baseRefName"))
    if info["baseRefName"] != "main":
        leave("PR does not target main")
    if info["isDraft"]:
        leave("PR is a draft")

    files = [f["path"] for f in info["files"]]
    guarded = [f for f in files if matches(f, PROTECTED)]
    if guarded:
        leave(f"it changes workflow controls or the spec: {', '.join(guarded)}")
    outside = [f for f in files if not matches(f, allowed)]
    if outside:
        leave(f"level {level} does not cover: {', '.join(outside)}")

    body = info.get("body") or ""
    gates = re.split(r"^##\s+Manual gates.*$", body, flags=re.M | re.I)
    if len(gates) > 1 and re.search(r"^\s*[-*]\s+\[ \]", gates[1].split("\n## ")[0], flags=re.M):
        leave("manual-gate boxes are still unticked")

    run("gh", "pr", "merge", pr, "--auto", "--squash", "--delete-branch")
    print(f"Auto-merge requested for PR #{pr} at level {level}. GitHub merges once api and ios pass.")


if __name__ == "__main__":
    main()
