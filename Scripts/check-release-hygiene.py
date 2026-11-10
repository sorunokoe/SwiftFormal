#!/usr/bin/env python3
"""Release hygiene: the community files exist, and no private path, secret or personal email is checked in.

  python3 Scripts/check-release-hygiene.py

Checks:
  1. Required files exist: LICENSE, CONTRIBUTING.md, CODE_OF_CONDUCT.md, SECURITY.md, CHANGELOG.md, docs/RELEASING.md,
     the issue forms and the pull request template.
  2. No text file (outside archive/, build folders and .git) contains a home-directory path such as `/Users/<name>/`
     or `/home/<name>/`, a private key block, a well-known token prefix, or an email address other than a GitHub no-reply one.

`archive/` is frozen history and is not scanned (docs/decisions/0001-archive-policy.md). It runs in a second or two.
"""
from __future__ import annotations

import os
import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
SKIPPED_PARTS = {"archive", ".build", ".git", ".swiftpm", "node_modules", "__pycache__", ".artifacts", "DerivedData"}
MAX_BYTES = 2_000_000

REQUIRED = [
    "LICENSE",
    "CONTRIBUTING.md",
    "CODE_OF_CONDUCT.md",
    "SECURITY.md",
    "CHANGELOG.md",
    "docs/RELEASING.md",
    ".github/ISSUE_TEMPLATE/bug.yml",
    ".github/ISSUE_TEMPLATE/soundness.yml",
    ".github/ISSUE_TEMPLATE/feature.yml",
    ".github/ISSUE_TEMPLATE/config.yml",
    ".github/pull_request_template.md",
]

PATTERNS = {
    "private path": re.compile(r"/(?:Users|home)/[A-Za-z0-9._-]+/"),
    "private key": re.compile(r"-----BEGIN [A-Z ]*PRIVATE KEY-----"),
    "token": re.compile(r"\b(?:ghp|gho|ghs|github_pat)_[A-Za-z0-9_]{20,}|\bAKIA[0-9A-Z]{16}\b|\bsk-[A-Za-z0-9]{32,}"),
    "email": re.compile(r"[A-Za-z0-9._%+-]+@(?!users\.noreply\.github\.com\b)(?!noreply\.github\.com\b)[A-Za-z0-9-]+(?:\.[A-Za-z0-9-]+)*\.(?:com|org|net|io|dev|me)\b"),
}
# Not a person: the SSH form of a git URL.
EMAIL_ALLOWED = {"git@github.com"}


def text_files():
    for directory, subdirectories, names in os.walk(ROOT):
        subdirectories[:] = sorted(d for d in subdirectories if d not in SKIPPED_PARTS)
        # In a linked worktree `.git` is a file that holds an absolute path; it is git metadata like the `.git` folder.
        for name in sorted(n for n in names if n not in SKIPPED_PARTS):
            path = Path(directory) / name
            try:
                if path.is_symlink() or path.stat().st_size > MAX_BYTES:
                    continue
                yield path.relative_to(ROOT), path.read_text(encoding="utf-8")
            except (UnicodeDecodeError, OSError):
                continue


def main() -> int:
    problems = []
    for name in REQUIRED:
        if not (ROOT / name).is_file():
            problems.append(f"missing file: {name}")
    for relative, text in text_files():
        for number, line in enumerate(text.splitlines(), 1):
            for kind, pattern in PATTERNS.items():
                for match in pattern.finditer(line):
                    if kind == "email" and match.group(0) in EMAIL_ALLOWED:
                        continue
                    # Never print a possible secret: the location is enough.
                    shown = match.group(0) if kind == "private path" else "(hidden)"
                    problems.append(f"{relative}:{number}: {kind} {shown}")
    for problem in problems:
        print(problem)
    if problems:
        print(f"release hygiene: {len(problems)} problem(s)")
        return 1
    print("release hygiene ok")
    return 0


if __name__ == "__main__":
    sys.exit(main())
