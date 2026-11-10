#!/usr/bin/env bash
# Builds the prebuilt `swiftformal` command (plan item U14; it was `sfverify` for the removed gate plugin): a release
# build, packed as a SwiftPM artifact bundle (`swiftformal.artifactbundle.zip` with an `info.json`), with its SHA-256 checksum.
#
#   Scripts/release-artifactbundle.sh <version> [out-dir]      e.g. Scripts/release-artifactbundle.sh 0.1.0
#
# Nothing is published. The release workflow (.github/workflows/release.yml) runs this on a tag and keeps the zip as a
# workflow artifact; attaching it to a release is the owner's step (docs/RELEASING.md).
#
# Reproducible: the build runs in a scratch folder of its own with every source path mapped to /swiftformal, the zip
# has fixed file times and order, so the same commit and the same compiler give the same bytes. To check a published
# zip, run this script on the tagged commit with the pinned compiler and compare the printed SHA-256.
#
# ARCHS (default "arm64 x86_64") picks the architectures of the universal binary.
set -euo pipefail
cd "$(dirname "$0")/.."
version="${1:?usage: Scripts/release-artifactbundle.sh <version> [out-dir]}"
out="${2:-.build/artifactbundle}"
archs="${ARCHS:-arm64 x86_64}"
root="$(pwd -P)"
scratch="$root/.build/artifactbundle-build"

arch_flags=()
for arch in $archs; do arch_flags+=(--arch "$arch"); done
# swiftformal does not need sfgen, so the Generator trait (swift-syntax) stays out. The prefix maps take the checkout
# path out of the compiled code; the linker's `-S` leaves out the debug map (paths and times of this machine's object
# files, of no use to anyone else), and ZERO_AR_DATE=1 zeroes archive member times. Either would otherwise change the
# binary (and its UUID) with the folder or the time of the build.
export ZERO_AR_DATE=1
swift build -c release --product swiftformal --disable-default-traits --scratch-path "$scratch" "${arch_flags[@]}" \
  -Xswiftc -file-prefix-map -Xswiftc "$root=/swiftformal" \
  -Xswiftc -file-prefix-map -Xswiftc "$scratch=/swiftformal-build" \
  -Xcc "-ffile-prefix-map=$root=/swiftformal" \
  -Xlinker -S
binary="$(swift build -c release --product swiftformal --disable-default-traits --scratch-path "$scratch" "${arch_flags[@]}" --show-bin-path)/swiftformal"

# Only libraries every supported macOS has: /usr/lib and /System. A Swift 6.2+ compatibility library
# (libswiftCompatibilitySpan.dylib, part of the OS only from macOS 26) would keep it from starting on macOS 13 to 15.
# Library lines are indented; a universal binary also prints one "(architecture …)" header per slice.
linked="$(otool -L "$binary" | awk '/^[[:space:]]/ {print $1}')"
if printf '%s\n' "$linked" | grep -vE '^(/usr/lib/|/System/Library/)' | grep -q .; then
  echo "swiftformal links a library outside /usr/lib and /System:" >&2
  printf '%s\n' "$linked" >&2
  exit 1
fi
if printf '%s\n' "$linked" | grep -q CompatibilitySpan; then
  echo "swiftformal links libswiftCompatibilitySpan.dylib: it would not start on macOS 13 to 15" >&2
  exit 1
fi
# Not `strings | grep -q`: with pipefail, grep stopping early makes the pipeline fail and hides a hit.
if [ "$(strings -a "$binary" | grep -cF "$root" || true)" != 0 ]; then
  echo "the binary still contains the checkout path $root: the build is not reproducible" >&2
  exit 1
fi

triples=""
for arch in $archs; do triples+="${triples:+, }\"$arch-apple-macosx\""; done
stage="$(mktemp -d)"
trap 'rm -rf "$stage"' EXIT
bundle="$stage/swiftformal.artifactbundle"
mkdir -p "$bundle/swiftformal-$version-macos/bin"
cp "$binary" "$bundle/swiftformal-$version-macos/bin/swiftformal"
cp LICENSE "$bundle/LICENSE"
cat > "$bundle/info.json" <<EOF
{
  "schemaVersion": "1.0",
  "artifacts": {
    "swiftformal": {
      "version": "$version",
      "type": "executable",
      "variants": [
        { "path": "swiftformal-$version-macos/bin/swiftformal", "supportedTriples": [$triples] }
      ]
    }
  }
}
EOF
# Fixed times and a sorted file list, so the zip depends only on the files.
find "$bundle" -exec touch -h -t 200001010000 {} +
mkdir -p "$out"
zip_path="$(cd "$out" && pwd -P)/swiftformal.artifactbundle.zip"
rm -f "$zip_path"
(cd "$stage" && find swiftformal.artifactbundle | LC_ALL=C sort | zip -X -q "$zip_path" -@)

sha="$(shasum -a 256 "$zip_path" | awk '{print $1}')"
checksum="$(swift package compute-checksum "$zip_path")"
test "$sha" = "$checksum" || { echo "shasum and swift package compute-checksum disagree" >&2; exit 1; }
printf '%s  swiftformal.artifactbundle.zip\n' "$sha" > "$zip_path.sha256"
cat <<EOF
swiftformal $version: $zip_path
compiler: $(swift --version 2>&1 | head -1)
commit:   $(git rev-parse HEAD 2>/dev/null || echo "unknown (not a git checkout)")$(git diff --quiet HEAD -- Sources Package.swift Package.resolved 2>/dev/null || echo " (uncommitted changes, or no git)")
SHA-256:  $sha
To reproduce: check out that commit, use the same compiler, run
  ARCHS="$archs" Scripts/release-artifactbundle.sh $version
and compare the SHA-256.
EOF
