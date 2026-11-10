#!/bin/bash
f=$1; o=$2; n=$(echo "$f" | sed 's#.*/swift/test/##; s#[/.]#_#g')
SDK=$(xcrun --show-sdk-path); extra=""
/usr/bin/grep -q "parse-stdlib" "$f" && extra="-parse-stdlib"
perl -e 'alarm 120; exec @ARGV' xcrun swiftc -frontend -emit-ir -Onone -parse-as-library $extra -module-name M -sdk $SDK "$f" -o "$o/ir/$n.ll" 2>/dev/null
