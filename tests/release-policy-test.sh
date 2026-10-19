#!/bin/bash
# Static policy assertions for the release workflows and release.sh.
#
# These checks keep the in-repository workflows honest, but they are NOT an
# enforcement boundary: a writer can push a branch with different YAML. The
# boundary is the repository configuration described in README.md
# ("Required repository settings"), which must be verified separately.
set -euo pipefail

ROOT=$(cd "$(dirname "$0")/.." && pwd)
cd "$ROOT"

shellcheck_status=0
if command -v shellcheck >/dev/null; then
  shellcheck release.sh tests/*.sh || shellcheck_status=$?
else
  echo "WARNING: shellcheck not installed; skipping"
fi

python3 - <<'PY'
import glob
import re
import sys

import yaml

failures = []


def check(cond, msg):
    if not cond:
        failures.append(msg)


def load(path):
    with open(path) as f:
        doc = yaml.safe_load(f)
    # PyYAML parses the bare key `on` as boolean True.
    if True in doc and "on" not in doc:
        doc["on"] = doc.pop(True)
    return doc


def perms(obj):
    p = obj.get("permissions")
    if p is None:
        return None
    if isinstance(p, str):
        return {"*": p}
    return p


def writes(p):
    return {k for k, v in (p or {}).items() if v == "write" or v == "write-all"}


def steps(job):
    return job.get("steps", [])


def check_common(path, doc):
    top = perms(doc)
    check(top is not None, f"{path}: must set top-level permissions")
    check(not writes(top), f"{path}: top-level permissions must not grant write")
    for name, job in doc["jobs"].items():
        jp = perms(job)
        check(jp is not None, f"{path}:{name}: job must set explicit permissions")
        for step in steps(job):
            uses = step.get("uses", "")
            if uses:
                check(re.fullmatch(r"[\w.-]+/[\w./-]+@[0-9a-f]{40}", uses) is not None,
                      f"{path}:{name}: action not pinned to a commit SHA: {uses}")
            if uses.startswith("actions/checkout@"):
                check((step.get("with") or {}).get("persist-credentials") is False,
                      f"{path}:{name}: checkout must set persist-credentials: false")
            run = step.get("run", "")
            check("${{" not in run,
                  f"{path}:{name}: run block interpolates an expression; pass it via env")
            env = step.get("env") or {}
            for k, v in env.items():
                check("secrets." not in str(v),
                      f"{path}:{name}: step env {k} uses a repository secret")


workflows = sorted(glob.glob(".github/workflows/*.y*ml"))
docs = {p: load(p) for p in workflows}
for p, d in docs.items():
    check_common(p, d)

PREPARE = ".github/workflows/auto-release.yaml"
PUBLISH = ".github/workflows/publish-release.yaml"
check(PREPARE in docs, f"{PREPARE} missing")
check(PUBLISH in docs, f"{PUBLISH} missing")

# Only the publish job of publish-release.yaml may hold a write permission or
# use the release environment.
for p, d in docs.items():
    for name, job in d["jobs"].items():
        w = writes(perms(job))
        env = job.get("environment")
        env_name = env.get("name") if isinstance(env, dict) else env
        trusted = (p == PUBLISH and name == "publish")
        if trusted:
            check(w == {"contents"}, f"{p}:{name}: must request exactly contents: write")
            check(env_name == "release", f"{p}:{name}: must use the protected 'release' environment")
            check(job.get("needs") == "build", f"{p}:{name}: must depend only on the build job")
        else:
            check(not w, f"{p}:{name}: must not request write permissions ({sorted(w)})")
            check(env_name != "release", f"{p}:{name}: must not use the 'release' environment")
        for step in steps(job):
            run = step.get("run", "")
            if "release.sh publish" in run:
                check(trusted, f"{p}:{name}: only the trusted publish job may run release.sh publish")
            if trusted:
                check("release.sh build" not in run and "release.sh prepare" not in run,
                      f"{p}:{name}: publish job must not build or discover versions")

# Preparation workflow: schedule/manual, read-only, never publishes.
if PREPARE in docs:
    d = docs[PREPARE]
    check(set(d["on"]) == {"schedule", "workflow_dispatch"},
          f"{PREPARE}: triggers must be schedule and workflow_dispatch only")
    runs = [s.get("run", "") for j in d["jobs"].values() for s in steps(j)]
    check(any("release.sh prepare" in r for r in runs), f"{PREPARE}: must run release.sh prepare")
    check(not any(re.search(r"release\.sh (build|publish)", r) for r in runs),
          f"{PREPARE}: must not build for a tag or publish")
    check(not any(re.search(r"\bgh release (create|edit|delete|upload)", r) for r in runs),
          f"{PREPARE}: must not mutate releases")

# Publication workflow: tag push only, no other trigger.
if PUBLISH in docs:
    d = docs[PUBLISH]
    on = d["on"]
    check(isinstance(on, dict) and set(on) == {"push"}, f"{PUBLISH}: must trigger on push only")
    push = (on or {}).get("push") or {}
    check(set(push) == {"tags"}, f"{PUBLISH}: push trigger must be tags only (no branches/paths)")
    check(push.get("tags") == ["v*"], f"{PUBLISH}: push tags must be exactly ['v*']")
    check(perms(d) == {}, f"{PUBLISH}: top-level permissions must be {{}}")
    build = d["jobs"].get("build", {})
    check(perms(build) == {"contents": "read"}, f"{PUBLISH}:build: must be contents: read")
    check("refs/tags/v" in str(build.get("if", "")), f"{PUBLISH}:build: must require a v* tag ref")
    build_runs = " ".join(s.get("run", "") for s in steps(build))
    check("merge-base --is-ancestor" in build_runs and "origin/main" in build_runs,
          f"{PUBLISH}:build: must require the tagged commit to be on main")
    check('release.sh build --tag "$TAG" --commit "$COMMIT"' in build_runs,
          f"{PUBLISH}:build: must bind tag and commit")
    for s in steps(build):
        if s.get("uses", "").startswith("actions/checkout@"):
            check((s.get("with") or {}).get("ref") == "${{ github.sha }}",
                  f"{PUBLISH}:build: checkout must pin the tagged commit")
    pub = d["jobs"].get("publish", {})
    pub_runs = [s.get("run", "") for s in steps(pub)]
    check(any('release.sh publish --tag "$TAG" --commit "$COMMIT"' in r for r in pub_runs),
          f"{PUBLISH}:publish: must publish with an explicit tag/commit binding")
    for s in steps(pub):
        if s.get("uses", "").startswith("actions/checkout@"):
            check((s.get("with") or {}).get("ref") == "${{ github.sha }}",
                  f"{PUBLISH}:publish: checkout must pin the tagged commit")
        if "run" in s:
            env = s.get("env") or {}
            if "release.sh publish" in s["run"]:
                check(env.get("TAG") == "${{ github.ref_name }}" and env.get("COMMIT") == "${{ github.sha }}",
                      f"{PUBLISH}:publish: TAG/COMMIT must come from the triggering tag")
            check(not re.search(r"(^|[;&|]\s*)(bash|sh|source|\.)\s+\S*(dist|RUNNER_TEMP)", s["run"]),
                  f"{PUBLISH}:publish: must not execute downloaded artifacts")

# release.sh publication guarantees.
with open("release.sh") as f:
    script = f.read()
creates = re.findall(r"gh release create(?:\\\n|[^\n])*", script)
check(len(creates) == 1, "release.sh: expected exactly one gh release create")
for c in creates:
    check("--verify-tag" in c, "release.sh: gh release create must use --verify-tag")
    check('--repo "$REPO"' in c, "release.sh: gh release create must target --repo explicitly")
    check("--target" not in c, "release.sh: gh release create must not pass --target")
check('REPO="stripe/claude-code-patches"' in script, "release.sh: REPO must be stripe/claude-code-patches")
check(not re.search(r"gh release (edit|delete|upload|delete-asset)", script),
      "release.sh: must never edit, delete or upload to existing releases")
check(not re.search(r"\bgit (tag|push)\b|git/refs", script), "release.sh: must never create or push tags")
check(not re.search(r"\b(eval|source)\b", script), "release.sh: must not eval or source data")
for cmd in ("gh release view", "gh release list"):
    for line in [l for l in script.splitlines() if cmd in l]:
        check('--repo "$REPO"' in line, f"release.sh: {cmd} must target --repo explicitly")
check(re.search(r"^cmd_publish\(\) \{.*?require_tag_commit", script, re.S | re.M) is not None,
      "release.sh: publish must verify the tag/commit binding")
publish_body = re.search(r"^cmd_publish\(\) \{(.*?)^\}", script, re.S | re.M)
check(publish_body is not None and "resolve_version" not in publish_body.group(1),
      "release.sh: publish must not perform version discovery")

if failures:
    print("Policy failures:")
    for msg in failures:
        print(f"  - {msg}")
    sys.exit(1)
print(f"Policy checks passed for {len(workflows)} workflow(s) and release.sh")
PY

exit "$shellcheck_status"
