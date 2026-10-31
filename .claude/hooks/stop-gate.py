#!/usr/bin/env python3
"""Stop hook: keep Claude working while verification is red for the packages it changed.

Reads the hook input JSON on stdin. If the branch changed files under api/, spec/ or ios/, runs
scripts/verify.sh for those packages. On failure it prints {"decision": "block", "reason": ...}
so Claude continues and fixes it. After MAX_BLOCKS blocks in one session it lets Claude stop,
so a problem it cannot fix (for example a missing simulator) never loops forever.
A green run is remembered by a fingerprint (it does not notice toolchain or node_modules changes) of the changed package files, so later turns that change nothing
there (chat, docs, a commit of the same content) skip the run.
"""
import hashlib
import json
import os
import subprocess
import sys
import tempfile

MAX_BLOCKS = 5
# Prefix -> package. Root npm files and scripts/ map to api, whose verify runs the audit and script tests.
PACKAGES = {"api/": "api", "spec/": "spec", "ios/": "ios", "scripts/": "api",
            "package.json": "api", "package-lock.json": "api"}


def git(cwd, *args):
    r = subprocess.run(["git", "-c", "core.quotepath=off", *args], cwd=cwd, capture_output=True, text=True)
    return r.stdout.strip() if r.returncode == 0 else ""


def changed_packages(cwd):
    base = git(cwd, "merge-base", "HEAD", "origin/main") or git(cwd, "rev-parse", "HEAD")
    files = set(git(cwd, "diff", "--name-only", base).splitlines())
    files |= set(git(cwd, "ls-files", "--others", "--exclude-standard").splitlines())
    pkgs = {pkg for f in files for prefix, pkg in PACKAGES.items() if f.startswith(prefix)}
    if "spec" in pkgs:
        pkgs.add("api")  # contract changes must keep the API green too
    return sorted(pkgs)


def state_fingerprint(cwd, pkgs):
    """Hash of the base commit and the content of every changed or new file under a package path."""
    base = git(cwd, "merge-base", "HEAD", "origin/main") or git(cwd, "rev-parse", "HEAD")
    files = set(git(cwd, "diff", "--name-only", base).splitlines())
    files |= set(git(cwd, "ls-files", "--others", "--exclude-standard").splitlines())
    h = hashlib.sha256(base.encode())
    for f in sorted(f for f in files if any(f.startswith(p) for p in PACKAGES)):
        h.update(f.encode())
        try:
            path = os.path.join(cwd, f)
            h.update(str(os.stat(path).st_mode).encode())  # a chmod changes the state too
            with open(path, "rb") as fh:
                h.update(fh.read())
        except OSError:
            h.update(b"<gone>")  # a deleted file still changes the state
    h.update(",".join(pkgs).encode())
    return h.hexdigest()


def main():
    try:
        data = json.load(sys.stdin)
    except Exception:
        data = {}
    cwd = data.get("cwd") or os.environ.get("CLAUDE_PROJECT_DIR") or os.getcwd()
    session = data.get("session_id", "unknown")

    pkgs = changed_packages(cwd)
    if not pkgs:
        return 0

    where = hashlib.sha256(cwd.encode()).hexdigest()[:12]
    green = os.path.join(tempfile.gettempdir(), f"running-plan-stop-gate-green-{session}-{where}")
    fingerprint = state_fingerprint(cwd, pkgs)
    if os.path.exists(green):
        with open(green) as f:
            if f.read() == fingerprint:
                return 0  # this exact state already passed

    result = subprocess.run(
        ["bash", "scripts/verify.sh", *pkgs], cwd=cwd, capture_output=True, text=True
    )
    counter = os.path.join(tempfile.gettempdir(), f"running-plan-stop-gate-{session}")
    if result.returncode == 0:
        if os.path.exists(counter):
            os.remove(counter)
        with open(green, "w") as f:
            f.write(fingerprint)
        return 0

    count = int(open(counter).read()) if os.path.exists(counter) else 0
    if count >= MAX_BLOCKS:
        print(json.dumps({"systemMessage": f"verify.sh still failing after {MAX_BLOCKS} attempts; stopping. Say so in the PR."}))
        return 0
    with open(counter, "w") as f:
        f.write(str(count + 1))

    tail = "\n".join((result.stdout + result.stderr).splitlines()[-60:])
    reason = (
        f"scripts/verify.sh {' '.join(pkgs)} is failing (attempt {count + 1} of {MAX_BLOCKS}). "
        f"Fix the cause, do not weaken or skip tests. Last output:\n{tail}"
    )
    print(json.dumps({"decision": "block", "reason": reason}))
    return 0


if __name__ == "__main__":
    sys.exit(main())
