#!/usr/bin/env python3
"""Ratchets (PC-5): a quality number may stay or improve, never get worse. Recorded in Scripts/baseline/quality.json.

    python3 Scripts/check-ratchet.py                          # static ratchets (cheap; part of the safety net and CI)
    python3 Scripts/check-ratchet.py --build-log LOG          # also: warnings in a `swift build` log must be 0
    python3 Scripts/check-ratchet.py --coverage FILE          # also: per-module coverage from Scripts/measure-coverage.py (by hand)
    python3 Scripts/check-ratchet.py --strict-memory-safety-log LOG   # also: -strict-memory-safety warnings per file (H7)
    python3 Scripts/check-ratchet.py --update [--coverage F] [--strict-memory-safety-log LOG]  # record today's numbers (only after an improvement)

What is checked:
  * Counts that must not go up: findings accepted by the SwiftLint baseline (in total and per rule), `try!` in Sources,
    mentions of `Unsafe` in Sources, TODO/FIXME markers. If one went DOWN, the file must be updated in the same change (`--update`).
  * Size of the trusted code (SFCheck, compiler pin, SIL semantic model): at most 10% over the recorded size (Scripts/measure-trust.py).
  * Warnings of `-strict-memory-safety` (SE-0458) per file of Sources/ and Plugins/, from a full build log of
    Scripts/strict-memory-safety.sh: no file may gain one, and a file that is not recorded may have none (plan item H7).
  * Coverage per module may not fall below the recorded value. The recorded value is the measured one minus a margin, so a
    timing-dependent line does not fail a build; the trusted modules therefore have a floor taken from their measurement, not a round number.
"""
import argparse
import collections
import json
import math
import pathlib
import re
import sys

sys.path.insert(0, str(pathlib.Path(__file__).resolve().parent))
import quality_metrics as qm  # noqa: E402

COVERAGE_MARGIN = 1.0  # percentage points kept below the measured value when it is recorded
TRUSTED_GROWTH_LIMIT_PERCENT = 10


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--update", action="store_true")
    ap.add_argument("--coverage", type=pathlib.Path)
    ap.add_argument("--build-log", type=pathlib.Path)
    ap.add_argument("--strict-memory-safety-log", type=pathlib.Path)
    args = ap.parse_args()

    counts = qm.lower_is_better()
    total, by_rule = qm.lint_findings()
    trusted = qm.trusted_lines()
    coverage = json.loads(args.coverage.read_text()) if args.coverage else None
    unsafe = strict_memory_safety_warnings(args.strict_memory_safety_log) if args.strict_memory_safety_log else None

    if args.update:
        old = qm.load() if qm.QUALITY.exists() else {}
        new = {
            "_note": "Ratchets (PC-5). Numbers may stay or improve. Update with `python3 Scripts/check-ratchet.py --update` in the same change that improves them.",
            "lower_is_better": counts,
            "swiftlint_baseline_by_rule": by_rule,
            "trusted_growth_limit_percent": TRUSTED_GROWTH_LIMIT_PERCENT,
            "trusted_lines": trusted,
            "coverage_percent_floor": old.get("coverage_percent_floor", {}),
            "strict_memory_safety_by_file": unsafe if unsafe is not None else old.get("strict_memory_safety_by_file", {}),
        }
        if coverage is not None:
            new["coverage_percent_floor"] = {m: math.floor((p - COVERAGE_MARGIN) * 10) / 10 for m, p in sorted(coverage.items())}
        qm.QUALITY.write_text(json.dumps(new, indent=2) + "\n")
        print(f"recorded {qm.QUALITY.relative_to(qm.ROOT)}")
        return 0

    q = qm.load()
    bad = []
    for name, now in counts.items():
        was = q["lower_is_better"].get(name)
        if was is None:
            bad.append(f"{name} is not recorded in quality.json")
        elif now > was:
            bad.append(f"{name} went up: {was} -> {now}")
        elif now < was:
            bad.append(f"{name} improved: {was} -> {now}. Record it with `python3 Scripts/check-ratchet.py --update` in the same change")
    for rule, now in by_rule.items():
        was = q["swiftlint_baseline_by_rule"].get(rule, 0)
        if now > was:
            bad.append(f"SwiftLint baseline has more `{rule}` findings than recorded: {was} -> {now}")
    bad += qm.trust_violations(q)
    if args.build_log is not None:
        # SwiftPM's "skipping cache due to an error" is about the machine (two fetches racing for the shared cache), not the code.
        warnings = sum(
            1 for line in args.build_log.read_text().splitlines() if "warning:" in line and "skipping cache due to an error" not in line
        )
        if warnings:
            bad.append(f"{warnings} compiler warnings in {args.build_log} (the ratchet is 0)")
    if unsafe is not None:
        recorded = q.get("strict_memory_safety_by_file", {})
        for file in sorted(set(recorded) | set(unsafe)):
            was, now = recorded.get(file, 0), unsafe.get(file, 0)
            if now > was:
                bad.append(f"-strict-memory-safety warnings in {file} went up: {was} -> {now} (mark nothing unsafe without need; see docs/TESTING.md)")
            elif now < was:
                bad.append(
                    f"-strict-memory-safety warnings in {file} fell: {was} -> {now}. Record it with "
                    "`Scripts/strict-memory-safety.sh --update` in the same change"
                )
    if coverage is not None:
        for module, floor in q["coverage_percent_floor"].items():
            now = coverage.get(module)
            if now is None:
                bad.append(f"coverage of {module} was not measured")
            elif now < floor:
                bad.append(f"coverage of {module} fell below its floor: {now}% < {floor}%")
        for module in coverage:
            if module not in q["coverage_percent_floor"]:
                bad.append(f"coverage of {module} is measured but has no floor in quality.json (`--update --coverage FILE`)")

    if bad:
        print("\n".join(bad))
        return 1
    print("ratchets ok")
    return 0


WARNING = re.compile(r"^(/\S+?):(\d+):(\d+): warning: (.*)$")
ESCAPES = re.compile(r"\x1b\[[0-9;]*m|\x1b\]8;;[^\x1b]*\x1b\\")


def strict_memory_safety_warnings(log: pathlib.Path) -> dict[str, int]:
    """Distinct strict-memory-safety warnings per file of this repository's Sources/ and Plugins/ in a build log."""
    root = str(qm.ROOT) + "/"
    seen = set()
    for raw in log.read_text(errors="replace").splitlines():
        line = ESCAPES.sub("", raw)
        m = WARNING.match(line)
        if not m or not m.group(1).startswith(root):
            continue
        if "strict-memory-safety" not in raw and "StrictMemorySafety" not in raw:
            continue
        file = m.group(1)[len(root):]
        if file.startswith(("Sources/", "Plugins/")):
            seen.add((file, m.group(2), m.group(3), ESCAPES.sub("", m.group(4)).split(" [#")[0]))
    return dict(sorted(collections.Counter(file for file, *_ in seen).items()))


if __name__ == "__main__":
    sys.exit(main())
