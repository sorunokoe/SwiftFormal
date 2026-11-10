#!/usr/bin/env bash
# Runs a test lane under a sanitizer (Task Q.6, Step 3). Run by hand before a release.
#   Scripts/sanitize.sh address|thread|undefined [fast|slow|oracle]     (default lane: fast)
# Each sanitizer builds into its own scratch path (.build/san-<name>), so the normal build stays warm.
# Plain `--sanitize=undefined` fails to link on the 6.4 toolchain (the swift-syntax C shims reference the UBSan runtime but it is not linked),
# so for `undefined` the script links the runtime dylib itself.
set -euo pipefail
cd "$(dirname "$0")/.."
sanitizer="${1:?usage: Scripts/sanitize.sh address|thread|undefined [fast|slow|oracle]}"
lane="${2:-fast}"
extra=()
if [ "$sanitizer" = undefined ]; then
  runtime="$(dirname "$(xcrun --find clang)")/../lib/clang"
  dylib="$(find "$runtime" -name 'libclang_rt.ubsan_osx_dynamic.dylib' | head -1)"
  [ -n "$dylib" ] || { echo "UBSan runtime not found under $runtime" >&2; exit 1; }
  extra=(-Xlinker "$dylib" -Xlinker -rpath -Xlinker "$(dirname "$dylib")")
fi
exec Scripts/test-lane.sh "$lane" --sanitize="$sanitizer" ${extra[@]+"${extra[@]}"} --scratch-path ".build/san-$sanitizer"
