#!/usr/bin/env python3
"""S2 (WAVE-26506): R1 fixture-(f) style proof that a failing leak guard
blocks every secret-bearing step in .buildkite/pipeline.yml.

Checks (all must PASS, exit 0):
  1. pipeline.yml parses as YAML with a `steps:` list.
  2. The first two COMMAND steps are guard-gitleaks then guard-content-policy,
     with the expected key/command/queue/timeout (the S2 byte-identical move).
  3. Every secret-bearing step (agents.queue == fpc-isolated-secrets) has BOTH
     guards in its must-pass set under Buildkite wait/depends_on semantics.
  4. Failure simulation: a failing guard-gitleaks blocks guard-content-policy
     and all later steps; a failing guard-content-policy blocks
     governance-enforce and all later steps. Blocked sets are printed.
  5. Every command step's command is exactly one checked-in script path
     (the fpc-isolated no-command-eval convention in the pipeline header).

Run: python3 .buildkite/tests/pipeline-gating.py   (needs python3 + pyyaml)
"""
import sys
from pathlib import Path

import yaml

ROOT = Path(__file__).resolve().parent.parent.parent
PIPELINE = ROOT / ".buildkite" / "pipeline.yml"

SECRETS_QUEUE = "fpc-isolated-secrets"
GUARD_KEYS = ("guard-gitleaks", "guard-content-policy")

EXPECTED_GUARDS = (
    {
        "label": ":key: guard gitleaks",
        "key": "guard-gitleaks",
        "command": ".buildkite/scripts/guard-gitleaks.sh",
        "queue": "fpc-isolated",
        "timeout_in_minutes": 10,
    },
    {
        "label": ":clipboard: guard content-policy",
        "key": "guard-content-policy",
        "command": ".buildkite/scripts/guard-content-policy.sh",
        "queue": SECRETS_QUEUE,
        "timeout_in_minutes": 10,
    },
)

EXPECTED_RETRY = {
    "automatic": [
        {"exit_status": -1, "limit": 1},
        {"signal_reason": "agent_stop", "limit": 1},
    ],
    "manual": {"allowed": True, "permit_on_passed": False},
}

FAILURES = []


def check(name, cond, detail=""):
    print(("PASS" if cond else "FAIL") + f" {name}" + (f" — {detail}" if detail else ""))
    if not cond:
        FAILURES.append(name)


def is_wait(step):
    if step == "wait":
        return True
    return isinstance(step, dict) and "wait" in step


def depends_of(step):
    deps = step.get("depends_on", []) if isinstance(step, dict) else []
    if isinstance(deps, str):
        deps = [deps]
    return [d if isinstance(d, str) else d.get("step") for d in deps]


def main():
    doc = yaml.safe_load(PIPELINE.read_text())
    check("1 pipeline parses with steps list", isinstance(doc, dict) and isinstance(doc.get("steps"), list))
    if FAILURES:
        return 1
    steps = doc["steps"]

    commands = [s for s in steps if isinstance(s, dict) and "command" in s]

    # 2 — guards first, byte-identical fields.
    first_two = [c.get("key") for c in commands[:2]]
    check("2a guards are the first two command steps", tuple(first_two) == GUARD_KEYS, f"got {first_two}")
    for cmd, exp in zip(commands[:2], EXPECTED_GUARDS):
        for field in ("label", "key", "command", "timeout_in_minutes"):
            check(f"2b {exp['key']}.{field} identical", cmd.get(field) == exp[field],
                  f"got {cmd.get(field)!r}")
        check(f"2b {exp['key']}.queue identical", (cmd.get("agents") or {}).get("queue") == exp["queue"],
              f"got {(cmd.get('agents') or {}).get('queue')!r}")
        check(f"2c {exp['key']}.retry policy identical", cmd.get("retry") == EXPECTED_RETRY)

    # Key index for depends_on resolution.
    by_key = {c["key"]: c for c in commands if "key" in c}

    def must_pass(step):
        """Keys that must have PASSED for `step` to start: every command step
        in an earlier wait-segment (barrier semantics) plus transitive
        depends_on targets. Same-segment steps run CONCURRENTLY — listing
        order within a segment gates nothing."""
        must = set()
        seg = set()
        for s in steps:
            if is_wait(s):
                must |= seg
                seg = set()
                continue
            if not (isinstance(s, dict) and "command" in s):
                continue
            if s is step:
                break
            seg.add(s.get("key"))
        stack = [d for d in depends_of(step) if d in by_key]
        while stack:
            dep = by_key[stack.pop()]
            if dep.get("key") in must:
                continue
            must.add(dep.get("key"))
            stack.extend(d for d in depends_of(dep) if d in by_key)
        must.discard(None)
        must.discard(step.get("key"))
        return must

    # 3 — every secret-bearing step gated on BOTH guards.
    secret_steps = [c for c in commands if (c.get("agents") or {}).get("queue") == SECRETS_QUEUE]
    check("3a secret-bearing steps found", len(secret_steps) >= 1, f"got {len(secret_steps)}")
    for s in secret_steps:
        mp = must_pass(s)
        missing = [g for g in GUARD_KEYS if g != s.get("key") and g not in mp]
        check(f"3b {s.get('key')} gated on both guards", not missing,
              f"must-pass={sorted(mp)}" if not missing else f"missing {missing}")

    # 4 — failure simulation (fixture-f style): a step runs iff nothing in
    # its must-pass set failed (barrier semantics are already folded into
    # must_pass; allow_dependency_failure relaxes only the depends_on part).
    def barrier_must_pass(step):
        must, seg = set(), set()
        for s in steps:
            if is_wait(s):
                must |= seg
                seg = set()
                continue
            if not (isinstance(s, dict) and "command" in s):
                continue
            if s is step:
                return must
            seg.add(s.get("key"))
        return must

    def simulate(failed_key):
        """Return (ran, blocked) key lists if `failed_key` fails."""
        failed = {failed_key}
        ran, blocked = [], []
        for s in commands:
            key = s.get("key")
            if key == failed_key:
                ran.append(key)
                continue
            mp = must_pass(s)
            if s.get("allow_dependency_failure", False) is True:
                mp = barrier_must_pass(s)
            (blocked if (mp & failed) else ran).append(key)
        return ran, blocked

    for gkey in GUARD_KEYS:
        ran, blocked = simulate(gkey)
        leaked = [k for k in ran
                  if (by_key[k].get("agents") or {}).get("queue") == SECRETS_QUEUE
                  and k != gkey]
        check(f"4 failing {gkey} blocks every secret-bearing step", not leaked,
              f"blocked={blocked}" if not leaked else f"LEAKED={leaked}")
        print(f"    simulate {gkey}=fail: ran={ran} blocked={blocked}")

    # 5 — no-command-eval convention: one script path, no args.
    for c in commands:
        cmd = c.get("command", "")
        ok = isinstance(cmd, str) and cmd.startswith(".buildkite/scripts/") and " " not in cmd
        check(f"5 {c.get('key')} single script path", ok, f"got {cmd!r}")

    print("RESULT " + ("ALL PASS" if not FAILURES else f"{len(FAILURES)} FAILURES"))
    return 1 if FAILURES else 0


if __name__ == "__main__":
    sys.exit(main())
