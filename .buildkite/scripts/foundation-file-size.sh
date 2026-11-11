#!/usr/bin/env bash
# foundation-file-size — GHA parity with _checks.yml job `checks`, step
# "File-size gate". MAX=800 mirrors foundation-gate.yml `with: max_lines: 800`.
set -euo pipefail
cd "$(dirname "$0")/../.."

MAX=800
fail=0
while IFS= read -r f; do
  grep -qxF "$f" .github/.filesize-allowlist 2>/dev/null && continue   # justified exception
  n=$(wc -l < "$f")
  if [ "$n" -gt "$MAX" ]; then echo "$f has $n lines (> $MAX)"; fail=1; fi
done < <(git ls-files '*.ts' '*.tsx' '*.js' '*.py' | grep -vE '\.(types|d)\.ts$')
if [ "$fail" = 0 ]; then echo "file-size gate passed (all <= $MAX lines)"; fi
exit "$fail"
