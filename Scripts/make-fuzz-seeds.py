#!/usr/bin/env python3
"""Regenerates the SIL seeds of the parser fuzzer (Tests/SoundnessZooTests/FuzzSeeds, plan item V9).

    python3 Scripts/make-fuzz-seeds.py

Each seed is real `swiftc -frontend -emit-sil -Onone` output of this repository's own Swift sources (Examples/),
cut down to one or a few functions so that the fuzz loop stays fast: the module header and type declarations, the
chosen functions and every body they reach through `function_ref`, and the printed declarations of the other
callees. Full-line comments and the file-path mapping are dropped. No compiler test file is copied (owner decision:
no vendoring). Run it with the pinned compiler; review the diff like any other baseline.
"""
import pathlib
import re
import subprocess
import sys

ROOT = pathlib.Path(__file__).resolve().parent.parent
OUT = ROOT / "Tests/SoundnessZooTests/FuzzSeeds"

# (seed name, source file, module name, mangled-name fragments of the functions to keep)
SEEDS = [
    ("metrics-clamp", "Examples/Metrics/Kernels.swift", "Kernels", ["5clampys4Int8VAD_A2DtF", "13clamp_ensures"]),
    ("metrics-discount", "Examples/Metrics/Kernels.swift", "Kernels", ["8discountys5UInt8VAD_ADtF"]),
    ("metrics-popcount", "Examples/Metrics/Kernels.swift", "Kernels", ["9popcount8ys5UInt8VADF"]),
    ("metrics-mul32", "Examples/Metrics/Kernels.swift", "Kernels", ["13mulCommutes32", "21mulCommutes32_ensures"]),
    ("gated-cell-index", "Examples/GatedPackage/Sources/Kernels/Kernels.swift", "Kernels", ["9cellIndexys4Int8VAD_A3DtF"]),
    ("gated-percent", "Examples/GatedPackage/Sources/Kernels/Kernels.swift", "Kernels", ["7percentys6UInt16VAD_ADtF"]),
    ("shipping-label", "Examples/Walk/Sources/Shipping/Shipping.swift", "Shipping", ["5label3forSSAA5SpeedO_tF"]),
    ("shipping-equals", "Examples/Walk/Sources/Shipping/Shipping.swift", "Shipping", ["21__derived_enum_equals"]),
    ("shipping-all-cases", "Examples/Walk/Sources/Shipping/Shipping.swift", "Shipping", ["8allCasesSayACGvgZ"]),
]


def emit(source, module):
    sdk = subprocess.run(["xcrun", "--show-sdk-path"], capture_output=True, text=True, check=True).stdout.strip()
    result = subprocess.run(
        ["xcrun", "swiftc", "-frontend", "-emit-sil", "-Onone", "-parse-as-library", "-module-name", module,
         "-sdk", sdk, str(ROOT / source), "-o", "/dev/stdout"],
        capture_output=True, text=True, check=True)
    return result.stdout


def split(text):
    """(header lines, {symbol: body lines}, {symbol: declaration line})."""
    lines = text.split("\n")
    header, bodies, declarations = [], {}, {}
    i = 0
    while i < len(lines):
        line = lines[i]
        if line.startswith("sil ") and " @" in line:
            symbol = line.split(" @", 1)[1].split(" : ", 1)[0]
            if line.endswith("{"):
                j = i
                while not lines[j].startswith("}"):
                    j += 1
                bodies[symbol] = [l for l in lines[i:j + 1] if not l.lstrip().startswith("//")]
                bodies[symbol][-1] = "}"
                i = j + 1
                continue
            declarations[symbol] = line
        elif not bodies and not line.startswith("//"):
            header.append(line)
        i += 1
    return header, bodies, declarations


def seed(text, fragments):
    header, bodies, declarations = split(text)
    roots = [s for s in bodies if any(f in s for f in fragments)]
    if len(roots) < len(fragments):
        sys.exit(f"not every fragment of {fragments} matched a function: {roots}")
    kept, todo = [], list(roots)
    while todo:
        symbol = todo.pop(0)
        if symbol in kept or symbol not in bodies:
            continue
        kept.append(symbol)
        for line in bodies[symbol]:
            todo += re.findall(r"function_ref @(\S+) :", line)
    called = {s for symbol in kept for line in bodies[symbol] for s in re.findall(r"function_ref @(\S+) :", line)}
    out = [l for l in header]
    while out and out[-1] == "":
        out.pop()
    for symbol in kept:
        out += [""] + bodies[symbol]
    extra = [declarations[s] for s in sorted(called) if s not in kept and s in declarations]
    if extra:
        out += [""] + extra
    return "\n".join(out) + "\n"


def main():
    OUT.mkdir(parents=True, exist_ok=True)
    cache = {}
    for name, source, module, fragments in SEEDS:
        if (source, module) not in cache:
            cache[(source, module)] = emit(source, module)
        text = seed(cache[(source, module)], fragments)
        if "/Users/" in text or "/home/" in text:
            sys.exit(f"{name}: a home-directory path in the seed")
        (OUT / f"{name}.sil").write_text(text)
        print(f"{name}.sil: {len(text)} bytes")


if __name__ == "__main__":
    main()
