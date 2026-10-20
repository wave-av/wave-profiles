#!/usr/bin/env bats
# S1 (WAVE-26505): fork-refusal in guard-content-policy.sh.
# Negative: fork-shaped env exits 2 with the refusal message, before the
# script touches GUARD_PRIVATE_REPOS. Positive: same-repo / non-PR env
# proceeds past the fork check into the vendored scan.
#
# The positive control asserts "not refused + scan reached a verdict" rather
# than exit 0: in a linked git worktree the scan flags the worktree's own
# `.git` pointer file (environmental abs-user-path KIND hit — CI clones use
# a `.git` directory, which the scanner excludes). The unit under test here
# is the refusal block, not the vendored scanner's verdict on a given tree.
#
# Run: bats .buildkite/tests/guard-content-policy-fork.bats
# (no repo deps; needs bash + git checkout; rg optional — see below)

setup() {
  SCRIPT_DIR="$(cd "$(dirname "$BATS_TEST_FILENAME")" && pwd)"
  SCRIPT="$SCRIPT_DIR/../scripts/guard-content-policy.sh"
  PIPELINE_REPO="https://github.com/wave-av/wave-monitor"
  FORK_REPO="https://github.com/example-fork/wave-monitor"
  # Assembled from fragments so the full fixture token never occurs
  # literally in this tree — the private-repo rule must find zero matches.
  FIXTURE_REPOS="zz-fixture-$(printf '%s' 'no-such-repo-zz')"
}

@test "fork PR env refuses with exit 2 before touching secrets (injection unset)" {
  run env -u GUARD_PRIVATE_REPOS \
    "BUILDKITE_PULL_REQUEST_REPO=$FORK_REPO" \
    "BUILDKITE_REPO=$PIPELINE_REPO" \
    "$SCRIPT"
  [ "$status" -eq 2 ]
  [[ "$output" == *"refusing to run"* ]]
  [[ "$output" != *"GUARD_PRIVATE_REPOS"* ]]
}

@test "fork PR env refuses with exit 2 when injection is set" {
  run env "GUARD_PRIVATE_REPOS=$FIXTURE_REPOS" \
    "BUILDKITE_PULL_REQUEST_REPO=$FORK_REPO" \
    "BUILDKITE_REPO=$PIPELINE_REPO" \
    "$SCRIPT"
  [ "$status" -eq 2 ]
  [[ "$output" == *"refusing to run"* ]]
}

@test "same-repo PR env proceeds past the fork check (positive control)" {
  run env "GUARD_PRIVATE_REPOS=$FIXTURE_REPOS" \
    "BUILDKITE_PULL_REQUEST_REPO=$PIPELINE_REPO" \
    "BUILDKITE_REPO=$PIPELINE_REPO" \
    "$SCRIPT"
  [[ "$output" != *"refusing to run"* ]]
  if command -v rg >/dev/null 2>&1; then
    [[ "$output" == *"public-repo-guard:"* ]]
  else
    [ "$status" -eq 2 ]
    [[ "$output" == *"ripgrep (rg) is required"* ]]
  fi
}

@test "non-PR env (vars unset) proceeds past the fork check" {
  run env -u BUILDKITE_PULL_REQUEST_REPO -u BUILDKITE_REPO \
    "GUARD_PRIVATE_REPOS=$FIXTURE_REPOS" \
    "$SCRIPT"
  [[ "$output" != *"refusing to run"* ]]
  if command -v rg >/dev/null 2>&1; then
    [[ "$output" == *"public-repo-guard:"* ]]
  else
    [ "$status" -eq 2 ]
    [[ "$output" == *"ripgrep (rg) is required"* ]]
  fi
}
