"""Numbers that may only get better (PC-5, Phase 7B). Shared by Scripts/check-ratchet.py and Scripts/measure-trust.py.

The recorded values live in Scripts/baseline/quality.json. Everything here is cheap and static (no build, no test run).
"""
from __future__ import annotations

import collections
import json
import pathlib
import re

ROOT = pathlib.Path(__file__).resolve().parent.parent
QUALITY = ROOT / "Scripts" / "baseline" / "quality.json"
LINT_BASELINE = ROOT / "Scripts" / "baseline" / "swiftlint-baseline.json"

# The part a user has to trust (docs/TRUST.md). SFCheck is the independent proof checker; the others are listed so they stay visible.
TRUSTED = {
    "SFCheck": "Sources/SFCheck",
    "CompilerPin": "Sources/SFSIL/CompilerPin.swift",
    "SILSemanticModel": "Sources/SFSemantics",
}


def code_lines(path: pathlib.Path) -> int:
    """Non-blank lines that are not comments, for one file or every .swift file under a directory."""
    files = [path] if path.is_file() else sorted(path.rglob("*.swift"))
    total = 0
    for f in files:
        in_block = False
        for raw in f.read_text().splitlines():
            line = raw.strip()
            if in_block:
                if "*/" in line:
                    in_block = False
                    line = line.split("*/", 1)[1].strip()
                else:
                    continue
            if line.startswith("/*"):
                if "*/" not in line:
                    in_block = True
                continue
            if line and not line.startswith("//"):
                total += 1
    return total


def trusted_lines() -> dict[str, int]:
    return {name: code_lines(ROOT / rel) for name, rel in TRUSTED.items()}


def _swift_files(*dirs: str) -> list[pathlib.Path]:
    return [f for d in dirs for f in sorted((ROOT / d).rglob("*.swift"))]


def _count(pattern: str, *dirs: str, skip_comments: bool = False) -> int:
    rx = re.compile(pattern)
    n = 0
    for f in _swift_files(*dirs):
        for line in f.read_text().splitlines():
            if skip_comments and line.lstrip().startswith("//"):
                continue
            if rx.search(line):
                n += 1
    return n


def lint_findings() -> tuple[int, dict[str, int]]:
    """The number of findings the SwiftLint baseline accepts, in total and per rule."""
    entries = json.loads(LINT_BASELINE.read_text())
    by_rule = collections.Counter(e["violation"]["ruleIdentifier"] for e in entries)
    return len(entries), dict(sorted(by_rule.items()))


def lower_is_better() -> dict[str, int]:
    """Counts that must never go up."""
    total, _ = lint_findings()
    return {
        "swiftlint_baseline_findings": total,
        "try_bang_in_sources": _count(r"\btry!", "Sources", "Plugins", skip_comments=True),
        "unsafe_mentions_in_sources": _count(r"Unsafe", "Sources"),
        "todo_markers": _count(r"\b(?:TODO|FIXME|XXX)\b", "Sources", "Tests", "Plugins"),
    }


def load() -> dict:
    return json.loads(QUALITY.read_text())


def trust_violations(quality: dict) -> list[str]:
    """Trusted code may grow by at most `trusted_growth_limit_percent` over the recorded size without a new baseline and a TRUST.md note."""
    limit_pct = quality["trusted_growth_limit_percent"]
    bad = []
    for name, now in trusted_lines().items():
        base = quality["trusted_lines"].get(name)
        if base is None:
            bad.append(f"trusted piece {name} has no recorded size in Scripts/baseline/quality.json")
        elif now > base * (1 + limit_pct / 100):
            bad.append(
                f"{name} has {now} code lines, {limit_pct}% over the recorded {base}: "
                "justify it in docs/TRUST.md, then record the new size with `python3 Scripts/check-ratchet.py --update`"
            )
    return bad
