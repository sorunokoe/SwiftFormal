#!/usr/bin/env python3
"""Checks the README's install lines: every `swift build` line in a ```sh block of README.md.

  python3 Scripts/check-readme-install.py         # fast: each line names at most one --product (safety net, CI links)
  python3 Scripts/check-readme-install.py --run   # also runs each line verbatim and checks the tools exist (CI examples)

`swift build --product` takes one product; given several, SwiftPM builds only the last and exits 0. So a line with two
`--product` flags fails here. `--run` first deletes each named tool from `.build/<config>/`, then runs every distinct line
with bash from the repository root, exactly as written, and fails unless each named tool was built again. It needs a
release build of the package (a few minutes on a clean checkout), so only Scripts/check-examples.sh runs it.
"""
from __future__ import annotations

import re
import shlex
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
FENCE = re.compile(r"^\s*```(\w*)\s*$")


def install_lines() -> list[tuple[int, str]]:
    """(line number, line) for each `swift build` line inside a ```sh block of README.md."""
    found = []
    language = None
    for number, line in enumerate((ROOT / "README.md").read_text(encoding="utf-8").splitlines(), 1):
        match = FENCE.match(line)
        if match:
            language = match.group(1) if language is None else None
            continue
        if language == "sh" and line.strip().startswith("swift build"):
            found.append((number, line.strip()))
    return found


def products(line: str) -> list[str]:
    words = shlex.split(line)
    return [words[i + 1] for i, word in enumerate(words[:-1]) if word == "--product"]


def configuration(line: str) -> str:
    words = shlex.split(line)
    for i, word in enumerate(words[:-1]):
        if word in ("-c", "--configuration"):
            return words[i + 1]
    return "debug"


def main() -> int:
    lines = install_lines()
    problems = [
        f"README.md:{number}: `swift build` names {len(products(line))} products; SwiftPM builds only the last. Use one --product per line."
        for number, line in lines
        if len(products(line)) > 1
    ]
    if not lines:
        problems.append("README.md: no `swift build` line in a ```sh block")
    if problems or "--run" not in sys.argv[1:]:
        for problem in problems:
            print(problem)
        print(f"check-readme-install: {'ok' if not problems else 'FAILED'} ({len(lines)} install lines)")
        return 1 if problems else 0

    tools = {(configuration(line), name) for _, line in lines for name in products(line)}
    for config, name in tools:
        (ROOT / ".build" / config / name).unlink(missing_ok=True)
    for line in dict.fromkeys(line for _, line in lines):
        print(f"== README: {line}", flush=True)
        subprocess.run(["bash", "-c", line], cwd=ROOT, check=True, stdin=subprocess.DEVNULL)
    missing = sorted(f".build/{config}/{name}" for config, name in tools if not (ROOT / ".build" / config / name).is_file())
    for path in missing:
        print(f"README install lines ran, but {path} was not built")
    print(f"check-readme-install --run: {'ok' if not missing else 'FAILED'} ({len(tools)} tools)")
    return 1 if missing else 0


if __name__ == "__main__":
    sys.exit(main())
