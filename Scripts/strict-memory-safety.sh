#!/usr/bin/env bash
# The strict-memory-safety lane (plan item H7, SE-0458): builds every target with `-strict-memory-safety` and checks the
# warnings per file of Sources/ and Plugins/ against Scripts/baseline/quality.json. The count may only fall.
# The package stays at tools-version 6.0 (`.strictMemorySafety()` needs 6.2), so the flag comes from the command line.
# The build starts from an empty scratch path: an incremental build does not print the warnings of files it skips.
#   Scripts/strict-memory-safety.sh            check (by hand)
#   Scripts/strict-memory-safety.sh --update   record today's counts, in the change that lowered them
set -euo pipefail
cd "$(dirname "$0")/.."
read -r major minor < <(swift --version 2>&1 | sed -nE 's/.*Swift version ([0-9]+)\.([0-9]+).*/\1 \2/p' | head -1) || true
if [ -z "${major:-}" ] || [ "$major" -lt 6 ] || { [ "$major" -eq 6 ] && [ "$minor" -lt 2 ]; }; then
  echo "strict-memory-safety lane skipped: -strict-memory-safety needs Swift 6.2 or newer ($(swift --version 2>&1 | head -1))"
  exit 0
fi
scratch=.build/strict-memory-safety
log=.build/strict-memory-safety.log
rm -rf "$scratch"
swift build -Xswiftc -strict-memory-safety --scratch-path "$scratch" >"$log" 2>&1 || { tail -30 "$log"; exit 1; }
python3 Scripts/check-ratchet.py --strict-memory-safety-log "$log" "$@"
