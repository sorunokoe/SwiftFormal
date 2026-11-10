#!/usr/bin/env bash
# Builds and runs every example. The README snippets are copied from these files, so an example that stops
# compiling (or stops proving) means the README is wrong. Each example is its own package with its own .build folder.
# Then runs the README's `swift build` install lines verbatim (a release build of the tools) and checks each tool exists.
# Several minutes on a clean checkout: CI runs it, the safety net does not.
set -euo pipefail
cd "$(dirname "$0")/.."

echo "== Examples/Walk: swift test"
swift test --package-path Examples/Walk 2>&1 | tail -3

echo "== Examples/Verify: swift test (the @Verify walk must prove)"
swift test --package-path Examples/Verify 2>&1 | tail -3

echo "== Examples/Prove: swift test (the symbolic proof, from SwiftFormalTesting, must be proved)"
swift test --package-path Examples/Prove 2>&1 | tail -3

echo "== Examples/GatedPackage: swiftformal check --gate (every @Verify function must be proved)"
swift build -c release --product swiftformal >/dev/null
.build/release/swiftformal check --gate --package "$PWD/Examples/GatedPackage" --target Kernels --force

echo "== Examples/GatedPackage: swiftformal check --gate --build-log (an app target's flow: the command from a build log)"
# Touch the source so the build compiles Kernels again and prints its command (-v); the gate builds nothing itself.
touch Examples/GatedPackage/Sources/Kernels/Kernels.swift
swift build --package-path "$PWD/Examples/GatedPackage" -v > .build/gated-build.log 2>&1
.build/release/swiftformal check --gate --build-log .build/gated-build.log --target Kernels --package "$PWD/Examples/GatedPackage"
echo "== Examples/GatedPackage: swiftformal check --build-log (every function of an app target, from the same log)"
.build/release/swiftformal check --build-log .build/gated-build.log --target Kernels --no-walks

echo "== README install lines: run verbatim, each named tool must be built"
python3 Scripts/check-readme-install.py --run

echo "== Examples/Verify: swiftformal check --gate (the README's quick start must prove the promise)"
.build/release/swiftformal check --gate --package "$PWD/Examples/Verify" --force

echo "EXAMPLES GREEN"
