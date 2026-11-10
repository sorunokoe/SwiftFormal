"""What SwiftFormal's SIL reader depends on, read from its own Swift sources (never a hand-copied list).

Standard library only. Used by `gates.py`; see docs/guides/pin-upgrade.md.

`derive(reader_files, builtin_files, instruction_names, builtin_names)` returns:

- instructions: every string literal in the reader sources that is an instruction name of either compiler. The
  reader matches instructions by literal text (`case "apply":`, `line.hasPrefix("cond_br ")`, `last == "unreachable"`,
  `range(of: ") = begin_apply ")`, the `readOnly` set of SILClosures.swift), so the literals are the list. Intersecting
  with SILNodes.def drops literals that are not instructions ("Bool", "native"). A literal that names an instruction
  the reader rejects only makes the gate stricter.
- builtins: literals of the builtin files (S0.swift's `base` names) and quoted builtin names in the reader
  (`"\\"ptrtoint_Word\\""`), each mapped to the Builtins.def name it starts with.
- tokens: the attributes and markers the reader looks for: `@word` and `[word` inside literals, and word literals on a
  line that mentions `attributes` (`attributes.contains("static")`).
"""
from __future__ import annotations

import glob
import os
import re
from dataclasses import dataclass, field

IDENTIFIER = re.compile(r"[a-z][a-z0-9_]*")


@dataclass
class Literal:
    content: str  # escapes resolved; each interpolation `\(...)` becomes U+0000
    path: str
    line: int
    line_text: str


def swift_literals(path: str) -> list[Literal]:
    """The string literals of a Swift file, outside comments, including those nested in interpolations."""
    with open(path, encoding="utf-8") as f:
        text = f.read()
    lines = text.split("\n")
    out: list[Literal] = []
    n = len(text)

    def line_at(pos: int) -> int:
        return text.count("\n", 0, pos) + 1

    def string(i: int) -> int:
        """Lex a string literal starting at `i` (at `#`s or the quote). Returns the index after it."""
        start = i
        hashes = 0
        while text[i] == "#":
            hashes += 1
            i += 1
        multiline = text.startswith('"""', i)
        i += 3 if multiline else 1
        if multiline and i < n and text[i] == "\n":
            i += 1  # a multi-line string starts on the next line
        closing = ('"""' if multiline else '"') + "#" * hashes
        escape = "\\" + "#" * hashes
        content = []
        while i < n:
            if text.startswith(closing, i):
                i += len(closing)
                break
            if text.startswith(escape, i):
                j = i + len(escape)
                c = text[j] if j < n else ""
                if c == "(":
                    i = code(j + 1, ")")
                    content.append("\0")
                    continue
                content.append({"n": "\n", "t": "\t", "0": "\0", "r": "\r"}.get(c, c))
                i = j + 1
                continue
            content.append(text[i])
            i += 1
        number = line_at(start)
        out.append(Literal("".join(content), path, number, lines[number - 1]))
        return i

    def code(i: int, until: str | None) -> int:
        """Lex code from `i` until the unmatched `until` (or the end). Returns the index after it."""
        depth = 0
        while i < n:
            c = text[i]
            if text.startswith("//", i):
                j = text.find("\n", i)
                i = n if j < 0 else j
            elif text.startswith("/*", i):
                level, i = 1, i + 2
                while i < n and level:
                    if text.startswith("/*", i):
                        level, i = level + 1, i + 2
                    elif text.startswith("*/", i):
                        level, i = level - 1, i + 2
                    else:
                        i += 1
            elif c == '"' or (c == "#" and re.match(r'#+"', text[i:i + 8])):
                i = string(i)
            elif until and c == "(":
                depth, i = depth + 1, i + 1
            elif until and c == until:
                if depth == 0:
                    return i + 1
                depth, i = depth - 1, i + 1
            else:
                i += 1
        return i

    code(0, None)
    return out


def _files(paths: list[str]) -> list[str]:
    out = []
    for p in paths:
        out.extend(sorted(glob.glob(os.path.join(p, "*.swift"))) if os.path.isdir(p) else [p])
    return out


@dataclass
class ReaderVocabulary:
    instructions: dict[str, str] = field(default_factory=dict)  # name -> "file:line" of the first literal
    builtins: dict[str, str] = field(default_factory=dict)
    tokens: dict[str, str] = field(default_factory=dict)
    files: list[str] = field(default_factory=list)


def _where(lit: Literal, root: str) -> str:
    return f"{os.path.relpath(lit.path, root) if root else lit.path}:{lit.line}"


def derive(reader_paths: list[str], builtin_paths: list[str], instruction_names: set[str], builtin_names: set[str],
           root: str = "") -> ReaderVocabulary:
    vocabulary = ReaderVocabulary()
    reader_files, builtin_files = _files(reader_paths), _files(builtin_paths)
    vocabulary.files = [os.path.relpath(f, root) if root else f for f in reader_files + builtin_files]

    def add_builtin(candidate: str, lit: Literal) -> None:
        matches = [b for b in builtin_names if candidate == b or candidate.startswith(b + "_")]
        if matches:
            vocabulary.builtins.setdefault(max(matches, key=len), _where(lit, root))

    for path in reader_files:
        for lit in swift_literals(path):
            word = lit.content.strip()
            if word.startswith(") = "):
                word = word[len(") = "):].strip()  # `range(of: ") = begin_apply ")`
            if IDENTIFIER.fullmatch(word) and word in instruction_names:
                vocabulary.instructions.setdefault(word, _where(lit, root))
            quoted = re.match(r'"([A-Za-z_][A-Za-z0-9_]*)"', lit.content)
            if quoted:
                add_builtin(quoted.group(1), lit)
            for token in re.findall(r"(?:^|[^\w])([@\[][A-Za-z_][A-Za-z0-9_]*)", lit.content):
                vocabulary.tokens.setdefault(token[1:], _where(lit, root))
            if "attributes" in lit.line_text.lower() and re.fullmatch(r"[a-z_]+\s?", lit.content):
                vocabulary.tokens.setdefault(lit.content.strip(), _where(lit, root))
    for path in builtin_files:
        for lit in swift_literals(path):
            if re.fullmatch(r"[A-Za-z_][A-Za-z0-9_]*", lit.content):
                add_builtin(lit.content, lit)
    return vocabulary
