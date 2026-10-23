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
# Chunking (T1/WAVE-27030): the host secrets channel caps each value at 512B
# (golden image MAX_SECRET), so Doppler wave/bkjobs carries the list as
# GUARD_PRIVATE_REPOS_01.._06 and the allowlist grants all six to this step
# key. A full GUARD_PRIVATE_REPOS (GHA org var, per-build proof injection)
# takes precedence when set; otherwise all six chunks must be present — a
# missing chunk fails closed, never silently narrows the rule.
#
# GHA apt-installs ripgrep when missing; FPC guests must not assume sudo/apt,
# so a missing rg fails closed with a clear message instead.
set -euo pipefail
cd "$(dirname "$0")/../.."

_norm_repo() {
  # host/owner/name lowercase, no scheme/user/suffix (review findings: a raw
  # comparison false-refuses SSH-style pipeline URLs, but dropping the host
  # would collapse distinct SCM hosts into one identity). Anything without a
  # host/owner/name shape normalizes to EMPTY (not an identity): equally
  # malformed PR/pipeline values must refuse, never compare equal and bypass.
  printf '%s' "$1" | tr '[:upper:]' '[:lower:]' | sed -E -e 's#^(https?|ssh)://([^/@]+@)?([^/]+)/#\3/#' -e 's#^git@([^:]+):#\1/#' -e 's#/$##' -e 's#\.git$##' | awk -F/ 'NF >= 3 && $1 != "" && $2 != "" && $3 != "" { print }'
}

if [ -n "${BUILDKITE_PULL_REQUEST_REPO:-}" ]; then
  _head="$(_norm_repo "$BUILDKITE_PULL_REQUEST_REPO")"
  _pipe="$(_norm_repo "${BUILDKITE_REPO:-}")"
  if [ -z "$_head" ] || [ -z "$_pipe" ] || [ "$_head" != "$_pipe" ]; then
    # Log NORMALIZED forms: raw URLs can embed userinfo credentials.
    echo "fork PR detected (head ${_head:-<unparseable>} != pipeline ${_pipe:-<unparseable>}) — refusing to run with host-injected credentials."
    echo "Host must run the trusted base-revision script or approve a trusted run; see README.md (Buildkite runbook)."
    exit 2
  fi
fi

command -v rg >/dev/null 2>&1 || {
  echo "ripgrep (rg) is required but not installed in the agent image — failing closed."
  exit 2
}
if [ -n "${GUARD_PRIVATE_REPOS+x}" ]; then
  # Set (even to empty): must be non-degenerate, takes precedence. An
  # explicitly empty/whitespace full value fails closed here — it must
  # never silently fall through to chunks (or disable the rule).
  _full_stripped="$(printf '%s' "$GUARD_PRIVATE_REPOS" | tr -d '[:space:]')"
  if [ -z "$_full_stripped" ]; then
    echo "GUARD_PRIVATE_REPOS is explicitly empty/whitespace — failing closed (an explicit empty value must never silently select chunks or disable the rule)."
    exit 2
  fi
else
  for _i in 01 02 03 04 05 06; do
    _v="GUARD_PRIVATE_REPOS_$_i"
    # Whitespace-only counts as missing: the policy splits on whitespace,
    # so a blank chunk would silently narrow the rule.
    if [ -z "$(printf '%s' "${!_v:-}" | tr -d '[:space:]')" ]; then
      echo "host must inject GUARD_PRIVATE_REPOS (full) or all of GUARD_PRIVATE_REPOS_01.._06 for step key guard-content-policy (missing $_v) — failing closed."
      exit 2
    fi
  done
  GUARD_PRIVATE_REPOS="$GUARD_PRIVATE_REPOS_01,$GUARD_PRIVATE_REPOS_02,$GUARD_PRIVATE_REPOS_03,$GUARD_PRIVATE_REPOS_04,$GUARD_PRIVATE_REPOS_05,$GUARD_PRIVATE_REPOS_06"
  export GUARD_PRIVATE_REPOS
fi
bash scripts/public-repo-guard/content-policy.sh .
