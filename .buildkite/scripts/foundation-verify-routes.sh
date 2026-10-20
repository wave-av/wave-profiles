#!/usr/bin/env bash
# foundation-verify-routes — GHA parity with _checks.yml job `verify-routes`
# (URL convention enforcement, docs/conventions/url-naming.md). No-op for repos
# with no wrangler.toml. Logic copied verbatim from the vendored _checks.yml.
set -euo pipefail
cd "$(dirname "$0")/../.."

# Reads only file paths from `git ls-files` (repo-controlled, trusted) and host strings
# extracted via a CONSTRAINED regex from wrangler.toml (PR-controlled). The regex
# `"[a-zA-Z0-9._-]+\.wave\.online[^"]*"` bounds matches between double-quotes; `cut -d/ -f1`
# then keeps only the hostname-shaped prefix. Hostnames cannot contain shell metacharacters
# under that character class, so the case-glob match is injection-safe.
fail=0
any=0
while IFS= read -r f; do
  any=1
  # Extract host portion (everything before the first /) from `pattern = "host/..."` lines.
  # Handles both inline-string `pattern = "..."` and `routes = ["a.wave.online/*", ...]`.
  while IFS= read -r h; do
    [ -z "$h" ] && continue
    case "$h" in
      *-edge.wave.online)
        echo "error($f): URL '$h' uses banned -edge suffix (see docs/conventions/url-naming.md)"; fail=1 ;;
      *.production.wave.online)
        echo "error($f): URL '$h' uses banned .production. (production is the default)"; fail=1 ;;
      wave-*.wave.online)
        echo "error($f): URL '$h' uses banned wave- prefix (redundant on wave.online)"; fail=1 ;;
      *-staging.wave.online)
        echo "error($f): URL '$h' uses banned -staging suffix (use <proto>.staging.wave.online sub-subdomain)"; fail=1 ;;
      *.staging.wave.online)
        echo "notice($f): staging URL $h OK" ;;
      *.dev.wave.online)
        echo "notice($f): dev URL $h OK" ;;
      *.wave.online)
        echo "notice($f): prod URL $h OK" ;;
      *)
        echo "warning($f): URL $h unrecognized — verify against docs/conventions/url-naming.md" ;;
    esac
  done < <(grep -oE '"[a-zA-Z0-9._-]+\.wave\.online[^"]*"' "$f" 2>/dev/null | tr -d '"' | cut -d/ -f1 | sort -u)
done < <(git ls-files '*wrangler.toml' 'wrangler*.toml')
if [ "$any" = 0 ]; then echo "no wrangler.toml — verify-routes is a no-op"; exit 0; fi
if [ "$fail" = 0 ]; then echo "verify-routes passed"; fi
exit "$fail"
