#!/bin/bash
# emit-one.sh <swift test file> <outdir>
f=$1; o=$2; n=$(echo "$f" | sed 's#.*/swift/test/##; s#[/.]#_#g')
SDK=$(xcrun --show-sdk-path)
extra=""
/usr/bin/grep -q "parse-stdlib" "$f" && extra="-parse-stdlib"
if perl -e 'alarm 120; exec @ARGV' xcrun swiftc -frontend -emit-sil -Onone -g -Xllvm -sil-print-debuginfo -parse-as-library $extra -module-name M -sdk $SDK "$f" -o "$o/sil/$n.sil" 2>/dev/null; then echo "ok $f"; else echo "fail $f"; fi
