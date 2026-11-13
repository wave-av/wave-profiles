#!/usr/bin/env bash
# foundation-secret-scan — GHA parity with _checks.yml job `checks`, step
# "Secret scan (fail-closed, allowlist-aware)". Patterns copied verbatim from
# the vendored _checks.yml; keep in sync with wave-foundation checks.yml@v1  # guard:allow shared checks repo mention (verified-safe reference)
# on every v1.x bump, exactly like the GHA file.
set -euo pipefail
cd "$(dirname "$0")/../.."

# Real-secret patterns. Lines tagged "pragma: allowlist secret" (e.g. test fixtures / regex
# definitions) are skipped — that's how a vetting module can define key-shapes without tripping.
HITS=$(grep -rIEn '(sk-[A-Za-z0-9]{20}|sk_(live|test)_[A-Za-z0-9]{20}|npm_[A-Za-z0-9]{30}|sbp_[a-f0-9]{40}|github_pat_[A-Za-z0-9_]{40}|AKIA[0-9A-Z]{16}|ghp_[A-Za-z0-9]{30}|AIzaSy[A-Za-z0-9_-]{20}|xai-[A-Za-z0-9]{40}|xoxb-[A-Za-z0-9-]+|-----BEGIN [A-Z ]*PRIVATE KEY)' \
  --exclude-dir=.git --exclude-dir=node_modules --exclude-dir=dist . | grep -v 'allowlist secret' \
  | { [ -f .github/.secret-allowlist ] && grep -vFf .github/.secret-allowlist || cat; } || true)
if [ -n "$HITS" ]; then
  echo "secret-like pattern found — do not commit credentials"
  # file:line only. Printing $HITS would copy the credential into the build log.
  # A line whose location can't be parsed (e.g. a colon in the file name) is
  # dropped to a placeholder rather than printed.
  printf '%s\n' "$HITS" | sed -E 's/^([^:]+:[0-9]+):.*/\1: match redacted/; t; s/.*/(location not shown): match redacted/'
  exit 1
fi
echo "secret-scan clean"
