"""Read the Swift compiler sources that decide how SIL is printed.

Standard library only. Used by `gates.py`; see docs/guides/pin-upgrade.md.

- `parse_sil_nodes(path)`: instruction textual names from SILNodes.def (`SINGLE_VALUE_INST(Id, name, ...)` and the
  other instruction macros), with the C++ class name (`Id`), the macro, the remaining arguments and the line.
- `parse_builtins(path)`: builtin names from Builtins.def (`BUILTIN_*(Id, "name", ...)`).
- `CxxFile(path)`: a C++ file with comments blanked out and string literals marked, so that brace matching and
  searches never look inside a comment or a string. `definitions(name)` finds function definitions,
  `fingerprint(name)` hashes them, `literals()` lists the string literals with their lines.
"""
from __future__ import annotations

import hashlib
import re
from dataclasses import dataclass

# ---------------------------------------------------------------------------------------------------------------------
# .def files

INST_MACROS = (
    r"(?:SINGLE_VALUE_INST|NON_VALUE_INST|TERMINATOR|MULTIPLE_VALUE_INST|FULL_INST|DYNAMICCAST_SINGLE_VALUE_INST"
    r"|DYNAMICCAST_NON_VALUE_INST|DYNAMICCAST_TERMINATOR|DYNAMICCAST_INST)"
)


def _read(path: str) -> str:
    with open(path, encoding="utf-8", errors="replace") as f:
        return f.read()


def _strip_comments_keep_lines(text: str) -> str:
    text = re.sub(r"/\*.*?\*/", lambda m: re.sub(r"[^\n]", " ", m.group(0)), text, flags=re.S)
    return re.sub(r"//[^\n]*", "", text)


def _define_spans(text: str) -> list[tuple[int, int]]:
    """Character spans of `#define` directives, with their backslash continuations."""
    return [(m.start(), m.end()) for m in re.finditer(r"^[ \t]*#[ \t]*define\b(?:[^\n]*\\\n)*[^\n]*", text, flags=re.M)]


def _in_spans(pos: int, spans: list[tuple[int, int]]) -> bool:
    return any(a <= pos < b for a, b in spans)


def _line_of(text: str, pos: int) -> int:
    return text.count("\n", 0, pos) + 1


def _macro_arguments(text: str, start: int) -> list[str]:
    """The arguments of a macro call whose `(` ends just before `start`, split at top-level commas."""
    depth, current, arguments, i = 1, [], [], start
    while i < len(text):
        c = text[i]
        if c == "(":
            depth += 1
        elif c == ")":
            depth -= 1
            if depth == 0:
                break
        if c == "," and depth == 1:
            arguments.append("".join(current))
            current = []
        else:
            current.append(c)
        i += 1
    arguments.append("".join(current))
    return [" ".join(a.replace("\\", " ").split()) for a in arguments]


def parse_sil_nodes(path: str) -> dict[str, dict]:
    """{textual name: {"id", "macro", "rest", "line"}} for every SIL instruction in SILNodes.def."""
    text = _strip_comments_keep_lines(_read(path))
    defines = _define_spans(text)
    out: dict[str, dict] = {}
    for m in re.finditer(r"\b(" + INST_MACROS + r")\s*\(", text):
        arguments = _macro_arguments(text, m.end())
        if len(arguments) < 2:
            continue
        ident, name = arguments[0], arguments[1]
        if name in ("NAME", "TEXTUALNAME", "TEXTUAL_NAME", "TextualName"):
            continue  # the macro plumbing itself
        if _in_spans(m.start(), defines) and "##" not in name:
            continue
        # Token-pasted names inside `#define ...REF_STORAGE` bodies become templates such as `load_<name>`.
        name = re.sub(r"\s*##\s*", "", name.replace("##name##", "<name>").replace("##name", "<name>").replace("name##", "<name>"))
        ident = re.sub(r"\s*##\s*", "", ident.replace("##Name##", "<Name>").replace("##Name", "<Name>").replace("Name##", "<Name>"))
        out[name] = {"id": ident, "macro": m.group(1), "rest": arguments[2:], "line": _line_of(text, m.start())}
    return out


def parse_sil_parents(path: str) -> dict[str, str]:
    """{class: parent class} for the abstract classes of SILNodes.def (`ABSTRACT_INST(RefCountingInst, SILInstruction)`).

    An instruction's own parent is the third argument of its macro. The printer's visitor falls back along this chain:
    `strong_retain` has no `visitStrongRetainInst` and is printed by `visitRefCountingInst`.
    """
    text = _strip_comments_keep_lines(_read(path))
    defines = _define_spans(text)
    out = {}
    for m in re.finditer(r"\bABSTRACT_[A-Z_]*\s*\(", text):
        if _in_spans(m.start(), defines):
            continue
        arguments = _macro_arguments(text, m.end())
        if len(arguments) >= 2 and arguments[0] not in ("ID",):
            out[arguments[0]] = arguments[-1] if arguments[-1] == "SILInstruction" else arguments[1]
    return out


def parse_builtins(path: str) -> dict[str, dict]:
    """{name: {"id", "macro", "rest", "line"}} for every builtin in Builtins.def."""
    text = _strip_comments_keep_lines(_read(path))
    defines = _define_spans(text)
    out: dict[str, dict] = {}
    for m in re.finditer(r"\b(BUILTIN[A-Z_]*)\s*\(", text):
        if _in_spans(m.start(), defines):
            continue
        line_start = text.rfind("\n", 0, m.start()) + 1
        if text[line_start : m.start()].strip().startswith("#"):
            continue  # #ifndef, #undef
        arguments = _macro_arguments(text, m.end())
        if len(arguments) < 2:
            continue
        # BUILTIN_BINARY_OPERATION_ALL stringifies an unquoted name.
        out[arguments[1].strip('"')] = {
            "id": arguments[0], "macro": m.group(1), "rest": arguments[2:], "line": _line_of(text, m.start()),
        }
    return out


# ---------------------------------------------------------------------------------------------------------------------
# C++ sources


@dataclass
class Definition:
    line: int  # first line of the definition (1-based)
    end_line: int
    text: str  # the raw source, signature to closing brace
    normalized: str  # comments removed, whitespace outside string literals removed


class CxxFile:
    """A C++ source file, lexed just enough to find function bodies and string literals.

    `code` is the file with every comment replaced by spaces (newlines kept, so offsets and lines do not move).
    `literal` marks the characters inside a string or character literal, quotes included.
    """

    def __init__(self, path: str) -> None:
        self.path = path
        self.raw = _read(path)
        self.code, self.literal, self.literal_spans = self._lex(self.raw)
        self._line_starts = [0] + [i + 1 for i, c in enumerate(self.raw) if c == "\n"]

    @staticmethod
    def _lex(raw: str) -> tuple[str, bytearray, list[tuple[int, int]]]:
        out = list(raw)
        literal = bytearray(len(raw))
        spans: list[tuple[int, int]] = []
        i, n = 0, len(raw)
        while i < n:
            c = raw[i]
            if c == "/" and i + 1 < n and raw[i + 1] == "/":
                j = raw.find("\n", i)
                j = n if j < 0 else j
                for k in range(i, j):
                    out[k] = " "
                i = j
            elif c == "/" and i + 1 < n and raw[i + 1] == "*":
                j = raw.find("*/", i + 2)
                j = n if j < 0 else j + 2
                for k in range(i, j):
                    if raw[k] != "\n":
                        out[k] = " "
                i = j
            elif c == "R" and raw.startswith('R"', i) and (i == 0 or not (raw[i - 1].isalnum() or raw[i - 1] == "_")):
                open_paren = raw.find("(", i + 2)
                delimiter = raw[i + 2 : open_paren]
                j = raw.find(")" + delimiter + '"', open_paren)
                j = n if j < 0 else j + len(delimiter) + 2
                for k in range(i, j):
                    literal[k] = 1
                spans.append((i, j))
                i = j
            elif c == '"' or (c == "'" and not (i > 0 and raw[i - 1].isalnum())):  # 1'000 is a digit separator
                j = i + 1
                while j < n and raw[j] != c and raw[j] != "\n":
                    j += 2 if raw[j] == "\\" else 1
                j = min(j + 1, n)
                for k in range(i, j):
                    literal[k] = 1
                if c == '"':
                    spans.append((i, j))
                i = j
            else:
                i += 1
        return "".join(out), literal, spans

    def line_of(self, pos: int) -> int:
        lo, hi = 0, len(self._line_starts) - 1
        while lo < hi:
            mid = (lo + hi + 1) // 2
            if self._line_starts[mid] <= pos:
                lo = mid
            else:
                hi = mid - 1
        return lo + 1

    def _matching(self, pos: int, open_char: str, close_char: str) -> int:
        """Index just past the bracket that closes the one at `pos`, or -1."""
        depth = 0
        for i in range(pos, len(self.code)):
            if self.literal[i]:
                continue
            c = self.code[i]
            if c == open_char:
                depth += 1
            elif c == close_char:
                depth -= 1
                if depth == 0:
                    return i + 1
        return -1

    def _body_start(self, after_parameters: int) -> int:
        """The `{` that opens a function body right after its parameter list (skipping `const`, `override`,
        `-> Type`, ...), or -1 when the parameter list belongs to a call or a declaration."""
        tail = re.match(r"(?:\s|const\b|override\b|final\b|noexcept\b|&|->\s*[\w:<>*&, ]+)*\{", self.code[after_parameters:])
        return after_parameters + tail.end() - 1 if tail else -1

    def definitions(self, name: str) -> list[Definition]:
        """Every definition of the function `name`.

        `name` is a plain or qualified name (`visitCondBranchInst`, `SILFunction::print`, `getBuiltinBaseName`), or,
        when it contains `(`, the literal text that starts the signature (`SILPrinter &operator<<(SILValuePrinterInfo i)`).
        """
        if "(" in name:
            pattern = re.compile(re.escape(name[: name.index("(")]) + r"\s*\(")
        else:
            pattern = re.compile(r"(?<![\w.>])" + re.escape(name) + r"\s*\(")
        found = []
        for m in pattern.finditer(self.code):
            if self.literal[m.start()]:
                continue
            if "(" in name and not self.code.startswith(name, m.start()):
                continue
            close = self._matching(m.end() - 1, "(", ")")
            if close < 0:
                continue
            brace = self._body_start(close)
            if brace < 0:
                continue
            end = self._matching(brace, "{", "}")
            if end < 0:
                continue
            start = self.raw.rfind("\n", 0, m.start()) + 1
            normalized = "".join(
                ch for i, ch in enumerate(self.code[start:end], start) if self.literal[i] or not ch.isspace()
            )
            found.append(Definition(self.line_of(start), self.line_of(end - 1), self.raw[start:end], normalized))
        return found

    def fingerprint(self, name: str) -> tuple[str | None, list[Definition]]:
        """A short SHA-256 of the normalized definitions of `name` (None when there is none), and the definitions."""
        found = self.definitions(name)
        if not found:
            return None, found
        digest = hashlib.sha256("\n".join(d.normalized for d in found).encode("utf-8")).hexdigest()[:12]
        return digest, found

    def literals(self) -> dict[str, int]:
        """{string literal content: first line} for the double-quoted literals outside comments and `#include`s."""
        out: dict[str, int] = {}
        for a, b in self.literal_spans:
            line_start = self.raw.rfind("\n", 0, a) + 1
            if self.raw[line_start:a].lstrip().startswith("#include"):
                continue
            text = self.raw[a:b]
            content = text[text.index("(") + 1 : text.rindex(")")] if text.startswith("R") else text[1:-1]
            out.setdefault(content, self.line_of(a))
        return out


# ---------------------------------------------------------------------------------------------------------------------
# Printer and parser tokens


def printer_tokens(cxx: CxxFile) -> dict[str, int]:
    """String literals of SILPrinter.cpp that look like SIL syntax: `[attr`, `@...`, `!...`, short keywords."""
    tokens = {}
    for literal, line in cxx.literals().items():
        t = literal.strip()
        if not t:
            continue
        if (
            re.match(r"^\[[A-Za-z_=]", t)
            or re.match(r"^[@!][A-Za-z_]", t)
            or (re.match(r"^,?\s*[a-z_]+(:|\s|$)", literal.strip(" ")) and len(t) <= 40)
            or (t.startswith("// ") and len(t) <= 40)
            or t.startswith("sil")
        ):
            tokens[literal] = line
    return tokens


def parser_tokens(cxx: CxxFile) -> dict[str, int]:
    """String literals of ParseSIL.cpp that are bare keywords (what the compiler's own SIL parser compares against)."""
    return {lit: line for lit, line in cxx.literals().items() if re.fullmatch(r"[A-Za-z_][A-Za-z0-9_.]*", lit)}
