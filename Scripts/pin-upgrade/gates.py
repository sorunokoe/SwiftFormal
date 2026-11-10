#!/usr/bin/env python3
"""Static gates of a compiler pin upgrade: compare two Swift compiler source trees against what the SIL reader uses.

    python3 -I Scripts/pin-upgrade/gates.py --old OLD_ROOT --new NEW_ROOT [--old-label L] [--new-label L]
                                            [--reader PATH ...] [--builtin-source PATH ...] [--diff-lines N]

OLD_ROOT and NEW_ROOT hold the files of `COMPARED_FILES` at their paths in the swiftlang/swift repository
(`Scripts/pin-upgrade.sh` downloads them). By default the reader is `Sources/SFSIL` and the builtin names come from
`Sources/SFSemantics/S0.swift` of this repository.

Gates (docs/guides/pin-upgrade.md explains each one):
  1 vocabulary    instruction and builtin names, macros and arguments (SILNodes.def, Builtins.def)
  2 tokens        printer and parser string literals (SILPrinter.cpp, ParseSIL.cpp)
  3 fingerprints  a SHA-256 of the printer code for every instruction the reader accepts, and of shared helpers

Exit status: 0 when no gate flags anything the reader uses, 1 when one does, 2 on a usage error or a missing file.
Standard library only.
"""
from __future__ import annotations

import argparse
import difflib
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))  # `python3 -I` leaves this folder off the path

from compiler_sources import CxxFile, parse_builtins, parse_sil_nodes, parse_sil_parents, parser_tokens, printer_tokens  # noqa: E402
from reader_vocabulary import derive  # noqa: E402

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))

SIL_NODES = "include/swift/SIL/SILNodes.def"
BUILTINS_DEF = "include/swift/AST/Builtins.def"
SIL_PRINTER = "lib/SIL/IR/SILPrinter.cpp"
PARSE_SIL = "lib/SIL/Parser/ParseSIL.cpp"
AST_PRINTER = "lib/AST/ASTPrinter.cpp"
BUILTINS_CPP = "lib/AST/Builtins.cpp"
COMPARED_FILES = [SIL_NODES, BUILTINS_DEF, SIL_PRINTER, PARSE_SIL, AST_PRINTER, BUILTINS_CPP]

# Code that shapes the text of many instructions at once, so no single visitor shows its change.
HELPERS = [
    (SIL_PRINTER, "void print(const SILBasicBlock *BB)"),  # block headers `bb1(%0 : $Int):`
    (SIL_PRINTER, "printSILArgument"),  # each block argument
    (SIL_PRINTER, "void print(const SILInstruction *I)"),  # `%3 = name ...`, debug locations, comments
    (SIL_PRINTER, "printInstOpCode"),  # the instruction name
    (SIL_PRINTER, "SILPrinter &operator<<(SILValuePrinterInfo i)"),  # every operand `%1 : $T`
    (SIL_PRINTER, "needPrintTypeFor"),  # when an operand's type is printed (the 6.2 change)
    (SIL_PRINTER, "printAllocRefInstBase"),
    (SIL_PRINTER, "printBranchArgs"),
    (SIL_PRINTER, "printDebugVar"),
    (SIL_PRINTER, "printDebugLocRef"),
    (SIL_PRINTER, "printDebugScopeRef"),
    (SIL_PRINTER, "printSILFunctionNameAndType"),
    (SIL_PRINTER, "printValueDecl"),
    (SIL_PRINTER, "SILFunction::print"),
    (SIL_PRINTER, "SILGlobalVariable::print"),
    (SIL_PRINTER, "SILWitnessTable::print"),
    (SIL_PRINTER, "SILWitnessTable::Entry::print"),
    (AST_PRINTER, "getStringForParameterConvention"),  # @guaranteed, @inout, @in_guaranteed, ...
    (AST_PRINTER, "getStringForResultConvention"),  # @owned, @out, ...
    (AST_PRINTER, "printFunctionExtInfo"),  # @convention(thin), ...
    (BUILTINS_CPP, "getBuiltinBaseName"),  # how `"add_Int64"` splits into a builtin and its types
]


class Report:
    def __init__(self, diff_lines: int) -> None:
        self.flags: list[str] = []  # each one touches the reader: exit 1
        self.reviews: list[str] = []  # changes the reader does not use: read, but do not block
        self.diff_lines = diff_lines

    def flag(self, gate: str, text: str) -> None:
        self.flags.append(f"[{gate}] {text}")
        print(f"  FLAG    {text}")

    def review(self, gate: str, text: str) -> None:
        self.reviews.append(f"[{gate}] {text}")


def _short(names: list[str], limit: int = 40) -> str:
    if not names:
        return "(none)"
    return " ".join(names[:limit]) + (f" ... (+{len(names) - limit})" if len(names) > limit else "")


def _diff_sets(old: dict, new: dict) -> dict:
    added, removed = sorted(set(new) - set(old)), sorted(set(old) - set(new))
    renamed = []
    old_by_id = {v["id"]: k for k, v in old.items()}
    for name in list(added):  # same C++ class, different text: a rename
        before = old_by_id.get(new[name]["id"])
        if before in removed:
            renamed.append((before, name))
            removed.remove(before)
            added.remove(name)
    changed = sorted(
        n for n in set(old) & set(new) if (old[n]["id"], old[n]["macro"], old[n]["rest"]) != (new[n]["id"], new[n]["macro"], new[n]["rest"])
    )
    return {"added": added, "removed": removed, "renamed": renamed, "changed": changed}


def _macro(entry: dict) -> str:
    return f"{entry['macro']}({entry['id']}, {', '.join(entry['rest'])})"


def gate_vocabulary(report: Report, kind: str, old: dict, new: dict, reader: set[str], file: str, labels: tuple[str, str]) -> None:
    d = _diff_sets(old, new)
    base = os.path.basename(file)
    print(f"  {kind}: {len(old)} -> {len(new)}; added {len(d['added'])}, removed {len(d['removed'])}, "
          f"renamed {len(d['renamed'])}, changed {len(d['changed'])}")
    print(f"    added:   {_short(d['added'])}")
    print(f"    removed: {_short(d['removed'])}")
    if d["renamed"]:
        print(f"    renamed: {_short([f'{a}->{b}' for a, b in d['renamed']])}")
    if d["changed"]:
        print(f"    changed: {_short(d['changed'])}")
    for name in d["added"]:
        where = f"{base}:{new[name]['line']}@{labels[1]}"
        (report.flag if name in reader else report.review)("vocabulary", f"{kind[:-1]} `{name}` is new ({where})")
    for name in d["removed"]:
        where = f"{base}:{old[name]['line']}@{labels[0]}"
        (report.flag if name in reader else report.review)("vocabulary", f"{kind[:-1]} `{name}` was removed ({where})")
    for before, after in d["renamed"]:
        text = f"{kind[:-1]} `{before}` was renamed `{after}` ({base}:{new[after]['line']}@{labels[1]})"
        (report.flag if before in reader or after in reader else report.review)("vocabulary", text)
    for name in d["changed"]:
        text = (f"{kind[:-1]} `{name}` changed: {_macro(old[name])} ({base}:{old[name]['line']}@{labels[0]}) -> "
                f"{_macro(new[name])} ({base}:{new[name]['line']}@{labels[1]})")
        (report.flag if name in reader else report.review)("vocabulary", text)


def gate_tokens(report: Report, old_root: str, new_root: str, watched: set[str], labels: tuple[str, str]) -> None:
    for rel, extract, watch in ((SIL_PRINTER, printer_tokens, True), (PARSE_SIL, parser_tokens, False)):
        a, b = extract(CxxFile(os.path.join(old_root, rel))), extract(CxxFile(os.path.join(new_root, rel)))
        added, removed = sorted(set(b) - set(a)), sorted(set(a) - set(b))
        base = os.path.basename(rel)
        print(f"  {base}: {len(a)} -> {len(b)} tokens; added {len(added)}, removed {len(removed)}")
        for sign, tokens, table, label in (("+", added, b, labels[1]), ("-", removed, a, labels[0])):
            for token in tokens:
                core = token.strip(" []@!,:(")
                text = f"{sign}{token!r} ({base}:{table[token]}@{label})"
                if watch and core in watched:
                    report.flag("tokens", f"reader token changed: {text}")
                else:
                    report.review("tokens", text)
                    print(f"    {text}")


def _visitor(name: str, nodes: dict, parents: dict, printer: CxxFile) -> tuple[str | None, str | None, list]:
    """(visitor, fingerprint, definitions) for instruction `name`: its own `visit<Class>`, else its parent's."""
    cls = nodes[name]["id"]
    chain = [cls]
    parent = nodes[name]["rest"][0] if nodes[name]["rest"] else None
    while parent and parent not in chain and parent not in ("SILNode", "ValueBase"):
        chain.append(parent)
        parent = parents.get(parent)
    for c in chain:
        digest, found = printer.fingerprint("visit" + c)
        if digest:
            return "visit" + c, digest, found
    return None, None, []


def _show_diff(report: Report, before: list, after: list, labels: tuple[str, str]) -> None:
    if report.diff_lines <= 0:
        return
    a = "\n".join(d.text for d in before).splitlines()
    b = "\n".join(d.text for d in after).splitlines()
    lines = [l for l in difflib.unified_diff(a, b, labels[0], labels[1], n=1, lineterm="")][2:]
    for line in lines[: report.diff_lines]:
        print(f"          {line}")
    if len(lines) > report.diff_lines:
        print(f"          ... ({len(lines) - report.diff_lines} more diff lines)")


def gate_fingerprints(report: Report, old_root: str, new_root: str, old_nodes: dict, new_nodes: dict,
                      reader: list[str], labels: tuple[str, str]) -> None:
    printers = (CxxFile(os.path.join(old_root, SIL_PRINTER)), CxxFile(os.path.join(new_root, SIL_PRINTER)))
    parents = (parse_sil_parents(os.path.join(old_root, SIL_NODES)), parse_sil_parents(os.path.join(new_root, SIL_NODES)))
    unchanged = 0
    for name in reader:
        if name not in old_nodes or name not in new_nodes:
            print(f"  {name}: defined by one compiler only (see the vocabulary gate)")
            continue
        (v0, h0, d0), (v1, h1, d1) = (
            _visitor(name, old_nodes, parents[0], printers[0]), _visitor(name, new_nodes, parents[1], printers[1]))
        if v0 is None or v1 is None:
            report.flag("fingerprints", f"`{name}`: no printer visitor found ({labels[0] if v0 is None else labels[1]}); "
                        "it cannot be fingerprinted")
        elif (v0, h0) != (v1, h1):
            report.flag("fingerprints", f"`{name}` printer changed: {v0} SILPrinter.cpp:{d0[0].line}@{labels[0]} -> "
                        f"{v1} SILPrinter.cpp:{d1[0].line}@{labels[1]}")
            _show_diff(report, d0, d1, labels)
        else:
            unchanged += 1
    print(f"  instructions: {unchanged} of {len(reader)} printer visitors unchanged")
    files: dict[str, tuple[CxxFile, CxxFile]] = {}
    unchanged = 0
    for rel, name in HELPERS:
        if rel not in files:
            files[rel] = (CxxFile(os.path.join(old_root, rel)), CxxFile(os.path.join(new_root, rel)))
        (h0, d0), (h1, d1) = files[rel][0].fingerprint(name), files[rel][1].fingerprint(name)
        base = os.path.basename(rel)
        if h0 is None and h1 is None:
            report.flag("fingerprints", f"helper `{name}` not found in {base} of either compiler: update HELPERS in gates.py")
        elif h0 is None or h1 is None:
            side = labels[0] if h0 is None else labels[1]
            report.flag("fingerprints", f"helper `{name}` is missing from {base}@{side}")
        elif h0 != h1:
            report.flag("fingerprints", f"helper `{name}` changed: {base}:{d0[0].line}@{labels[0]} -> {base}:{d1[0].line}@{labels[1]}")
            _show_diff(report, d0, d1, labels)
        else:
            unchanged += 1
    print(f"  shared helpers: {unchanged} of {len(HELPERS)} unchanged")


DECISION_TABLE = """\
  Decision table (static gates plus the dynamic lanes):
    static gates clean, no verdict delta, no reader code changed -> add the version line only; no semantics bump
                                                                    (the proof cache key already holds the compiler)
    reader or encoder code changed to accept the new output      -> bump SILFrontendVersion.semantics
    any verdict delta on the same source                         -> bump semantics, and a CHANGELOG line naming the functions
    a `safe` that became `mayTrap` under the new compiler        -> stop: investigate before pinning"""


def run(old_root: str, new_root: str, labels: tuple[str, str], reader_paths: list[str], builtin_paths: list[str],
        diff_lines: int = 30, table: bool = True) -> int:
    missing = [f"{label}: {rel}" for root, label in ((old_root, labels[0]), (new_root, labels[1]))
               for rel in COMPARED_FILES if not os.path.isfile(os.path.join(root, rel))]
    if missing:
        print("pin-upgrade: missing compiler files:\n  " + "\n  ".join(missing), file=sys.stderr)
        return 2
    report = Report(diff_lines)
    old_nodes, new_nodes = parse_sil_nodes(os.path.join(old_root, SIL_NODES)), parse_sil_nodes(os.path.join(new_root, SIL_NODES))
    old_builtins = parse_builtins(os.path.join(old_root, BUILTINS_DEF))
    new_builtins = parse_builtins(os.path.join(new_root, BUILTINS_DEF))
    reader = derive(reader_paths, builtin_paths, set(old_nodes) | set(new_nodes), set(old_builtins) | set(new_builtins),
                    root=ROOT)

    sources = ", ".join(os.path.relpath(p, ROOT) for p in reader_paths + builtin_paths)
    print(f"Reader vocabulary, derived from {sources} ({len(reader.files)} files):")
    print(f"  {len(reader.instructions)} instructions: {' '.join(sorted(reader.instructions))}")
    print(f"  {len(reader.builtins)} builtins: {' '.join(sorted(reader.builtins))}")
    print(f"  {len(reader.tokens)} watched tokens: {' '.join(sorted(reader.tokens))}")

    print("\n[gate 1] vocabulary (SILNodes.def, Builtins.def)")
    gate_vocabulary(report, "instructions", old_nodes, new_nodes, set(reader.instructions), SIL_NODES, labels)
    gate_vocabulary(report, "builtins", old_builtins, new_builtins, set(reader.builtins), BUILTINS_DEF, labels)
    print("\n[gate 2] printer and parser tokens (SILPrinter.cpp, ParseSIL.cpp; review-only lines are listed)")
    gate_tokens(report, old_root, new_root, set(reader.tokens), labels)
    print("\n[gate 3] fingerprints (printer visitor of each reader instruction, shared helpers)")
    gate_fingerprints(report, old_root, new_root, old_nodes, new_nodes, sorted(reader.instructions), labels)

    print("\n== Summary")
    by_gate = {g: sum(1 for f in report.flags if f.startswith(f"[{g}]")) for g in ("vocabulary", "tokens", "fingerprints")}
    print("  flags (touch the reader): " + ", ".join(f"{g} {n}" for g, n in by_gate.items()))
    print(f"  review items (the reader does not use them): {len(report.reviews)}")
    for item in report.flags:
        print(f"    {item}")
    if report.flags:
        print("  Result: the reader is affected. Read each flagged line and check the reader against the new printer")
        print("  output. If SILParser, SILEnums or SILEncoder has to change, bump SILFrontendVersion.semantics.")
    else:
        print("  Result: static gates clean. If the dynamic lanes show no verdict delta, add the version line only.")
    if table:
        print(DECISION_TABLE)
    return 1 if report.flags else 0


def main(argv: list[str]) -> int:
    parser = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    parser.add_argument("--old", help="source root of the pinned compiler")
    parser.add_argument("--new", help="source root of the candidate compiler")
    parser.add_argument("--old-label", default="OLD")
    parser.add_argument("--new-label", default="NEW")
    parser.add_argument("--reader", action="append", help="reader Swift file or folder (default Sources/SFSIL)")
    parser.add_argument("--builtin-source", action="append", help="Swift file naming the builtins (default S0.swift)")
    parser.add_argument("--diff-lines", type=int, default=30, help="diff lines shown per changed fingerprint (0: none)")
    parser.add_argument("--no-table", action="store_true", help="leave the decision table out of the summary")
    parser.add_argument("--table-only", action="store_true", help="print the decision table and exit")
    args = parser.parse_args(argv)
    if args.table_only:
        print(DECISION_TABLE)
        return 0
    if not args.old or not args.new:
        parser.error("--old and --new are required")
    reader = args.reader or [os.path.join(ROOT, "Sources/SFSIL")]
    builtins = args.builtin_source or [os.path.join(ROOT, "Sources/SFSemantics/S0.swift")]
    return run(args.old, args.new, (args.old_label, args.new_label), reader, builtins, args.diff_lines, not args.no_table)


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
