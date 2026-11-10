#!/usr/bin/env python3
"""Every `public` declaration in a front-door module must have a doc comment directly above it."""
import pathlib
import re
import sys

FRONT_DOORS = ["SwiftFormal", "SwiftFormalTesting", "SFProve"]  # SFProve: re-exported by SwiftFormalTesting
decl = re.compile(r"^\s*(@[\w.]+(\(.*\))?\s+)*public\s+(?!import)")
missing = []
for module in FRONT_DOORS:
    for path in sorted(pathlib.Path("Sources", module).rglob("*.swift")):
        lines = path.read_text().splitlines()
        for i, line in enumerate(lines):
            if decl.match(line) and "override" not in line:
                j = i - 1
                while j >= 0:
                    if lines[j].strip().startswith("@"):
                        j -= 1
                    elif lines[j].strip() == ")":
                        # The end of an attribute written over several lines (`@available(\n …\n)`): skip to its `@`.
                        while j >= 0 and not lines[j].strip().startswith("@"):
                            j -= 1
                    else:
                        break
                if j < 0 or not lines[j].strip().startswith("///"):
                    missing.append(f"{path}:{i + 1}: {line.strip()[:80]}")
print("\n".join(missing) or "doc coverage ok")
sys.exit(1 if missing else 0)
