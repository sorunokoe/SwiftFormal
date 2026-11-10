#!/bin/sh
# usage: fetch.sh DIR  -- downloads the compared files for each ref (pinned to commit SHAs) into DIR/dl/<label>/<path>
set -u
DIR=$1
REFS="swift-6.0-RELEASE=f79ab15f11ffea6cad859da22b17da6cd9252167 swift-6.1-RELEASE=197e7be596bee7c00c2ddf73ec636d4c8b5105a4 swift-6.2-RELEASE=1ff1cc1170617ab23ab74aa8b741c8daca1903f6 swift-6.3-RELEASE=aa782beb23b8bd83bd16fca831532a05dd6cea39 swift-6.4.0-RELEASE=b8189d766d86ad7fc8106787d6ce9e402f38dd72 main=9691209cd1612a7163f8f23327d021bd5a227898"
FILES="include/swift/SIL/SILNodes.def include/swift/AST/Builtins.def lib/SIL/IR/SILPrinter.cpp lib/SIL/Parser/ParseSIL.cpp lib/AST/Builtins.cpp lib/AST/ASTPrinter.cpp include/swift/AST/TypeAttr.def lib/SIL/IR/SILModule.cpp docs/SIL/Instructions.md docs/SIL.rst"
for r in $REFS; do
  label=${r%%=*}; sha=${r#*=}
  for f in $FILES; do
    out="$DIR/dl/$label/$f"; mkdir -p "$(dirname "$out")"
    code=$(curl -sS -L -o "$out" -w '%{http_code}' "https://raw.githubusercontent.com/swiftlang/swift/$sha/$f")
    if [ "$code" != 200 ]; then echo "MISS $label $f ($code)"; rm -f "$out"; else echo "OK   $label $f $(wc -l < "$out") lines"; fi
  done
done
