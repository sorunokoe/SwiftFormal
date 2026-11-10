#!/bin/bash
# Runs every scaling group into one results file. Usage: BIN=<SwiftFormalScaling> SCALING_SIL_DIR=<dir> run-groups.sh <results.json>
# Super-linear tasks carry their own `maxSize`, because --max-duration stops repetitions, not a run that is already long.
# SCALING_MAX_POW (default 20) caps every size at 2^N for a quick smoke run. About 35 minutes on an M4 Pro at the default.
set -u
B=${BIN:?set BIN to the SwiftFormalScaling binary}
OUT=$1
MAXP=${SCALING_MAX_POW:-20}
p2() { local s="" top=$(( $2 < MAXP ? $2 : MAXP )); for ((k=$1;k<=top;k++)); do s="$s $((1<<k))"; done; echo $s; }
COMMON="--cycles 3 --iterations 3 --min-duration 0.002 --max-duration 3 --disable-cutoff true --mode append"
run() { local filter=$1; shift; echo "== $filter"; "$B" run "$OUT" $COMMON --filter "$filter" --sizes "$@" 2>&1 | tail -1; }
run '^(Domain\.|verify|partition|BehaviorLock|CNFBuilder\.and|ProofDigest|LRATChecker (dense-ID variant )?unit chain|sample )' $(p2 4 20)
run '^Pairwise\.rows' $(p2 2 7)
run '^Domain\.combinations pairwise' $(p2 2 9)
run '^CNFBuilder\.add' $(p2 4 16)
run '^CNFBuilder\.(mul|unsignedDivide)' $(p2 2 9)
run '^Solver random 3-SAT ratio 3' $(p2 6 12)
run '^Solver random 3-SAT ratio 6' $(p2 5 12)
run '^Solver add-assoc' $(p2 3 9)
run '^Solver mul-comm' $(p2 2 6)
run '^(LRATChecker (dense-ID variant )?solver|RUPChecker|LRATProof)' $(p2 4 17)
run '^(SILText|SILModule|SpecIndex|ProofCache\.key)' $(p2 4 13)
run '^ProofCache store' $(p2 4 12)
