#!/usr/bin/env python3
"""Fails on broken relative links and heading anchors in the Markdown files, and on README snippets that are not copied from Examples/.

  python3 Scripts/check-links.py

Checked: every `[text](target)` and `[ref]: target` outside code. A target that is a path must exist; a `#anchor` must match a
heading of the file it points at (GitHub's way of making anchors). Web links (`http`, `https`, `mailto`) are not fetched.
Not checked: `archive/` (frozen history) and build folders.
Snippets: every ```swift block in README.md must appear, line for line (indentation and blank lines ignored), in a Swift file under Examples/.
A block that is not code from an example (the install line) is allowed when the line above it is `<!-- not from Examples -->`.
"""
from __future__ import annotations

import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
SKIPPED_PARTS = {"archive", ".build", ".git", ".swiftpm", "node_modules", "__pycache__"}

FENCE = re.compile(r"^\s*(```|~~~)")
INLINE_LINK = re.compile(r"(?<!\!)\[(?:[^\]\\]|\\.)*\]\(\s*(<[^>]*>|[^)\s]*)(?:\s+(?:\"[^\"]*\"|'[^']*'))?\s*\)")
IMAGE_LINK = re.compile(r"!\[(?:[^\]\\]|\\.)*\]\(\s*(<[^>]*>|[^)\s]*)(?:\s+(?:\"[^\"]*\"|'[^']*'))?\s*\)")
REFERENCE_DEFINITION = re.compile(r"^\s{0,3}\[[^\]]+\]:\s*(<[^>]*>|\S+)")
HEADING = re.compile(r"^\s{0,3}(#{1,6})\s+(.*?)\s*#*\s*$")
INLINE_CODE = re.compile(r"`+[^`]*`+")


def markdown_files() -> list[Path]:
    found = []
    for path in sorted(ROOT.rglob("*.md")):
        relative = path.relative_to(ROOT)
        if SKIPPED_PARTS & set(relative.parts):
            continue
        found.append(path)
    return found


def prose_lines(text: str):
    """Yields (line number, line) for lines outside fenced code, with inline code removed."""
    fence = None
    for number, line in enumerate(text.splitlines(), 1):
        match = FENCE.match(line)
        if match:
            if fence is None:
                fence = match.group(1)
            elif match.group(1) == fence:
                fence = None
            continue
        if fence is None:
            yield number, INLINE_CODE.sub("", line)


def slug(heading: str) -> str:
    """GitHub's anchor for a heading: markup removed, lower case, punctuation dropped, spaces to hyphens."""
    text = re.sub(r"!\[([^\]]*)\]\([^)]*\)", r"\1", heading)
    text = re.sub(r"\[([^\]]*)\]\([^)]*\)", r"\1", text)
    text = text.replace("`", "").replace("*", "").replace("<", "").replace(">", "")
    text = text.strip().lower()
    text = re.sub(r"[^\w\- ]", "", text)
    return text.replace(" ", "-")


_anchor_cache: dict[Path, set[str]] = {}


def anchors(path: Path) -> set[str]:
    if path not in _anchor_cache:
        found: set[str] = set()
        counts: dict[str, int] = {}
        fence = None
        for line in path.read_text(encoding="utf-8").splitlines():
            fenced = FENCE.match(line)
            if fenced:
                fence = None if fence == fenced.group(1) else (fence or fenced.group(1))
                continue
            match = None if fence else HEADING.match(line)
            if not match:
                continue
            base = slug(match.group(2))
            n = counts.get(base, 0)
            found.add(base if n == 0 else f"{base}-{n}")
            counts[base] = n + 1
        _anchor_cache[path] = found
    return _anchor_cache[path]


def targets(text: str):
    for number, line in prose_lines(text):
        for pattern in (INLINE_LINK, IMAGE_LINK):
            for match in pattern.finditer(line):
                yield number, match.group(1).strip("<>")
        match = REFERENCE_DEFINITION.match(line)
        if match:
            yield number, match.group(1).strip("<>")


def check_link(source: Path, target: str) -> str | None:
    if not target or re.match(r"^[a-zA-Z][a-zA-Z0-9+.-]*:", target):
        return None  # empty, or a web / mailto link
    path_part, _, anchor = target.partition("#")
    destination = source if path_part == "" else (source.parent / path_part.split("?")[0]).resolve()
    if path_part and not destination.exists():
        return f"missing file: {target}"
    if anchor and destination.suffix == ".md" and destination.is_file():
        if anchor.lower() not in anchors(destination):
            return f"no heading for anchor: {target}"
    return None


def check_snippets() -> list[str]:
    readme = ROOT / "README.md"
    sources = []
    for path in (ROOT / "Examples").rglob("*.swift"):
        if ".build" in path.relative_to(ROOT).parts:
            continue
        sources.append([line.strip() for line in path.read_text(encoding="utf-8").splitlines() if line.strip()])
    problems = []
    block: list[str] | None = None
    start = 0
    exempt = False
    previous = ""
    for number, line in enumerate(readme.read_text(encoding="utf-8").splitlines(), 1):
        if block is None:
            if line.strip() == "```swift":
                block, start, exempt = [], number, previous.strip() == "<!-- not from Examples -->"
            previous = line
        elif line.strip().startswith("```"):
            wanted = [item.strip() for item in block if item.strip()]
            window = len(wanted)
            if not exempt and not any(lines[i : i + window] == wanted for lines in sources for i in range(len(lines) - window + 1)):
                problems.append(f"README.md:{start}: the Swift snippet is not copied from a file under Examples/")
            block = None
        else:
            block.append(line)
    return problems


def main() -> int:
    problems = []
    files = markdown_files()
    for path in files:
        for number, target in targets(path.read_text(encoding="utf-8")):
            message = check_link(path, target)
            if message:
                problems.append(f"{path.relative_to(ROOT)}:{number}: {message}")
    problems += check_snippets()
    for problem in problems:
        print(problem)
    if problems:
        print(f"check-links: {len(problems)} problem(s) in {len(files)} Markdown files")
        return 1
    print(f"check-links: ok ({len(files)} Markdown files)")
    return 0


if __name__ == "__main__":
    sys.exit(main())
