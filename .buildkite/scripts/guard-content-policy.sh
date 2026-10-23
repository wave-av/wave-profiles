#!/usr/bin/env bash
# guard-content-policy — GHA parity with public-repo-guard.yml step "content
# policy (WAVE trade-secret / internal-leak gate)": runs the VENDORED
# scripts/public-repo-guard/content-policy.sh (never fetched at run time).
#
# GUARD_PRIVATE_REPOS arrives via host injection by (pipeline, step key) on the
# fpc-isolated-secrets queue — it is confidential config (private repo names),
# so it must NOT be inlined in pipeline.yml or any committed file. Unset/empty
# FAILS CLOSED here: a Buildkite config error must never silently disable the
# blocking private-repo rule. (Local callers run the vendored
# scripts/public-repo-guard/content-policy.sh directly, where the rule stays
# optional — see README.md.)
#
# GHA apt-installs ripgrep when missing; FPC guests must not assume sudo/apt,
# so a missing rg fails closed with a clear message instead.
set -euo pipefail
cd "$(dirname "$0")/../.."

if [ -n "${BUILDKITE_PULL_REQUEST_REPO:-}" ] && [ -n "${BUILDKITE_REPO:-}" ] \
   && [ "$BUILDKITE_PULL_REQUEST_REPO" != "$BUILDKITE_REPO" ]; then
  echo "fork PR detected (head $BUILDKITE_PULL_REQUEST_REPO != pipeline $BUILDKITE_REPO) — refusing to run with host-injected credentials."
  echo "Host must run the trusted base-revision script or approve a trusted run; see README.md (Buildkite runbook)."
  exit 2
fi

command -v rg >/dev/null 2>&1 || {
  echo "ripgrep (rg) is required but not installed in the agent image — failing closed."
  exit 2
}
# Chunking (T1/WAVE-27030): the host secrets channel caps each value at 512B
# (golden image MAX_SECRET), so Doppler wave/bkjobs carries the list as
# GUARD_PRIVATE_REPOS_01.._06 and the allowlist grants all six to this step
# key. A full GUARD_PRIVATE_REPOS takes precedence when set; otherwise all
# six chunks must be present - a missing chunk fails closed, never silently
# narrows the rule.
if [ -z "${GUARD_PRIVATE_REPOS:-}" ]; then
  for _i in 01 02 03 04 05 06; do
    _v="GUARD_PRIVATE_REPOS_$_i"
    if [ -z "${!_v:-}" ]; then
      echo "host must inject GUARD_PRIVATE_REPOS (full) or all of GUARD_PRIVATE_REPOS_01.._06 for step key guard-content-policy (missing $_v) - failing closed."
      exit 2
    fi
  done
  GUARD_PRIVATE_REPOS="$GUARD_PRIVATE_REPOS_01,$GUARD_PRIVATE_REPOS_02,$GUARD_PRIVATE_REPOS_03,$GUARD_PRIVATE_REPOS_04,$GUARD_PRIVATE_REPOS_05,$GUARD_PRIVATE_REPOS_06"
  export GUARD_PRIVATE_REPOS
fi
bash scripts/public-repo-guard/content-policy.sh .
