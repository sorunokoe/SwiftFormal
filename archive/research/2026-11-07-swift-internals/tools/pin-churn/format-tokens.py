#!/usr/bin/env python3
"""Set-diff the printed/parsed SIL format tokens between two Swift source roots.

Usage (run with `python3 -I`):
  format-tokens.py OLD_ROOT NEW_ROOT [--watch tok1,tok2,...]

From lib/SIL/IR/SILPrinter.cpp it collects every C string literal that looks like
SIL syntax: attribute brackets ("[stack] ", "[tail_elems "), "@..." and "!..."
markers, and short keyword-ish literals (" to ", ", forwarding: @", "// Loop header").
From lib/SIL/Parser/ParseSIL.cpp it collects every string literal that is a bare
identifier-like keyword (what parseSILIdentifier / P.Tok.getText() compare
against). Prints added/removed tokens per file with the first line number in the
new (added) or old (removed) file. Exit status 1 if any --watch token changed.
"""
import os
import re
import sys

LIT = re.compile(r'"((?:[^"\\\n]|\\.)*)"')


def literals(path):
    out = {}
    with open(path, encoding="utf-8", errors="replace") as f:
        for no, line in enumerate(f, 1):
            s = line.strip()
            if s.startswith("//") or s.startswith("#include"):
                continue
            for m in LIT.finditer(line):
                out.setdefault(m.group(1), no)
    return out


def printer_tokens(path):
    toks = {}
    for lit, no in literals(path).items():
        t = lit.strip()
        if not t:
            continue
        if re.match(r"^\[[A-Za-z_=]", t) or re.match(r"^[@!][A-Za-z_]", t) \
           or re.match(r"^[,]?\s*[a-z_]+(:|\s|$)", lit.strip(" ")) and len(t) <= 40 \
           or t.startswith("// ") and len(t) <= 40 or t.startswith("sil"):
            toks[lit] = no
    return toks


def parser_tokens(path):
    toks = {}
    for lit, no in literals(path).items():
        if re.fullmatch(r"[A-Za-z_][A-Za-z0-9_.]*", lit):
            toks[lit] = no
    return toks


def main(argv):
    watch = set()
    if "--watch" in argv:
        i = argv.index("--watch")
        watch = set(argv[i + 1].split(","))
        argv = argv[:i] + argv[i + 2:]
    if len(argv) != 2:
        print(__doc__, file=sys.stderr)
        return 2
    old, new = argv
    hit = False
    for rel, fn in (("lib/SIL/IR/SILPrinter.cpp", printer_tokens),
                    ("lib/SIL/Parser/ParseSIL.cpp", parser_tokens)):
        a, b = fn(os.path.join(old, rel)), fn(os.path.join(new, rel))
        added = sorted(set(b) - set(a))
        removed = sorted(set(a) - set(b))
        print(f"## {rel}: {len(a)} -> {len(b)} tokens")
        print(f"  added ({len(added)}):")
        for t in added:
            print(f"    +{t!r}  {rel}:{b[t]}@NEW")
        print(f"  removed ({len(removed)}):")
        for t in removed:
            print(f"    -{t!r}  {rel}:{a[t]}@OLD")
        for t in added + removed:
            if t.strip(" []@!,:") in watch or t in watch:
                hit = True
                print(f"  WATCHED TOKEN CHANGED: {t!r}")
    return 1 if hit else 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
