#!/usr/bin/env python3
"""Fails if a target depends on a module it is not allowed to see.

The allowed edges are written once, in Scripts/sandboxes.py. A target that is not listed there fails.
"""
import json
import pathlib
import re
import subprocess
import sys

sys.path.insert(0, str(pathlib.Path(__file__).resolve().parent))
from sandboxes import CNF_MAX_LINES, SANDBOXES, tests_owner  # noqa: E402

ROOT = pathlib.Path(__file__).resolve().parent.parent
KIND_OF_TYPE = {"library": "library", "executable": "tool", "plugin": "plugin", "macro": "macro"}

pkg = json.loads(subprocess.check_output(["swift", "package", "describe", "--type", "json"], cwd=ROOT))
bad = []
seen = set()
claimed_tests = tests_owner()

for t in pkg["targets"]:
    name = t["name"]
    if t["type"] == "test":
        if name not in claimed_tests:
            bad.append(f"{name} is a test target that no sandbox in Scripts/sandboxes.py uses as its `tests`")
        continue
    seen.add(name)
    if name not in SANDBOXES:
        bad.append(f"{name} is not in Scripts/sandboxes.py: declare its layer")
        continue
    entry = SANDBOXES[name]
    if KIND_OF_TYPE.get(t["type"]) != entry.kind:
        bad.append(f'{name} is a {t["type"]} target but the registry says kind={entry.kind}')
    deps = set(t.get("target_dependencies") or [])
    extra = deps - entry.deps
    if extra:
        bad.append(f"{name} must not depend on {sorted(extra)}")

test_names = {t["name"] for t in pkg["targets"] if t["type"] == "test"}
for name, entry in SANDBOXES.items():
    if name not in seen:
        bad.append(f"{name} is in Scripts/sandboxes.py but not in Package.swift")
    for dep in entry.deps:
        if dep not in SANDBOXES:
            bad.append(f"{name} lists {dep} as a dependency, but {dep} is not in the registry")
    if entry.tests and entry.tests not in test_names:
        bad.append(f"{name} names test target {entry.tests}, which is not in Package.swift")
    for extra_target in entry.more_tests:
        if extra_target not in test_names:
            bad.append(f"{name} names test target {extra_target} in more_tests, which is not in Package.swift")

# Independence rule (docs/TRUST.md): the checker may only know the shared alphabet.
if "SFCheck" in SANDBOXES and SANDBOXES["SFCheck"].deps != {"SFCNF"}:
    bad.append("SFCheck may depend only on SFCNF (it must stay independent of the solver and the encoder)")

# The same rule at the source level (PC-6, Task Q.6): a target dependency can be added without an import, an import without a dependency.
CHECK_ALLOWED_IMPORTS = {"Foundation", "Swift", "SFCNF"}
IMPORT_RE = re.compile(r"^\s*(?:@\w+\s+)*(?:(?:public|package|internal|private|fileprivate)\s+)?import\s+(?:\w+\s+)?([A-Za-z_][\w]*)")
for f in sorted((ROOT / "Sources" / "SFCheck").rglob("*.swift")):
    for line in f.read_text().splitlines():
        m = IMPORT_RE.match(line)
        if m and m.group(1) not in CHECK_ALLOWED_IMPORTS:
            bad.append(f"{f.relative_to(ROOT)} imports {m.group(1)}: SFCheck may import only {sorted(CHECK_ALLOWED_IMPORTS)}")

# Every UNSAT answer that SFProve turns into a result must pass through an independent checker first (docs/TRUST.md).
# Counting is crude on purpose: each `case .unsat` needs its own `LRATChecker.check(` or `RUPChecker.check(` in the same file.
for f in sorted((ROOT / "Sources" / "SFProve").rglob("*.swift")):
    text = f.read_text()
    unsat_cases = len(re.findall(r"case\s+\.unsat\b", text))
    checker_calls = len(re.findall(r"\b(?:LRATChecker|RUPChecker)\.check\(", text))
    if unsat_cases > checker_calls:
        bad.append(f"{f.relative_to(ROOT)} has {unsat_cases} `case .unsat` but only {checker_calls} checker calls: an UNSAT answer must be checked by SFCheck")

# SFCNF is the shared alphabet. If it grows, redraw the boundary instead of letting it become a dumping ground.
cnf_lines = sum(
    1
    for f in (ROOT / "Sources" / "SFCNF").rglob("*.swift")
    for line in f.read_text().splitlines()
    if line.strip()
)
if cnf_lines > CNF_MAX_LINES:
    bad.append(f"SFCNF has {cnf_lines} non-blank lines (limit {CNF_MAX_LINES}): redraw the boundary")

if bad:
    print("\n".join(bad))
    sys.exit(1)
print("layering ok")
