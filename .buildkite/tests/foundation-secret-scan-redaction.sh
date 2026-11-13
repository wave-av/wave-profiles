#!/usr/bin/env bash
# Runs the real foundation-secret-scan.sh against throwaway trees and checks
# that a hit fails closed (exit 1) and names file:line, but never prints the
# matched text. Run from the repo root: bash .buildkite/tests/foundation-secret-scan-redaction.sh
set -euo pipefail
root="$(cd "$(dirname "$0")/../.." && pwd)"
scan="$root/.buildkite/scripts/foundation-secret-scan.sh"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
fail=0

# Built at runtime so this file never matches the scan pattern itself.
marker="AKIA$(printf 'Q%.0s' {1..16})"

mktree() {
  local dir="$work/$1"
  mkdir -p "$dir/.buildkite/scripts"
  cp "$scan" "$dir/.buildkite/scripts/foundation-secret-scan.sh"
  printf '%s\n' "$dir"
}

# Sets $rc and $out for one scan of tree $1.
run() {
  rc=0
  out="$(bash "$1/.buildkite/scripts/foundation-secret-scan.sh" 2>&1)" || rc=$?
}

# 1. A hit fails closed, names file:line, and does not print the match.
dir="$(mktree hit)"
printf 'first line\nkey = %s trailing\n' "$marker" >"$dir/leak.txt"
run "$dir"
[ "$rc" = 1 ] || { echo "FAIL: hit exited $rc, want 1"; fail=1; }
printf '%s\n' "$out" | grep -q 'leak.txt:2' || { echo "FAIL: output does not name leak.txt:2"; fail=1; }
if printf '%s\n' "$out" | grep -qF "$marker"; then echo "FAIL: output printed the matched text"; fail=1; fi
if printf '%s\n' "$out" | grep -qF 'trailing'; then echo "FAIL: output printed the rest of the matched line"; fail=1; fi

# 2. A clean tree passes.
dir="$(mktree clean)"
printf 'nothing here\n' >"$dir/ok.txt"
run "$dir"
[ "$rc" = 0 ] || { echo "FAIL: clean tree exited $rc, want 0"; fail=1; }

# 3. A line tagged with the allowlist pragma is skipped.
dir="$(mktree pragma)"
printf 'fixture %s # pragma: allowlist secret\n' "$marker" >"$dir/fixture.txt"
run "$dir"
[ "$rc" = 0 ] || { echo "FAIL: pragma-tagged line exited $rc, want 0"; fail=1; }

# 4. A colon in the file name can't push the match into the output.
dir="$(mktree colon)"
printf 'key = %s trailing\n' "$marker" >"$dir/a:b.txt"
run "$dir"
[ "$rc" = 1 ] || { echo "FAIL: colon-name hit exited $rc, want 1"; fail=1; }
if printf '%s\n' "$out" | grep -qF "$marker"; then echo "FAIL: colon-name hit printed the matched text"; fail=1; fi

[ "$fail" -eq 0 ] || exit 1
echo "foundation-secret-scan redaction OK"
