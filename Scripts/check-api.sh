#!/usr/bin/env bash
# Compares front-door APIs with a tag: the argument, or else the latest release tag (for example 0.1.0).
# Intended breaks go into Scripts/baseline/api-allowlist.txt (one regex per line).
set -uo pipefail
cd "$(dirname "$0")/.."
base="${1:-$(git describe --tags --abbrev=0 --match '[0-9]*' 2>/dev/null)}"
if [ -z "$base" ]; then echo "api check: no release tag yet, nothing to compare with"; exit 0; fi
# SFProve (a preview) is not compared: SwiftPM builds no baseline for a plain
# target here, so the digester fails. Check SFProve changes by hand in review.
out=$(swift package diagnose-api-breaking-changes "$base" \
  --products SwiftFormal SwiftFormalTesting 2>&1)
if ! printf '%s\n' "$out" | grep -q "breaking change"; then
  printf '%s\n' "$out" | tail -20
  echo "api check could not run"; exit 1
fi
if [ -f Scripts/baseline/api-allowlist.txt ]; then
  out=$(printf '%s\n' "$out" | grep -v -f Scripts/baseline/api-allowlist.txt || true)
fi
if printf '%s\n' "$out" | grep -E "💔|breaking" | grep -v "No breaking changes" | grep -q .; then
  printf '%s\n' "$out" | grep -E "💔|breaking" | grep -v "No breaking changes"
  echo "unlisted API break"; exit 1
fi
echo "api ok"
