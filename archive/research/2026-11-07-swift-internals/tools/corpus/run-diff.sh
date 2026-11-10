#!/bin/bash
V="${V:-$PWD}"  # work dir; was the session scratch v/
cd $V; : > out/emit/diff.jsonl; : > out/emit/diffcrash.txt
for s in out/emit/sil/*.sil; do b=$(basename $s .sil); [ -f out/emit/ir/$b.ll ] || continue
  perl -e 'alarm 180; exec @ARGV' repo/.build/release/corpusdiff $s out/emit/ir/$b.ll M >> out/emit/diff.jsonl 2>>out/emit/diffstderr.txt
  rc=$?; [ $rc -ne 0 ] && echo "$rc $s" >> out/emit/diffcrash.txt
done
echo done
