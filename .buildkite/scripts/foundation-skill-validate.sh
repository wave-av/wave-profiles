#!/usr/bin/env bash
# foundation-skill-validate — GHA parity with _checks.yml job `skill-validate`
# (SKILL.md frontmatter gate). Validates *SKILL.md in THIS repo; no-op if the
# repo has none. Python body mirrors wave-foundation/scripts/validate-skills.py;  # guard:allow shared checks repo mention (verified-safe reference)
# keep the two in sync.
#
# Needs PyYAML. Prefer the image's copy; otherwise pip-install a PINNED pyyaml
# into a throwaway dir (GHA installs unpinned `pyyaml` — the pin is the one
# deliberate hardening; same gate, deterministic install).
set -euo pipefail
cd "$(dirname "$0")/../.."

if ! python3 -c 'import yaml' 2>/dev/null; then
  echo "PyYAML not in image; installing pinned pyyaml into a temp dir"
  PYDIR="$(mktemp -d)"
  trap 'rm -rf "$PYDIR"' EXIT
  python3 -m pip install --quiet --target "$PYDIR" 'pyyaml==6.2.1'
  export PYTHONPATH="$PYDIR${PYTHONPATH:+:$PYTHONPATH}"
fi

python3 - <<'PY'
import sys, os, re, subprocess
import yaml
allf = subprocess.run(["git","ls-files","*SKILL.md"], capture_output=True, text=True).stdout.splitlines()
# Only validate invocable skills; skip nested reference/vendored SKILL.md.
skip = ("/references/", "/_external/", "/_consolidated", "/_archived", "/node_modules/", "/dist/")
files = [f for f in allf if not any(s in "/" + f for s in skip)]
if not files:
    print("no SKILL.md in repo — skill gate is a no-op"); sys.exit(0)
errs = []
for p in files:
    d = os.path.basename(os.path.dirname(p))
    t = open(p, encoding="utf-8", errors="replace").read()
    m = re.match(r"^---\s*\n(.*?)\n---", t, re.S)
    if not m:
        errs.append(f"{p}: no frontmatter block"); continue
    fm = m.group(1)
    seen, dup = set(), set()
    for line in fm.split("\n"):
        k = re.match(r"^([A-Za-z_][\w-]*):", line)
        if k: (dup if k.group(1) in seen else seen).add(k.group(1))
    if dup: errs.append(f"{p}: duplicate frontmatter keys: {', '.join(sorted(dup))}")
    try:
        data = yaml.safe_load(fm) or {}
    except yaml.YAMLError as e:
        errs.append(f"{p}: invalid YAML frontmatter: {e}"); continue
    if not isinstance(data, dict):
        errs.append(f"{p}: frontmatter is not a mapping"); continue
    if data.get("name") != d:
        errs.append(f"{p}: name '{data.get('name')}' != directory '{d}'")
    if not str(data.get("description") or "").strip():
        errs.append(f"{p}: missing/empty description")
    for key in ("allowed-tools", "hooks"):
        if key in data:
            v = data[key]
            if v is None or (isinstance(v, (list, dict, str)) and len(v) == 0):
                errs.append(f"{p}: '{key}' present but EMPTY")
for e in errs:
    print(f"error: {e}")
print(f"validated {len(files)} skills — {len(errs)} errors")
sys.exit(1 if errs else 0)
PY
