#!/bin/bash
# Scaling curves (developer-only, docs/PERFORMANCE.md). Usage: Scripts/scaling.sh <out-dir> [baseline results.json]
# SCALING_MAX_POW=N caps every size at 2^N (Scripts/baseline/scaling-slopes.json uses 14).
# Builds SwiftFormalScaling under SWIFTFORMAL_BENCH into its own scratch path (the macOS 15 floor never touches .build),
# runs every group into <out-dir>/results.json, renders charts, and compares against a baseline when given (report only).
set -euo pipefail
ROOT=$(cd "$(dirname "$0")/.." && pwd)
OUT=$(mkdir -p "$1" && cd "$1" && pwd)
BASELINE=${2:-}
cd "$ROOT"
# The variable adds three pins to Package.resolved, and resolving again without it keeps them: put the file back.
RESOLVED=$(mktemp)
cp Package.resolved "$RESOLVED"
trap 'cp "$RESOLVED" Package.resolved; rm -f "$RESOLVED"' EXIT
FRAMEWORKS="$(xcrun --show-sdk-platform-path)/Developer/Library/Frameworks"  # SwiftFormalTesting links Testing.framework
SWIFTFORMAL_BENCH=1 swift build -c release --scratch-path .build/scaling --product SwiftFormalScaling \
    -Xswiftc -enable-testing -Xlinker -rpath -Xlinker "$FRAMEWORKS"
B=.build/scaling/release/SwiftFormalScaling
SIL="$OUT/sil"; mkdir -p "$SIL"
for ((k=4; k<=${SCALING_MAX_POW:-13} && k<=13; k++)); do n=$((1<<k))   # generated inputs for the SIL tasks
    python3 Benchmarks/Scaling/gen.py kernels $n > "$SIL/k$n.swift"; python3 Benchmarks/Scaling/gen.py chain $n > "$SIL/c$n.swift"
    for kind in k c; do xcrun swiftc -frontend -emit-sil -Onone -module-name K -g -Xllvm -sil-print-debuginfo -parse-as-library \
        -sdk "$(xcrun --show-sdk-path)" "$SIL/$kind$n.swift" -o "$SIL/$kind$n.sil"; done
done
SCALING_SIL_DIR="$SIL" BIN="$B" Benchmarks/Scaling/run-groups.sh "$OUT/results.json"
for group in 'Domain|sample|Pairwise' 'verify|partition|BehaviorLock' 'CNFBuilder|Solver' 'LRAT|RUP' 'SIL|SpecIndex|ProofCache|ProofDigest'; do
    "$B" render "$OUT/results.json" "$OUT/${group%%|*}.png" --filter "^($group)" --center-statistic minimum --top-statistic maximum
done
# Report only: the log-log slope per task, and a GitHub warning for every slope that rose against the committed one.
python3 Benchmarks/Scaling/analyze.py "$OUT/results.json" --json "$OUT/slopes.json" \
    --baseline Scripts/baseline/scaling-slopes.json | tee "$OUT/slopes.txt" | grep '^::warning::' || true
if [ -n "$BASELINE" ]; then
    "$B" results compare "$BASELINE" "$OUT/results.json" --output "$OUT/compare" --chart-cutoff 1.25 --list-cutoff 1.25 || true
fi
