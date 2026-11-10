#!/usr/bin/env python3
"""Fails if the package stops being usable as a dependency on its declared platforms.

1. The manifest that a consumer sees has no `unsafeFlags`. SwiftPM refuses a dependency with unsafe flags, so the
   developer-only settings in Package.swift must stay behind an environment variable that is unset here.
2. No command-line tool links `libswiftCompatibilitySpan.dylib`. That library is part of the OS from macOS 26 on; a
   standalone tool that links it does not start on macOS 13 to 15 unless the dylib ships beside it. Since Swift 6.2
   the stdlib `Span` types and swift-collections 1.7 can pull it in (apple/swift-collections#732).
"""
import json
import os
import pathlib
import subprocess
import sys

ROOT = pathlib.Path(__file__).resolve().parent.parent
TOOLS = ("sfverify", "sfgen")
DEVELOPER_ONLY = ("SWIFTFORMAL_DEV_OPTIMIZE", "SWIFTFORMAL_DOCS", "SWIFTFORMAL_BENCH")


def main():
    bad = []
    environment = {k: v for k, v in os.environ.items() if k not in DEVELOPER_ONLY}
    manifest = subprocess.run(
        ["swift", "package", "dump-package"], cwd=ROOT, env=environment, check=True, capture_output=True, text=True
    ).stdout
    json.loads(manifest)
    if "unsafeFlags" in manifest:
        bad.append("the consumer manifest contains unsafeFlags: SwiftPM would refuse SwiftFormal as a dependency")

    for tool in TOOLS:
        subprocess.run(["swift", "build", "--product", tool], cwd=ROOT, check=True, capture_output=True)
        binary = ROOT / ".build/debug" / tool
        linked = subprocess.run(["otool", "-L", str(binary)], check=True, capture_output=True, text=True).stdout
        if "CompatibilitySpan" in linked:
            bad.append(f"{tool} links libswiftCompatibilitySpan.dylib: it would not start on macOS 13 to 15")

    for problem in bad:
        print(problem)
    if bad:
        return 1
    print(f"portability ok (no unsafeFlags for consumers; {', '.join(TOOLS)} link no compatibility Span library)")
    return 0


if __name__ == "__main__":
    sys.exit(main())
