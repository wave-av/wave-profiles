#!/usr/bin/env bash
# guard-gitleaks — GHA parity with public-repo-guard.yml steps "Install gitleaks
# (pinned + checksum-verified)" + "gitleaks (secret scan — published tree)".
#
# Version pin + SHA-256 copied from the GHA workflow; bump the two together.
# One deliberate change: GHA `sudo install`s to /usr/local/bin. FPC guests must
# not assume sudo, so the verified binary runs from a temp dir instead — same
# scan, smaller footprint.
set -euo pipefail
cd "$(dirname "$0")/../.."

GITLEAKS_VERSION="8.30.1"
GITLEAKS_SHA256="551f6fc83ea457d62a0d98237cbad105af8d557003051f41f3e7ca7b3f2470eb"

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
cd "$WORK"
curl -fsSL --proto '=https' --tlsv1.2 -o gitleaks.tar.gz \
  "https://github.com/gitleaks/gitleaks/releases/download/v${GITLEAKS_VERSION}/gitleaks_${GITLEAKS_VERSION}_linux_x64.tar.gz"
echo "${GITLEAKS_SHA256}  gitleaks.tar.gz" | sha256sum -c -
tar -xzf gitleaks.tar.gz gitleaks
./gitleaks version
cd - >/dev/null
"$WORK/gitleaks" detect --no-git --source . --config .gitleaks.toml --redact --no-banner --exit-code 1
