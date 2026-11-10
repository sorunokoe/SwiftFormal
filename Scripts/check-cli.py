#!/usr/bin/env python3
"""The command-line contract of sfverify, sfgen and swiftformal: argv -> exit code, stdout and stderr.

    python3 Scripts/check-cli.py            compare with Scripts/baseline/cli.txt (exit 1 on any difference)
    python3 Scripts/check-cli.py --record   write the baseline (review the diff, then commit it)

Only cases that need no compiler run are listed: parsing, usage errors and exit codes. What a real scan prints is
guarded by Scripts/check-golden.sh. Output is recorded as its first line plus a hash of the whole text, so a change to
the help text shows up without the baseline holding all of it.
"""
import hashlib
import pathlib
import re
import subprocess
import sys

ROOT = pathlib.Path(__file__).resolve().parent.parent
BASELINE = ROOT / "Scripts/baseline/cli.txt"
MISSING = "Examples/does-not-exist.swift"

CASES = [
    ("sfverify", []),
    ("sfverify", ["--help"]),
    ("sfverify", ["-h"]),
    ("sfverify", ["--bogus"]),
    ("sfverify", ["--budget"]),
    ("sfverify", ["--budget", "many", MISSING]),
    ("sfverify", ["--budget", "0", MISSING]),
    ("sfverify", ["--budget", "-5", MISSING]),
    ("sfverify", ["--time-limit", "0", MISSING]),
    ("sfverify", ["--budget=many", MISSING]),
    ("sfverify", ["--budget=7", "--module=Kernels", MISSING]),
    ("sfverify", ["--stats", MISSING]),
    ("sfverify", ["--paranoid", MISSING]),
    ("sfverify", ["--stamp", "out.txt", MISSING]),
    ("sfverify", ["--json", "--xcode", MISSING]),
    ("sfverify", ["--build", "--package", "Examples/GatedPackage"]),
    ("sfverify", ["--package"]),
    ("sfverify", ["--config", "fast", MISSING]),
    ("sfverify", ["--config"]),
    ("sfverify", ["--cross-check", "gcc", MISSING]),
    ("sfverify", ["--format", "pdf", MISSING]),
    ("sfverify", ["--format"]),
    ("sfverify", ["--emit-tests"]),
    ("sfverify", ["--gate", "--confirm", MISSING]),
    ("sfverify", ["--format=sarif", "--json", MISSING]),
    ("sfverify", ["--package", "Examples/GatedPackage", "--target", "Bogus"]),
    ("sfverify", ["--build-log", "build.log"]),
    ("sfverify", ["--build", "--build-log", "build.log", "--target", "Kernels"]),
    ("sfverify", ["--cache-dir", "out", MISSING]),
    ("sfverify", ["--at", MISSING + ":3", MISSING]),
    ("sfverify", ["--at", "Package.swift", MISSING]),
    ("sfverify", ["--at=Package.swift:0", MISSING]),
    ("sfverify", ["--at", "Package.swift:3", "--gate", MISSING]),
    ("sfverify", ["--symbol", "f", "--only", "g", MISSING]),
    ("sfverify", ["--symbol", "f", "--at", "Package.swift:3", MISSING]),
    ("sfverify", ["--proof-cache", "out", "--no-proof-cache", MISSING]),
    ("sfverify", ["--proof-cache"]),
    ("sfverify", ["--gate", "--proof-cache=out", MISSING]),
    ("swiftformal", ["--help"]),
    ("swiftformal", ["check", "--format", "pdf"]),
    ("swiftformal", ["check", "--format"]),
    ("swiftformal", ["check", "--at", "Package.swift:3"]),
    ("swiftformal", ["check", "--at", "Package.swift"]),
    ("swiftformal", ["check", "--json", "--xcode", "--scan"]),
    ("swiftformal", ["check", "--no-proof-cache", "--proof-cache", "out", "--scan", "Examples/does-not-exist:X"]),
    ("swiftformal", ["check", "--jobs", "0", "--scan", "Examples/does-not-exist:X"]),
    ("swiftformal", ["check", "--jobs", "many"]),
    ("swiftformal", ["check", "--jobs"]),
    ("swiftformal", ["check", "--gate", "--help"]),
    ("swiftformal", ["check", "--gate", "--scan", "Examples/does-not-exist:X"]),
    ("swiftformal", ["check", "--gate", "--build-log", "build.log"]),
    ("swiftformal", ["check", "--gate", "--scratch-path", "out"]),
    ("swiftformal", ["check", "--gate", "--no-proof-cache", "--proof-cache", "out"]),
    ("swiftformal", ["check", "--gate", "--package", "Examples/does-not-exist"]),
    ("swiftformal", ["check", "--gate", "--no-opaque-calls", "--package", "Examples/does-not-exist"]),
    ("swiftformal", ["check", "--format", "sarif", "--json", "--scan", "Examples/does-not-exist:X"]),
    ("swiftformal", ["check", "--emit-tests"]),
    ("swiftformal", ["check", "--build-log", "build.log"]),
    ("swiftformal", ["check", "--cache-dir", "out", "--scan", "Examples/does-not-exist:X"]),
    ("swiftformal", ["verify", "--help"]),
    ("swiftformal", ["scan", "--help"]),
    ("swiftformal", ["gen"]),
    ("swiftformal", ["doctor", "--help"]),
    ("swiftformal", ["doctor", "--bogus"]),
    ("swiftformal", ["doctor", "--package"]),
    ("swiftformal", ["doctor", "--package", "Examples/does-not-exist"]),
    ("swiftformal", ["lsp", "--help"]),
    ("swiftformal", ["lsp", "--tcp"]),
    ("swiftformal", ["strings", "--help"]),
    ("sfgen", []),
    ("sfgen", ["frobnicate"]),
    ("sfgen", ["generate"]),
    ("sfgen", ["prune"]),
    ("sfgen", ["prune", "--generated", MISSING]),
    ("sfgen", ["domains"]),
    ("sfgen", ["domains", "--symbols", MISSING, "--out", MISSING]),
]


COMPILER_FAILED = "COMPILER FAILED"


def summary(text):
    text = text.replace(str(ROOT), "<ROOT>")
    # Elapsed time (`gate passed: … (3 ms)`) differs between runs; it is not part of the contract.
    text = re.sub(r"\(\d+ ms\)", "(N ms)", text)
    # What follows is the compiler's own wording, which differs between Swift versions (CI's runner is not the pinned one).
    if COMPILER_FAILED in text:
        text = text[: text.index(COMPILER_FAILED) + len(COMPILER_FAILED)]
    first = text.strip().splitlines()[0] if text.strip() else ""
    return f"{first[:100]!r} sha={hashlib.sha256(text.encode()).hexdigest()[:12]}"


def run_all():
    for product in ("sfverify", "sfgen", "swiftformal"):
        subprocess.run(["swift", "build", "--product", product], cwd=ROOT, check=True, capture_output=True)
    lines = []
    for product, argv in CASES:
        result = subprocess.run([str(ROOT / ".build/debug" / product), *argv], cwd=ROOT, capture_output=True, text=True, timeout=60)
        lines.append(f"{product} {' '.join(argv) or '(no arguments)'}")
        lines.append(f"  exit {result.returncode}")
        lines.append(f"  stdout {summary(result.stdout)}")
        lines.append(f"  stderr {summary(result.stderr)}")
    return "\n".join(lines) + "\n"


def main():
    measured = run_all()
    if "--record" in sys.argv:
        BASELINE.write_text(measured)
        print(f"recorded {BASELINE.relative_to(ROOT)}")
        return 0
    expected = BASELINE.read_text()
    if measured == expected:
        print(f"cli contract unchanged ({len(CASES)} cases)")
        return 0
    import difflib

    sys.stdout.writelines(difflib.unified_diff(expected.splitlines(True), measured.splitlines(True), "baseline", "measured"))
    print("cli contract changed: if intended, run python3 Scripts/check-cli.py --record and say why in the CHANGELOG")
    return 1


if __name__ == "__main__":
    sys.exit(main())
