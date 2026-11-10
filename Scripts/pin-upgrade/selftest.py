#!/usr/bin/env python3
"""Offline self-test of the pin-upgrade gates. Exit status 1 on any failure.

    python3 Scripts/pin-upgrade/selftest.py

Uses the excerpts in fixtures/ (README.md there): `old` and `new` differ by a known added instruction
(`unchecked_inplace_enum_data_addr`), a known changed visitor (`cond_br`), a comment-and-indentation-only edit
(`visitRefCountingInst`, must not count) and changes the reader does not use. Further cases are built in a temporary
folder from those trees. It also derives the reader vocabulary from this repository's real Sources/SFSIL, and runs
Scripts/pin-upgrade.sh end to end on a pre-filled cache (SHA refs, so no network).
"""
from __future__ import annotations

import contextlib
import io
import os
import shutil
import subprocess
import sys
import tempfile

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)

import gates  # noqa: E402
from compiler_sources import CxxFile  # noqa: E402
from reader_vocabulary import derive, swift_literals  # noqa: E402

FIXTURES = os.path.join(HERE, "fixtures")
OLD, NEW = os.path.join(FIXTURES, "old"), os.path.join(FIXTURES, "new")
READER = [os.path.join(FIXTURES, "reader", "SILParser.swift")]
BUILTINS = [os.path.join(FIXTURES, "reader", "S0.swift")]
REPO = os.path.dirname(os.path.dirname(HERE))

failures: list[str] = []


def check(condition: bool, what: str) -> None:
    print(f"  {'ok  ' if condition else 'FAIL'} {what}")
    if not condition:
        failures.append(what)


def run_gates(old: str, new: str) -> tuple[int, str]:
    out = io.StringIO()
    with contextlib.redirect_stdout(out), contextlib.redirect_stderr(out):
        rc = gates.run(old, new, ("OLD", "NEW"), READER, BUILTINS, diff_lines=0)
    return rc, out.getvalue()


def flags(output: str) -> list[str]:
    return [line.strip()[len("FLAG"):].strip() for line in output.splitlines() if line.strip().startswith("FLAG ")]


def variant(tmp: str, name: str, edits: list[tuple[str, str, str]]) -> str:
    """A copy of the `new` tree with (file, old text, new text) replacements."""
    root = os.path.join(tmp, name)
    shutil.copytree(NEW, root)
    for rel, before, after in edits:
        path = os.path.join(root, rel)
        with open(path, encoding="utf-8") as f:
            text = f.read()
        assert before in text, (rel, before)
        with open(path, "w", encoding="utf-8") as f:
            f.write(text.replace(before, after, 1))
    return root


def test_lexers() -> None:
    print("lexers")
    with tempfile.TemporaryDirectory() as tmp:
        swift = os.path.join(tmp, "a.swift")
        with open(swift, "w", encoding="utf-8") as f:
            f.write('let a = "x \\(f("inner")) y" // "comment"\n/* "block /* nested */ still" */ let b = #"raw"#\n'
                    'let c = """\n  multi "quoted"\n  """\nlet d = "\\"ptrtoint_Word\\""\n')
        contents = [lit.content for lit in swift_literals(swift)]
        check(contents == ["inner", "x \0 y", "raw", '  multi "quoted"\n  ', '"ptrtoint_Word"'],
              f"Swift literals: interpolation, comments, raw and multi-line strings ({contents!r})")
        cxx = os.path.join(tmp, "a.cpp")
        with open(cxx, "w", encoding="utf-8") as f:
            f.write('void f(int x) {\n  if (x) { out << "}"; }  // }\n  out << \'{\';\n}\nvoid g() { f(1); }\n'
                    'void h() {\n  f(2);  // a comment\n}\n')
        file = CxxFile(cxx)
        found = file.definitions("f")
        check(len(found) == 1 and found[0].line == 1 and found[0].end_line == 4,
              "C++ body ends at the right brace despite braces in strings, characters and comments")
        check(file.fingerprint("missing")[0] is None, "a missing function has no fingerprint")
        with open(cxx, "w", encoding="utf-8") as f:
            f.write('void h() {\n    f(2);\n}\n')
        check(CxxFile(cxx).fingerprint("h")[0] == file.fingerprint("h")[0],
              "comments and whitespace do not change a fingerprint")


def test_fixture_reader() -> None:
    print("reader vocabulary (fixture)")
    from compiler_sources import parse_builtins, parse_sil_nodes

    names = set(parse_sil_nodes(os.path.join(OLD, gates.SIL_NODES))) | set(parse_sil_nodes(os.path.join(NEW, gates.SIL_NODES)))
    builtins = set(parse_builtins(os.path.join(NEW, gates.BUILTINS_DEF)))
    vocabulary = derive(READER, BUILTINS, names, builtins)
    expected = {"br", "cond_br", "return", "debug_value", "strong_retain", "unchecked_take_enum_data_addr",
                "unchecked_inplace_enum_data_addr"}
    check(set(vocabulary.instructions) == expected,
          f"instructions from hasPrefix, ==, case (not comments): {sorted(vocabulary.instructions)}")
    check(set(vocabulary.builtins) == {"add", "sadd_with_overflow", "ptrtoint"},
          f"builtins from S0 names and quoted builtin names: {sorted(vocabulary.builtins)}")
    check("stack" in vocabulary.tokens, "attribute tokens next to `attributes`")


def test_real_reader() -> None:
    print("reader vocabulary (this repository's Sources/SFSIL)")
    must = {"apply", "begin_apply", "br", "cond_br", "debug_value", "integer_literal", "keypath", "return", "struct",
            "unchecked_inplace_enum_data_addr", "unreachable", "Bool"}
    vocabulary = derive([os.path.join(REPO, "Sources/SFSIL")], [os.path.join(REPO, "Sources/SFSemantics/S0.swift")],
                        must, {"add", "sadd_with_overflow", "ptrtoint", "cmp_slt"})
    check(set(vocabulary.instructions) == must - {"Bool"},
          f"finds the reader's instructions, not type names: missing {sorted(must - {'Bool'} - set(vocabulary.instructions))}")
    check(set(vocabulary.builtins) == {"add", "sadd_with_overflow", "ptrtoint", "cmp_slt"},
          f"finds the S0 builtins: {sorted(vocabulary.builtins)}")
    check({"static", "stack", "guaranteed", "inout"} <= set(vocabulary.tokens), "finds the reader's attributes")


def test_gates() -> None:
    print("gates (fixture old -> new)")
    rc, output = run_gates(OLD, NEW)
    found = flags(output)
    check(rc == 1, f"exit status 1 (got {rc})")
    check(any("`unchecked_inplace_enum_data_addr` is new" in f for f in found), "flags the new reader instruction")
    check(any("`unchecked_take_enum_data_addr` changed" in f for f in found), "flags a reader instruction's new parent")
    check(any("`cond_br` printer changed" in f for f in found), "flags the changed cond_br visitor")
    check(len(found) == 3, f"flags nothing else ({len(found)} flags)")
    check(not any("strong_retain" in f for f in found), "a comment-only edit of visitRefCountingInst is not a change")
    check("make_borrow" in output and "makeBorrow" in output and not any("make" in f for f in found),
          "a new instruction and builtin the reader does not use are listed, not flagged")
    check("+'non_nested'" in output, "parser token changes are listed")

    print("gates (fixture old -> old)")
    rc, output = run_gates(OLD, OLD)
    check(rc == 0 and not flags(output) and "static gates clean" in output, f"identical trees are clean (exit {rc})")

    with tempfile.TemporaryDirectory() as tmp:
        print("gates (variants of new)")
        no_visitor = variant(tmp, "no-visitor", [(gates.SIL_PRINTER, "void visitReturnInst(", "void visitReturnInstGone(")])
        rc, output = run_gates(NEW, no_visitor)
        check(rc == 1 and any("`return`: no printer visitor found" in f for f in flags(output)),
              "a visitor missing on one side is flagged, not skipped")
        token = variant(tmp, "token", [(gates.SIL_PRINTER, '*this << "[stack] ";', '*this << "[on_stack] ";')])
        rc, output = run_gates(NEW, token)
        found = flags(output)
        check(rc == 1 and any("reader token changed: -'[stack] '" in f for f in found),
              "a removed printer token the reader watches is flagged")
        check(any("helper `printAllocRefInstBase` changed" in f for f in found), "a changed shared helper is flagged")
        helper = variant(tmp, "helper", [(gates.BUILTINS_CPP, "getBuiltinBaseName", "getBuiltinBaseNameRenamed")])
        rc, output = run_gates(NEW, helper)
        check(rc == 1 and any("helper `getBuiltinBaseName` is missing" in f for f in flags(output)),
              "a helper missing on one side is flagged")
        print("gates (missing file)")
        os.remove(os.path.join(helper, gates.PARSE_SIL))
        rc, _ = run_gates(NEW, helper)
        check(rc == 2, f"a missing compiler file is exit status 2 (got {rc})")


def test_script() -> None:
    print("Scripts/pin-upgrade.sh (pre-filled cache, SHA refs, offline)")
    old_sha, new_sha = "0" * 39 + "1", "0" * 39 + "2"
    with tempfile.TemporaryDirectory() as tmp:
        shutil.copytree(OLD, os.path.join(tmp, old_sha))
        shutil.copytree(NEW, os.path.join(tmp, new_sha))
        result = subprocess.run(["bash", os.path.join(REPO, "Scripts/pin-upgrade.sh"), "--cache", tmp, old_sha, new_sha],
                                capture_output=True, text=True, check=False)
        out = result.stdout
        check(result.returncode == 1, f"exit status 1 (got {result.returncode}; stderr: {result.stderr.strip()[:200]})")
        check(all(s in out for s in ("== Step 1", "== Step 2", "== Step 3", "== Step 4")), "prints all four steps")
        check("`unchecked_inplace_enum_data_addr` is new" in out and "`cond_br` printer changed" in out,
              "flags the known changes with the real reader")
        check("Scripts/test-lane.sh oracle" in out and "bump SILFrontendVersion.semantics" in out,
              "prints the dynamic lanes and the decision table")
        result = subprocess.run(["bash", os.path.join(REPO, "Scripts/pin-upgrade.sh"), "only-one-ref"],
                                capture_output=True, text=True, check=False)
        check(result.returncode == 2, "a usage error is exit status 2")


def main() -> int:
    test_lexers()
    test_fixture_reader()
    test_real_reader()
    test_gates()
    test_script()
    if failures:
        print(f"\nselftest: {len(failures)} FAILED")
        return 1
    print("\nselftest: all passed")
    return 0


if __name__ == "__main__":
    sys.exit(main())
