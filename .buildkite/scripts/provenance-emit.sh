#!/usr/bin/env bash
# provenance-emit — WAVE-26520 O1 wiring v1: emit the per-run provenance.json
# (SLSA-style, feeds WAVE-26504 Q4 attestation) and upload it as a BK artifact.
#
# QUEUE: fpc-isolated. This step receives NO secrets. The secret NAME below
# (GUARD_PRIVATE_REPOS) is a name-only claim about what the host injected
# into the guard-content-policy step — never a value. The vendored emitter
# enforces UPPER_SNAKE names and fails closed on anything value-shaped.
#
# PLACEMENT: final step behind its own `wait` barrier, so it runs only after
# every prior step passed. V1 emits green-build provenances only: a failed
# guard blocks this step by barrier semantics, so failure shapes cannot emit
# here (they stay covered by the O1 fixtures until a v2 API-driven emitter).
#
# HONESTY NOTES (v1, all reversible):
# - The manifest claims exit 0 for every step: this step runs only when all
#   of them passed (this pipeline has no conditional steps, so the list is
#   static).
# - Self (provenance-emit) is listed exit 0: any DELIVERED artifact implies
#   the emitter + upload both succeeded, so the step exited 0. Local-only
#   files from failed runs never leave the ephemeral agent.
# - base_rev is BUILDKITE_COMMIT (the built rev). The true fork-point base is
#   resolvable from pr.{base_repo,base_ref,number} in the artifact; resolving
#   it at emit time (fetch + merge-base) is deferred to v2 to keep this step
#   free of new network failure modes.
# - Upload uses a relative path from the repo root (documented
#   buildkite-agent behavior); the emitter itself runs with --no-upload.
set -euo pipefail
cd "$(dirname "$0")/../.."

PROV=".buildkite/provenance"
OUT="provenance.json"
INJECTED="guard-content-policy:GUARD_PRIVATE_REPOS"

command -v node >/dev/null 2>&1 || {
  echo "provenance-emit: node is required but missing — failing closed."
  exit 2
}
NODE_MAJOR="$(node -p 'process.versions.node.split(".")[0]')"
if [ "$NODE_MAJOR" -lt 18 ]; then
  echo "provenance-emit: node >= 18 required, found $(node --version) — failing closed."
  exit 2
fi
[ -f "$PROV/bin/emit-provenance.mjs" ] || {
  echo "provenance-emit: vendored emitter missing at $PROV — failing closed."
  exit 2
}

TMP="$(mktemp -d)"
STEPS="$TMP/steps.json"
GUARDS="$TMP/guards.json"
trap 'rm -rf "$TMP"' EXIT

cat >"$STEPS" <<'EOF'
[
  {"key": "foundation-secret-scan", "queue": "fpc-isolated", "command": ".buildkite/scripts/foundation-secret-scan.sh", "exit": 0},
  {"key": "foundation-file-size", "queue": "fpc-isolated", "command": ".buildkite/scripts/foundation-file-size.sh", "exit": 0},
  {"key": "foundation-skill-validate", "queue": "fpc-isolated", "command": ".buildkite/scripts/foundation-skill-validate.sh", "exit": 0},
  {"key": "foundation-verify-routes", "queue": "fpc-isolated", "command": ".buildkite/scripts/foundation-verify-routes.sh", "exit": 0},
  {"key": "provenance-emit", "queue": "fpc-isolated", "command": ".buildkite/scripts/provenance-emit.sh", "exit": 0}
]
EOF
cat >"$GUARDS" <<'EOF'
[
  {"key": "guard-gitleaks", "verdict": "pass", "detail": "exit 0 (build proceeded past wait barrier)"},
  {"key": "guard-content-policy", "verdict": "pass", "detail": "exit 0 (build proceeded past wait barrier)"}
]
EOF

: "${BUILDKITE_COMMIT:?provenance-emit: BUILDKITE_COMMIT is required}"
node "$PROV/bin/emit-provenance.mjs" \
  --repo-dir . \
  --steps "$STEPS" \
  --guards "$GUARDS" \
  --base-rev "$BUILDKITE_COMMIT" \
  --out "$OUT" \
  --injected "$INJECTED" \
  --no-upload

if [ "${BUILDKITE:-}" = "true" ]; then
  command -v buildkite-agent >/dev/null 2>&1 || {
    echo "provenance-emit: on BK but buildkite-agent missing — failing closed."
    exit 2
  }
  buildkite-agent artifact upload "$OUT"
else
  echo "provenance-emit: not on BK (BUILDKITE!=true) — upload skipped, artifact at $OUT"
fi
