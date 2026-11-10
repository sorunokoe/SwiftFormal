#!/usr/bin/env bash
# The test lanes of docs/decisions/0004-test-lanes.md. One definition, used by CI, the safety net and contributors.
#   Scripts/test-lane.sh fast     every commit: debug build, skips everything slow or spawning a compiler
#   Scripts/test-lane.sh slow     before a release: release build
#   Scripts/test-lane.sh oracle   before a release: release build, starts swiftc (skipped with a reason on an unpinned compiler)
# Any further arguments go to `swift test` (for example `--enable-code-coverage`, `-Xswiftc -sanitize=address`).
# `swift test` cannot select Swift Testing tags (no --skip-tag), so lanes are picked by test target and suite name.
# Release test builds need -enable-testing: without it, `@testable import` in the other test targets fails to build.
set -euo pipefail
cd "$(dirname "$0")/.."
slow_targets='SFBVTests|SFProveTests|SFSATTests|SFSILTests'
# A suite whose name ends in `SlowTests` (S0SlowTests, SelfVerificationSlowTests, ...) is slow wherever it lives.
slow_suites='SlowTests'
# Every test is Swift Testing, so the lanes skip the XCTest pass (one per bundle). An XCTest test would be skipped silently.
if grep -rlq '^import XCTest' Tests; then
  echo "XCTest tests found under Tests/ (the lanes pass --disable-xctest): port them to Swift Testing" >&2; exit 2
fi
case "${1:-}" in
  fast)   exec swift test --disable-xctest "${@:2}" --skip "SFOracleTests|$slow_suites|$slow_targets" ;;
  slow)   exec swift test --disable-xctest -c release -Xswiftc -enable-testing "${@:2}" --filter "$slow_suites|$slow_targets" ;;
  # The slow lane in a debug build with the engine modules optimized: seconds, not the release lane's long first
  # build, and the tests keep assertions. Its own build folder, because the flags differ. Not a replacement for the
  # release slow lane before a release.
  # It needs no sfgen, so it leaves out swift-syntax (`--disable-default-traits`; its own scratch path, so the
  # other builds keep their traits).
  slow-dev) SWIFTFORMAL_DEV_OPTIMIZE=1 exec swift test --disable-xctest --disable-default-traits --scratch-path .build/dev-optimize "${@:2}" --filter "$slow_suites|$slow_targets" ;;
  oracle) exec swift test --disable-xctest -c release -Xswiftc -enable-testing "${@:2}" --filter 'SFOracleTests' ;;
  *) echo "usage: Scripts/test-lane.sh fast|slow|slow-dev|oracle [extra swift test flags, e.g. --enable-code-coverage]" >&2; exit 2 ;;
esac
