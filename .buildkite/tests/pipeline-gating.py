#!/usr/bin/env python3
"""S2 (WAVE-26506): R1 fixture-(f) style proof that a failing leak guard
blocks every secret-bearing step in .buildkite/pipeline.yml.

Checks (all must PASS, exit 0):
  1. pipeline.yml parses as YAML with a `steps:` list.
  1g. Guards carry no soft_fail/allow_failure/if/branches/skip; waits carry
      no continue_on_failure (WAVE-27331 gap 1).
  1h. No `group:` nesting — the walk is top-level only (gap 3).
  1i. No plural `commands:` lists — the walk keys on `command` and would
      skip them while BK runs every entry (review).
  2. The first two COMMAND steps are guard-gitleaks then guard-content-policy,
     with the expected key/command/queue/timeout (the S2 byte-identical move).
  2p. Probe set is empty or exactly the pinned absence-probe trio, preceding
      all gated steps, soft-fail-FLAG-only, commands pinned, never on the
      secrets queue except probe-absence-env (P4 PROMOTION.md).
  3. Every secret-bearing step (agents.queue == fpc-isolated-secrets) has BOTH  # guard:allow BK pipeline schema attribute, not a repo reference
     guards in its must-pass set under Buildkite wait/depends_on semantics.
     Waits with continue_on_failure:true are NOT barriers (gap 2).
  4. Failure simulation: a failing guard blocks every secret-bearing step;
     4b asserts the COMPLETE blocked set (every later step, gap 5).
  5. Every command step's command is an existing .sh/.mjs directly under
     .buildkite/scripts/ with no metacharacters (gap 4).
  6. simulate() fails loudly on unknown keys; when governance-enforce is
     present its failure must block every later step (gap 6).

Run: python3 .buildkite/tests/pipeline-gating.py [--pipeline PATH] [--selftest]
  --selftest runs inline positive+negative fixtures per new assertion (no
  network, tmp dirs only) instead of checking the real pipeline.
  (needs python3 + pyyaml)
"""
import sys
import tempfile
from pathlib import Path

import yaml

ROOT = Path(__file__).resolve().parent.parent.parent
DEFAULT_PIPELINE = ROOT / ".buildkite" / "pipeline.yml"

SECRETS_QUEUE = "fpc-isolated-secrets"
GUARD_KEYS = ("guard-gitleaks", "guard-content-policy")
# BK pipeline schema attributes that must never appear on a guard step — a
# guard that can soft-fail, skip, or narrow itself is not a gate.  # guard:allow BK pipeline schema attributes, not repo references
FORBIDDEN_GUARD_KEYS = ("soft_fail", "allow_failure", "if", "branches", "skip")
PINNED_PROBES = ("probe-absence-env", "probe-absence-fs", "probe-absence-log")
EXPECTED_PROBE_COMMANDS = {
    "probe-absence-env": ".buildkite/scripts/probe-absence-env.mjs",
    "probe-absence-fs": ".buildkite/scripts/probe-absence-fs.mjs",
    "probe-absence-log": ".buildkite/scripts/probe-absence-log.mjs",
}
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


def is_wait(step):
    if step == "wait":
        return True
    return isinstance(step, dict) and "wait" in step


def is_blocking_wait(step):
    """A bare `wait` (or `wait: ~`) is a barrier; a wait carrying
    continue_on_failure:true lets later steps run despite earlier failures,
    so it is NOT a barrier (WAVE-27331 gap 2)."""
    if not is_wait(step):
        return False
    if isinstance(step, dict):
        return step.get("continue_on_failure") is not True
    return True


def depends_of(step):
    deps = step.get("depends_on", []) if isinstance(step, dict) else []
    if isinstance(deps, str):
        deps = [deps]
    return [d if isinstance(d, str) else d.get("step") for d in deps]


def must_pass(steps, by_key, step, self_key):
    """Keys that must have PASSED for `step` to start: every command step
    in an earlier wait-segment (barrier semantics) plus transitive
    depends_on targets. Same-segment steps run CONCURRENTLY — listing
    order within a segment gates nothing."""
    must = set()
    seg = set()
    for s in steps:
        if is_wait(s):
            if is_blocking_wait(s):
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
    must.discard(self_key)
    return must


def barrier_must_pass(steps, step):
    must, seg = set(), set()
    for s in steps:
        if is_wait(s):
            if is_blocking_wait(s):
                must |= seg
            seg = set()
            continue
        if not (isinstance(s, dict) and "command" in s):
            continue
        if s is step:
            return must
        seg.add(s.get("key"))
    return must


def simulate(steps, commands, by_key, failed_key):
    """Return (ran, blocked) key lists if `failed_key` fails. Fails LOUDLY
    on an unknown key — a simulation over a missing step is vacuous and
    must never read as ALL PASS (WAVE-27331 gap 6)."""
    if failed_key not in by_key:
        raise KeyError(f"simulate: unknown step key {failed_key!r}")
    failed = {failed_key}
    ran, blocked = [], []
    for s in commands:
        key = s.get("key")
        if key == failed_key:
            ran.append(key)
            continue
        mp = must_pass(steps, by_key, s, key)
        if s.get("allow_dependency_failure", False) is True:
            mp = barrier_must_pass(steps, s)
        (blocked if (mp & failed) else ran).append(key)
    return ran, blocked


def evaluate(pipeline_path, root):
    """Run every check against one pipeline file. Returns a list of
    (name, passed, detail) rows; failures is [name for failing rows]."""
    import re

    rows = []

    def check(name, cond, detail=""):
        rows.append((name, bool(cond), detail))

    try:
        doc = yaml.safe_load(Path(pipeline_path).read_text())
    except Exception as exc:  # noqa: BLE001 — unreadable pipeline fails closed
        check("1 pipeline parses with steps list", False, str(exc))
        return rows
    check("1 pipeline parses with steps list",
          isinstance(doc, dict) and isinstance(doc.get("steps"), list))
    if not rows[-1][1]:
        return rows
    steps = doc["steps"]

    # 1h — no group nesting (the walk below is top-level only).
    grouped = [i for i, s in enumerate(steps)
               if isinstance(s, dict) and "group" in s]
    check("1h no group: nesting", not grouped, f"steps[{grouped}]" if grouped else "")

    # 1i — no plural `commands:` lists. A step with `commands:` (list) has no
    # `command` key, so the walk below would skip it entirely while BK runs
    # every entry — an ungated code-execution bypass. One script path per
    # step (the no-command-eval convention); multi-command steps refuse.
    listed = [i for i, s in enumerate(steps)
              if isinstance(s, dict) and "commands" in s]
    check("1i no commands: lists", not listed, f"steps[{listed}]" if listed else "")

    commands = [s for s in steps if isinstance(s, dict) and "command" in s]

    # 1g — guards carry no escape hatches; waits carry no continue_on_failure.
    by_key_all = {c.get("key"): c for c in commands if c.get("key")}
    for gkey in GUARD_KEYS:
        g = by_key_all.get(gkey)
        if g is None:
            check(f"1g {gkey} present", False, "missing guard step")
            continue
        bad = [k for k in FORBIDDEN_GUARD_KEYS if k in g]
        check(f"1g {gkey} carries no escape hatch", not bad, f"has {bad}" if bad else "")
    for i, s in enumerate(steps):
        if isinstance(s, dict) and "wait" in s and s.get("continue_on_failure") is True:
            check(f"1g steps[{i}] wait carries no continue_on_failure", False,
                  "non-blocking wait weakens every barrier")

    # P4 (PROMOTION.md): R2 absence probes (probe-*) run UNGATED by design —
    # zero injection by construction, so they are not secret-bearing even
    # when one asserts on the secrets queue. They must precede the guards.
    # Shapes without probes (trivial tier) carry an empty set — also valid.
    probes = [c for c in commands if (c.get("key") or "").startswith("probe-")]
    gated = [c for c in commands if not (c.get("key") or "").startswith("probe-")]
    probe_keys = sorted(c.get("key") for c in probes)
    check("2p probe set empty or exactly the pinned trio",
          probe_keys == [] or probe_keys == sorted(PINNED_PROBES),
          f"got {probe_keys}")
    if probes:
        check("2p probes precede all gated steps",
              all(commands.index(p) < commands.index(g) for p in probes for g in gated),
              f"got {[c.get('key') for c in commands[:4]]}")
        for p in probes:
            check(f"2p {p.get('key')} soft-fails FLAG only, never internal errors",
                  p.get("soft_fail") == [{"exit_status": 1}],
                  f"got {p.get('soft_fail')!r}")
            check(f"2p {p.get('key')} command pinned to vendored script",
                  p.get("command") == EXPECTED_PROBE_COMMANDS.get(p.get("key")),
                  f"got {p.get('command')!r}")
            check(f"2p {p.get('key')} never on secrets queue",
                  p.get("key") == "probe-absence-env" or (p.get("agents") or {}).get("queue") != SECRETS_QUEUE,  # guard:allow BK pipeline keyword, not a repo reference
                  "only probe-absence-env may ride the secrets queue (it asserts absence there); any other probe-* key would bypass gating")
            check(f"2p {p.get('key')} carries no depends_on", "depends_on" not in p,
                  "probe must run ungated")

    # 2 — guards first (among gated steps), byte-identical fields.
    first_two = [c.get("key") for c in gated[:2]]
    check("2a guards are the first two command steps", tuple(first_two) == GUARD_KEYS, f"got {first_two}")
    for cmd, exp in zip(gated[:2], EXPECTED_GUARDS):
        for field in ("label", "key", "command", "timeout_in_minutes"):
            check(f"2b {exp['key']}.{field} identical", cmd.get(field) == exp[field],
                  f"got {cmd.get(field)!r}")
        check(f"2b {exp['key']}.queue identical", (cmd.get("agents") or {}).get("queue") == exp["queue"],  # guard:allow BK pipeline keyword, not a repo reference
              f"got {(cmd.get('agents') or {}).get('queue')!r}")  # guard:allow BK pipeline keyword, not a repo reference
        check(f"2c {exp['key']}.retry policy identical", cmd.get("retry") == EXPECTED_RETRY)

    by_key = {c["key"]: c for c in commands if "key" in c}

    # 3 — every secret-bearing step gated on BOTH guards.
    secret_steps = [c for c in gated if (c.get("agents") or {}).get("queue") == SECRETS_QUEUE]  # guard:allow BK pipeline keyword, not a repo reference
    check("3a secret-bearing steps found", len(secret_steps) >= 1, f"got {len(secret_steps)}")
    for s in secret_steps:
        mp = must_pass(steps, by_key, s, s.get("key"))
        missing = [g for g in GUARD_KEYS if g != s.get("key") and g not in mp]
        check(f"3b {s.get('key')} gated on both guards", not missing,
              f"must-pass={sorted(mp)}" if not missing else f"missing {missing}")

    # 4 — failure simulation + COMPLETE blocked set (gap 5).
    for gkey in GUARD_KEYS:
        try:
            ran, blocked = simulate(steps, commands, by_key, gkey)
        except KeyError as exc:
            check(f"4 failing {gkey} simulated", False, str(exc))
            continue
        leaked = [k for k in ran
                  if (by_key[k].get("agents") or {}).get("queue") == SECRETS_QUEUE  # guard:allow BK pipeline keyword, not a repo reference
                  and k != gkey and not k.startswith("probe-")]
        check(f"4 failing {gkey} blocks every secret-bearing step", not leaked,
              f"blocked={blocked}" if not leaked else f"LEAKED={leaked}")
        order = [c.get("key") for c in commands]
        later = order[order.index(gkey) + 1:]
        escaped = [k for k in later if k in ran]
        check(f"4b failing {gkey} blocks EVERY later step", not escaped,
              f"blocked={len(blocked)}" if not escaped else f"ESCAPED={escaped}")
        rows.append((f"    simulate {gkey}=fail: ran={ran} blocked={blocked}", True, ""))

    # 5 — no-command-eval convention, hardened (gap 4): an existing
    # .sh/.mjs directly under .buildkite/scripts/, no metacharacters, and
    # the RESOLVED target must stay inside the scripts dir (is_file follows
    # symlinks — a bare existence check is bypassable).
    pat = re.compile(r"^\.buildkite/scripts/[A-Za-z0-9_][A-Za-z0-9_.-]*\.(sh|mjs)$")
    scripts_dir = (root / ".buildkite" / "scripts").resolve()
    for c in commands:
        cmd = c.get("command", "")
        shape_ok = isinstance(cmd, str) and bool(pat.match(cmd))
        target = (root / cmd).resolve() if shape_ok else None
        try:
            contained = target is not None and target.relative_to(scripts_dir) is not None
        except ValueError:
            contained = False
        exists_ok = shape_ok and (root / cmd).is_file()
        ok = shape_ok and exists_ok and contained
        detail = f"got {cmd!r}"
        if shape_ok and not exists_ok:
            detail += " (missing from checkout)"
        elif shape_ok and not contained:
            detail += " (resolves outside .buildkite/scripts/)"
        check(f"5 {c.get('key')} pinned existing script path", ok, detail)

    # 6 — governance-enforce failure gate (gap 6): simulate() already fails
    # loudly on unknown keys; when the step exists its failure must block
    # every later step (trivial-tier shapes without it note the skip).
    try:
        simulate(steps, commands, by_key, "definitely-not-a-step")
        check("6a simulate fails loudly on unknown keys", False, "no error raised")
    except KeyError:
        check("6a simulate fails loudly on unknown keys", True, "")
    if "governance-enforce" in by_key:
        _ran, blocked = simulate(steps, commands, by_key, "governance-enforce")
        order = [c.get("key") for c in commands]
        later = order[order.index("governance-enforce") + 1:]
        escaped = [k for k in later if k in _ran]
        check("6b failing governance-enforce blocks every later step", not escaped,
              f"blocked={len(blocked)}" if not escaped else f"ESCAPED={escaped}")
    else:
        rows.append(("6b governance-enforce absent (trivial-tier shape) — skipped", True, ""))

    return rows


def _write_tree(files):
    """Create a tmp repo root with .buildkite/scripts/<name> files."""
    root = Path(tempfile.mkdtemp(prefix="gating-"))
    scripts = root / ".buildkite" / "scripts"
    scripts.mkdir(parents=True)
    for name in files:
        (scripts / name).write_text("#!/bin/sh\n")
    return root


def _evaluate_yaml(doc_yaml, files):
    root = _write_tree(files)
    pipe = root / ".buildkite" / "pipeline.yml"
    pipe.write_text(doc_yaml)
    return evaluate(str(pipe), root)


def _failed(rows, prefix):
    return [n for (n, ok, _d) in rows if n.startswith(prefix) and not ok]


def selftest():
    """Positive+negative fixtures per new WAVE-27331 assertion. No network."""
    RETRY_YAML = ("retry: {automatic: [{exit_status: -1, limit: 1}, "
                  "{signal_reason: agent_stop, limit: 1}], "
                  "manual: {allowed: true, permit_on_passed: false}}")
    GUARD_A = ("  - label: ':key: guard gitleaks'\n    key: guard-gitleaks\n"
               "    command: .buildkite/scripts/guard-gitleaks.sh\n"
               "    agents: {queue: fpc-isolated}\n    timeout_in_minutes: 10\n"  # guard:allow BK agents/queue keywords in synthetic fixture, not a repo reference
               f"    {RETRY_YAML}\n")
    GUARD_B = ("  - label: ':clipboard: guard content-policy'\n"
               "    key: guard-content-policy\n"
               "    command: .buildkite/scripts/guard-content-policy.sh\n"
               "    agents: {queue: fpc-isolated-secrets}\n"  # guard:allow BK agents/queue keywords in synthetic fixture, not a repo reference
               "    timeout_in_minutes: 10\n"
               f"    {RETRY_YAML}\n")
    SECRET_JOB = ("  - label: secret job\n    key: secret-job\n"
                  "    command: .buildkite/scripts/job.sh\n"
                  "    agents: {queue: fpc-isolated-secrets}\n")  # guard:allow BK agents/queue keywords in synthetic fixture, not a repo reference
    FILES = ("guard-gitleaks.sh", "guard-content-policy.sh", "job.sh")
    VALID = ("steps:\n" + GUARD_A + "  - wait: ~\n" + GUARD_B
             + "  - wait: ~\n" + SECRET_JOB)

    fails = []

    def t(name, cond, detail=""):
        print(("PASS" if cond else "FAIL") + f" selftest {name}" + (f" — {detail}" if detail else ""))
        if not cond:
            fails.append(name)

    # Positive: minimal valid shape passes everything.
    rows = _evaluate_yaml(VALID, FILES)
    bad = [n for (n, ok, _d) in rows if not ok and not n.startswith("    simulate")]
    t("valid shape ALL PASS", not bad, f"{bad}" if bad else "")

    # Gap 1 negatives: escape hatches on guards / waits.
    rows = _evaluate_yaml(VALID.replace("key: guard-gitleaks\n",
                                        "key: guard-gitleaks\n    soft_fail: true\n"), FILES)
    t("gap1 guard soft_fail caught", bool(_failed(rows, "1g")), "")
    rows = _evaluate_yaml(VALID.replace("key: guard-content-policy\n",
                                        "key: guard-content-policy\n    branches: main\n"), FILES)
    t("gap1 guard branches caught", bool(_failed(rows, "1g")), "")
    rows = _evaluate_yaml(VALID.replace("  - wait: ~\n",
                                        "  - wait: ~\n    continue_on_failure: true\n", 1), FILES)
    t("gap1 wait continue_on_failure caught", bool(_failed(rows, "1g")), "")

    # Gap 2 engine: non-blocking wait is not a barrier (direct unit proof).
    doc = yaml.safe_load(VALID.replace("  - wait: ~\n",
                                       "  - wait: ~\n    continue_on_failure: true\n"))
    cmds = [s for s in doc["steps"] if isinstance(s, dict) and "command" in s]
    bk = {c["key"]: c for c in cmds}
    job = bk["secret-job"]
    mp = must_pass(doc["steps"], bk, job, "secret-job")
    t("gap2 continue_on_failure wait drops earlier segment", "guard-gitleaks" not in mp,
      f"must={sorted(mp)}")
    ran, _blocked = simulate(doc["steps"], cmds, bk, "guard-gitleaks")
    t("gap2 failure after soft wait still runs", "secret-job" in ran, f"ran={ran}")
    doc2 = yaml.safe_load(VALID)
    cmds2 = [s for s in doc2["steps"] if isinstance(s, dict) and "command" in s]
    bk2 = {c["key"]: c for c in cmds2}
    _ran2, blocked2 = simulate(doc2["steps"], cmds2, bk2, "guard-gitleaks")
    t("gap2 bare wait still barriers", "secret-job" in blocked2, "")

    # Gap 3 negative: group nesting fails.
    rows = _evaluate_yaml(VALID + "  - group: g\n    steps:\n" + SECRET_JOB.replace("key: secret-job", "key: nested"), FILES)
    t("gap3 group nesting caught", bool(_failed(rows, "1h")), "")
    rows = _evaluate_yaml(VALID + "  - label: sneaky\n    key: sneak\n    commands:\n      - .buildkite/scripts/job.sh\n      - curl evil.example\n", FILES)
    t("review commands: list caught", bool(_failed(rows, "1i")), "")

    # Gap 4 negatives: metachars / missing / subdir commands.
    rows = _evaluate_yaml(VALID.replace(".buildkite/scripts/job.sh",
                                        ".buildkite/scripts/job.sh;id"), FILES)
    t("gap4 shell metachars caught", bool(_failed(rows, "5 secret-job")), "")
    rows = _evaluate_yaml(VALID.replace(".buildkite/scripts/job.sh",
                                        ".buildkite/scripts/nope.sh"), FILES)
    t("gap4 missing script caught", bool(_failed(rows, "5 secret-job")), "")
    rows = _evaluate_yaml(VALID.replace(".buildkite/scripts/job.sh",
                                        ".buildkite/scripts/sub/job.sh"), FILES)
    t("gap4 subdir path caught", bool(_failed(rows, "5 secret-job")), "")

    # Review hardening: symlinked script escaping the scripts dir fails.
    root = _write_tree(FILES)
    outside = root / "outside.sh"
    outside.write_text("#!/bin/sh\n")
    link = root / ".buildkite" / "scripts" / "job.sh"
    link.unlink()
    link.symlink_to(outside)
    pipe = root / ".buildkite" / "pipeline.yml"
    pipe.write_text(VALID)
    rows = evaluate(str(pipe), root)
    t("review symlink escape caught", bool(_failed(rows, "5 secret-job")), "")

    # Review hardening: strict argv (typos fail loudly, never test default).
    t("review unknown flag rejected", main(["--nope"]) == 2, "")
    t("review value-less --pipeline rejected", main(["--pipeline"]) == 2, "")
    vroot = _write_tree(FILES)
    vpipe = vroot / ".buildkite" / "pipeline.yml"
    vpipe.write_text(VALID)
    import io as _io
    from contextlib import redirect_stdout as _rs
    with _rs(_io.StringIO()):
        rc = main(["--pipeline", str(vpipe)])
    t("review root defaults to pipeline checkout", rc == 0, f"rc={rc}")

    # Gap 5 engine: 4b is load-bearing — same-segment later step escapes.
    doc3 = yaml.safe_load("steps:\n" + GUARD_A.replace("    retry:", "    # retry:") +
                          "  - label: z\n    key: zed\n    command: .buildkite/scripts/job.sh\n")
    cmds3 = [s for s in doc3["steps"] if isinstance(s, dict) and "command" in s]
    bk3 = {c["key"]: c for c in cmds3}
    ran3, _b3 = simulate(doc3["steps"], cmds3, bk3, "guard-gitleaks")
    t("gap5 same-segment step escapes guard failure", "zed" in ran3, f"ran={ran3}")

    # Gap 6: unknown key loud; governance failure blocks later steps.
    try:
        simulate(doc2["steps"], cmds2, bk2, "nope-missing")
        t("gap6 unknown key loud", False, "no error")
    except KeyError:
        t("gap6 unknown key loud", True, "")
    gov = ("  - label: gov\n    key: governance-enforce\n"
           "    command: .buildkite/scripts/job.sh\n"
           "    agents: {queue: fpc-isolated-secrets}\n")  # guard:allow BK agents/queue keywords in synthetic fixture, not a repo reference
    evil = ("  - label: evil\n    key: evil-secret\n"
            "    command: .buildkite/scripts/job.sh\n"
            "    agents: {queue: fpc-isolated-secrets}\n")  # guard:allow BK agents/queue keywords in synthetic fixture, not a repo reference
    leak_pipe = ("steps:\n" + GUARD_A + "  - wait: ~\n" + GUARD_B
                 + "  - wait: ~\n" + gov + evil)
    rows = _evaluate_yaml(leak_pipe, FILES)
    t("gap6 governance leak caught", bool(_failed(rows, "6b")), "")
    t("gap6 leak shape keeps 3b green (isolation)", not _failed(rows, "3b"), "")

    print("SELFTEST " + ("ALL PASS" if not fails else f"{len(fails)} FAILURES: {fails}"))
    return 1 if fails else 0


def main(argv):
    if "--selftest" in argv:
        return selftest()
    pipeline = DEFAULT_PIPELINE
    root = None  # default: derived from the pipeline path (its own checkout)
    args = list(argv)
    while args:
        a = args.pop(0)
        if a in ("--pipeline", "--root"):
            if not args:
                print(f"usage: pipeline-gating.py [--pipeline PATH] [--root DIR] [--selftest]; {a} needs a value",
                      file=sys.stderr)
                return 2
            if a == "--pipeline":
                pipeline = Path(args.pop(0))
            else:
                root = Path(args.pop(0))
        elif a.startswith("--"):
            print(f"usage: pipeline-gating.py [--pipeline PATH] [--root DIR] [--selftest]; unknown option {a}",
                  file=sys.stderr)
            return 2
        else:
            print(f"usage: pipeline-gating.py [--pipeline PATH] [--root DIR] [--selftest]; unexpected argument {a}",
                  file=sys.stderr)
            return 2
    if root is None:
        # A pipeline at <root>/.buildkite/pipeline.yml belongs to <root>;
        # existence checks must run against the PIPELINE's checkout, not the
        # checker's (review: a typo'd --pipeline must not silently pass).
        root = pipeline.resolve().parent.parent
    rows = evaluate(str(pipeline), root)
    failures = [n for (n, ok, _d) in rows if not ok and not n.startswith("    simulate")]
    for name, ok, detail in rows:
        if name.startswith("    simulate"):
            print(name)
        else:
            print(("PASS" if ok else "FAIL") + f" {name}" + (f" — {detail}" if detail else ""))
    print("RESULT " + ("ALL PASS" if not failures else f"{len(failures)} FAILURES"))
    return 1 if failures else 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
