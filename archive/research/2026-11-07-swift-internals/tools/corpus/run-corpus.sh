#!/bin/bash
# usage: run-corpus.sh <outdir> [--prove]
V="${V:-$PWD}"  # work dir; was the session scratch v/
SRC=$V/../swift-src/swift
BIN=$V/repo/.build/debug/corpus
OUT=$1; shift
mkdir -p $OUT; : > $OUT/results.jsonl; : > $OUT/crashes.txt
find $SRC/test/SIL $SRC/test/SILOptimizer -name '*.sil' | sort | while read f; do
  perl -e 'alarm 60; exec @ARGV' $BIN sil "$f" "$@" >> $OUT/results.jsonl 2>>$OUT/stderr.txt
  rc=$?
  if [ $rc -ne 0 ]; then echo "$rc $f" >> $OUT/crashes.txt; fi
done
