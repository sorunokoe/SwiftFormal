#!/bin/sh
# usage: diffstat.sh DIR -- per-step +/- line counts for the compared files (git diff --no-index --numstat)
DIR=$1; cd "$DIR/dl" || exit 1
set -- swift-6.0-RELEASE swift-6.1-RELEASE swift-6.2-RELEASE swift-6.3-RELEASE swift-6.4.0-RELEASE main
prev=""
for t in "$@"; do
  if [ -n "$prev" ]; then
    for f in include/swift/SIL/SILNodes.def include/swift/AST/Builtins.def lib/SIL/IR/SILPrinter.cpp lib/SIL/Parser/ParseSIL.cpp docs/SIL/Instructions.md; do
      [ -f "$prev/$f" ] && [ -f "$t/$f" ] || { echo "$prev..$t	-	-	$f (missing on one side)"; continue; }
      /usr/bin/git diff --no-index --numstat "$prev/$f" "$t/$f" | awk -v s="$prev..$t" -v f="$f" '{print s"\t+"$1"\t-"$2"\t"f} END{if(NR==0)print s"\t+0\t-0\t"f}'
    done
  fi
  prev=$t
done
