#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
log=.build/sf-build.txt
mkdir -p .build
swift build 2>&1 | tee "$log" | tail -1
# SwiftPM's "skipping cache due to an error" is about the machine (two fetches racing for the shared cache), not the code.
test "$(grep 'warning:' "$log" | grep -vc 'skipping cache due to an error' || true)" = "0"
# Fast lane (Scripts/test-lane.sh, docs/decisions/0004-test-lanes.md). The slow and oracle lanes are not part of the safety net.
Scripts/test-lane.sh fast
Scripts/check-test-inventory.sh
Scripts/check-golden.sh
python3 Scripts/check-cli.py
python3 Scripts/check-portability.py
# The pin-upgrade gates (docs/guides/pin-upgrade.md) on their offline fixtures.
python3 Scripts/pin-upgrade/selftest.py
# Every mutant of the mutation lane still applies to today's sources (plan item V6; the lane itself runs by hand).
python3 Scripts/mutation-lane.py --check
# The standard-library code behind Scan's summaries is the reviewed one (plan item R6; skips on an unpinned compiler).
python3 Scripts/check-summary-pin.py
# Deterministic prover cost (conflicts, clauses) and the JSON schema (Phase 8, docs/PERFORMANCE.md).
python3 Scripts/metrics.py
# The API check costs about a minute, so it runs only when a module behind a public product (or a module whose
# public types those products expose) changed since this branch left main, committed, staged or untracked.
# SAFETY_NET_FULL=1 always runs it; CI always runs it.
api_paths=(Sources/SwiftFormal Sources/SwiftFormalTesting Sources/SwiftFormalMacros
  Sources/SFProve Sources/SFBV Sources/SFCNF)
api_base=$(git merge-base HEAD main 2>/dev/null || git rev-parse HEAD)
if [ "${SAFETY_NET_FULL:-0}" = 1 ] || ! git diff --quiet "$api_base" -- "${api_paths[@]}" \
  || [ -n "$(git ls-files --others --exclude-standard -- "${api_paths[@]}")" ]; then
  Scripts/check-api.sh
else
  echo "api check skipped: no public-API source changed since $(git rev-parse --short "$api_base") (SAFETY_NET_FULL=1 runs it; CI always does)"
fi
python3 Scripts/check-doc-coverage.py
python3 Scripts/check-layering.py
python3 Scripts/check-sandboxes.py
# Broken Markdown links and README snippets that are not copied from Examples/ (Phase 9). Scripts/check-examples.sh is CI only: it takes minutes on a clean checkout.
python3 Scripts/check-links.py
# Each README `swift build` line names one --product (SwiftPM builds only the last). check-examples.sh runs the lines.
python3 Scripts/check-readme-install.py
# Community files exist; no private path, token or personal email outside archive/ (Phase 10, docs/RELEASING.md).
python3 Scripts/check-release-hygiene.py
# Style and quality ratchets (Phase 7B). swift-format ships with the toolchain; SwiftLint is optional locally and required in CI.
swift format lint --strict --recursive Sources Tests Examples Benchmarks/Sources Benchmarks/Scaling Benchmarks/Package.swift Package.swift
if command -v swiftlint >/dev/null; then
  swiftlint lint --quiet --baseline Scripts/baseline/swiftlint-baseline.json --strict
else
  echo "swiftlint not installed: skipped (CI runs it; brew install swiftlint)"
fi
python3 Scripts/check-ratchet.py --build-log "$log"
echo "SAFETY NET GREEN"
