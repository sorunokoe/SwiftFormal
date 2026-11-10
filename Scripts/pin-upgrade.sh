#!/usr/bin/env bash
# Checks a compiler pin upgrade before the pin changes. Guide: docs/guides/pin-upgrade.md.
#
#   Scripts/pin-upgrade.sh [--cache DIR] [--diff-lines N] OLD_REF NEW_REF [CANDIDATE_DEVELOPER_DIR]
#
# OLD_REF and NEW_REF are swiftlang/swift tags, branches or commit SHAs (for example swift-6.4.0-RELEASE and
# swift-6.5-RELEASE). The script
#   1. resolves each ref to a commit SHA (git ls-remote) and downloads the compared compiler files for it from
#      raw.githubusercontent.com into the cache (default .build/pin-upgrade, or $PIN_UPGRADE_CACHE), once per SHA;
#   2. runs the static gates (Scripts/pin-upgrade/gates.py): vocabulary, printer tokens, visitor fingerprints;
#   3. prints the dynamic lanes to run with the candidate compiler (it does not run them);
#   4. prints the decision table.
# Exit status: 0 when no static gate touches the reader, 1 when one does, 2 on a usage or download error.
set -euo pipefail
cd "$(dirname "$0")/.."

usage() { sed -n '4,4p' "$0" | sed 's/^# *//' >&2; exit 2; }

cache="${PIN_UPGRADE_CACHE:-.build/pin-upgrade}"
diff_lines=30
while [ $# -gt 0 ]; do
  case "$1" in
    --cache) [ $# -ge 2 ] || usage; cache="$2"; shift 2 ;;
    --diff-lines) [ $# -ge 2 ] || usage; diff_lines="$2"; shift 2 ;;
    -h|--help) usage ;;
    --*) usage ;;
    *) break ;;
  esac
done
[ $# -ge 2 ] && [ $# -le 3 ] || usage
old_ref="$1"; new_ref="$2"; developer_dir="${3:-}"

repo_url="https://github.com/swiftlang/swift"
raw_url="https://raw.githubusercontent.com/swiftlang/swift"
files="include/swift/SIL/SILNodes.def include/swift/AST/Builtins.def lib/SIL/IR/SILPrinter.cpp
lib/SIL/Parser/ParseSIL.cpp lib/AST/ASTPrinter.cpp lib/AST/Builtins.cpp"

# A full 40-digit SHA is used as is; anything else is looked up as a tag, then as a branch (short SHAs are not).
resolve() {
  local ref="$1" refs sha
  if printf '%s' "$ref" | grep -Eq '^[0-9a-f]{40}$'; then printf '%s\n' "$ref"; return; fi
  if ! refs=$(git ls-remote "$repo_url" "refs/tags/$ref^{}" "refs/tags/$ref" "refs/heads/$ref"); then
    echo "pin-upgrade: cannot reach $repo_url (git ls-remote failed); pass full commit SHAs to use the cache offline" >&2
    exit 2
  fi
  sha=$(printf '%s\n' "$refs" | awk '
    /\^\{\}$/ { peeled = $1 } /refs\/tags\// && !/\^\{\}$/ { tag = $1 } /refs\/heads\// { head = $1 }
    END { print (peeled != "" ? peeled : (tag != "" ? tag : head)) }')
  if [ -z "$sha" ]; then echo "pin-upgrade: $ref is not a tag or branch of $repo_url" >&2; exit 2; fi
  printf '%s\n' "$sha"
}

fetch() {
  local sha="$1" dir="$cache/$1" f
  for f in $files; do
    [ -s "$dir/$f" ] && continue
    mkdir -p "$(dirname "$dir/$f")"
    if ! curl --fail --silent --show-error --location --retry 2 -o "$dir/$f.part" "$raw_url/$sha/$f"; then
      rm -f "$dir/$f.part"
      echo "pin-upgrade: could not download $f at $sha" >&2
      exit 2
    fi
    mv "$dir/$f.part" "$dir/$f"
  done
}

old_sha=$(resolve "$old_ref")
new_sha=$(resolve "$new_ref")
echo "== Step 1: compiler sources"
echo "  OLD $old_ref = $old_sha"
echo "  NEW $new_ref = $new_sha"
fetch "$old_sha"
fetch "$new_sha"
echo "  cached in $cache/<sha>/"
echo

echo "== Step 2: static gates"
rc=0
python3 -I Scripts/pin-upgrade/gates.py --old "$cache/$old_sha" --new "$cache/$new_sha" \
  --old-label "$old_ref" --new-label "$new_ref" --diff-lines "$diff_lines" --no-table || rc=$?
if [ "$rc" -ge 2 ]; then exit "$rc"; fi
echo

echo "== Step 3: dynamic lanes (run these yourself, with the candidate compiler)"
prefix=""
if [ -n "$developer_dir" ]; then
  prefix="DEVELOPER_DIR=$developer_dir "
  version=$(DEVELOPER_DIR="$developer_dir" xcrun swiftc --version 2>/dev/null | head -n 1 || true)
  echo "  candidate compiler: ${version:-(xcrun found no swiftc in $developer_dir)}"
else
  echo "  candidate compiler: the default xcrun swiftc (pass its DEVELOPER_DIR as the third argument to pick another)"
fi
cat <<EOF
  a. Add the candidate's \`${prefix}xcrun swiftc --version | head -n 1\` line to
     SILFrontendVersion.verifiedCompilers in Sources/SFSIL/ProofCacheVersions.swift (a local edit, not committed yet).
  b. ${prefix}Scripts/test-lane.sh oracle
  c. ${prefix}Scripts/test-lane.sh slow
  d. ${prefix}Scripts/check-golden.sh
  e. ${prefix}python3 Scripts/metrics.py
  Compare every verdict with the pinned compiler's run. Not built yet: the compiler-corpus lane (V3) and the
  constant-folder oracle (V5); until they exist, b to e are the whole dynamic check.
EOF
echo
echo "== Step 4: decision"
python3 -I Scripts/pin-upgrade/gates.py --table-only
if [ "$rc" -ne 0 ]; then
  echo "pin-upgrade: static gates flagged changes that touch the reader (exit 1). Review them before step 3."
else
  echo "pin-upgrade: static gates clean (exit 0)."
fi
exit "$rc"
