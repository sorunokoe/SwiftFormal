#!/usr/bin/env bash
# No baseline test may disappear. New tests are fine. Renames must be listed in Scripts/baseline/test-renames.tsv (old<TAB>new).
set -euo pipefail
cd "$(dirname "$0")/.."
now=$(swift test list 2>/dev/null | sed -E 's/^[^.]+\.//' | sort -u)
missing=$(comm -23 Scripts/baseline/test-inventory.txt <(printf '%s\n' "$now"))
if [ -f Scripts/baseline/test-renames.tsv ]; then
  while IFS=$'\t' read -r old new; do
    missing=$(printf '%s\n' "$missing" | grep -vxF "$old" || true)
  done < Scripts/baseline/test-renames.tsv
fi
if [ -n "$missing" ]; then echo "Tests missing since baseline:"; printf '%s\n' "$missing"; exit 1; fi
echo "test inventory ok ($(printf '%s\n' "$now" | wc -l | tr -d ' ') tests)"
