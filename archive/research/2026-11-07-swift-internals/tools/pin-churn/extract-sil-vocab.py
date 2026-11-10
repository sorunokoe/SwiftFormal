#!/usr/bin/env python3
"""Extract the SIL textual vocabulary from a Swift compiler checkout.

Usage (run with `python3 -I`):
  extract-sil-vocab.py SILNodes.def Builtins.def            # sorted name lists
  extract-sil-vocab.py --json SILNodes.def Builtins.def     # machine-readable
  extract-sil-vocab.py --diff OLD_ROOT NEW_ROOT [--fail-on-reader]
      OLD_ROOT/NEW_ROOT are swift source roots (containing include/swift/...).
      Prints added/removed/renamed/changed instructions and builtins and flags
      every change that touches the SwiftFormal reader vocabulary below.
      With --fail-on-reader, exits 1 if any reader-vocabulary name changed.

Instruction names come from SILNodes.def macro invocations whose 2nd argument
is the textual name (SINGLE_VALUE_INST, NON_VALUE_INST, TERMINATOR,
MULTIPLE_VALUE_INST, DYNAMICCAST_*, FULL_INST). Token-pasted names inside
`#define ...REF_STORAGE` bodies are reported as templates, e.g. load_<name>.
Builtin names come from every BUILTIN*(Id, Name, ...) invocation in
Builtins.def (BUILTIN_BINARY_OPERATION_ALL stringifies an unquoted Name).
"""
import difflib
import json
import os
import re
import sys

INST_MACROS = r"(?:SINGLE_VALUE_INST|NON_VALUE_INST|TERMINATOR|MULTIPLE_VALUE_INST|FULL_INST|DYNAMICCAST_SINGLE_VALUE_INST|DYNAMICCAST_NON_VALUE_INST|DYNAMICCAST_TERMINATOR|DYNAMICCAST_INST)"

# The SwiftFormal SIL text reader's accepted instructions (anything else is rejected).
READER_INSTS = set("""
debug_value debug_step dealloc_stack destroy_addr end_access strong_release fix_lifetime
dealloc_ref dealloc_stack_ref retain_value release_value strong_retain begin_apply end_apply
abort_apply begin_cow_mutation end_cow_mutation begin_dealloc_ref cond_fail store load
string_literal struct builtin integer_literal metatype tuple struct_extract struct_element_addr
tuple_extract tuple_element_addr function_ref apply alloc_stack begin_access upcast
unchecked_ref_cast alloc_ref global_value ref_tail_addr index_addr ref_element_addr
thin_to_thick_function partial_apply convert_function convert_escape_to_noescape mark_dependence
enum unchecked_enum_data select_enum select_enum_addr init_enum_data_addr
unchecked_take_enum_data_addr unchecked_inplace_enum_data_addr inject_enum_addr copy_addr
switch_enum switch_enum_addr br cond_br return unreachable
""".split())

# Integer builtins the reader / its semantics care about.
READER_BUILTINS = set("""
add sub mul sdiv udiv srem urem and or xor shl lshr ashr
sadd_with_overflow uadd_with_overflow ssub_with_overflow usub_with_overflow
smul_with_overflow umul_with_overflow
cmp_eq cmp_ne cmp_slt cmp_sle cmp_sgt cmp_sge cmp_ult cmp_ule cmp_ugt cmp_uge
truncOrBitCast zextOrBitCast sextOrBitCast int_expect ptrtoint
""".split())


def _strip_comments(text):
    # keep line structure so offsets map to line numbers
    text = re.sub(r"/\*.*?\*/", lambda m: re.sub(r"[^\n]", " ", m.group(0)), text, flags=re.S)
    return re.sub(r"//[^\n]*", "", text)


def _define_spans(text):
    """Character spans of #define directives (with backslash continuations)."""
    spans = []
    for m in re.finditer(r"^[ \t]*#[ \t]*define\b(?:[^\n]*\\\n)*[^\n]*", text, flags=re.M):
        spans.append((m.start(), m.end()))
    return spans


def _in_spans(pos, spans):
    return any(a <= pos < b for a, b in spans)


def _lineno(text, pos):
    return text.count("\n", 0, pos) + 1


def _split_args(text, start):
    """Split a macro call's arguments starting just after '('. Returns (args, end)."""
    depth, cur, args, i = 1, [], [], start
    while i < len(text) and depth:
        c = text[i]
        if c == "(":
            depth += 1
        elif c == ")":
            depth -= 1
            if depth == 0:
                break
        if c == "," and depth == 1:
            args.append("".join(cur).strip())
            cur = []
        else:
            cur.append(c)
        i += 1
    args.append("".join(cur).strip())
    return [" ".join(a.replace("\\", " ").split()) for a in args], i


def parse_silnodes(path):
    raw = open(path, encoding="utf-8", errors="replace").read()
    text = _strip_comments(raw)
    defs = _define_spans(text)
    out = {}
    for m in re.finditer(r"\b(" + INST_MACROS + r")\s*\(", text):
        args, _ = _split_args(text, m.end())
        if len(args) < 2:
            continue
        ident, name = args[0], args[1]
        if name in ("NAME", "TEXTUALNAME", "TEXTUAL_NAME", "TextualName"):
            continue  # macro plumbing
        in_def = _in_spans(m.start(), defs)
        if in_def and "##" not in name:
            continue
        name = re.sub(r"\s*##\s*", "", name.replace("##name##", "<name>").replace("##name", "<name>").replace("name##", "<name>"))
        ident = re.sub(r"\s*##\s*", "", ident.replace("##Name##", "<Name>").replace("##Name", "<Name>").replace("Name##", "<Name>"))
        out[name] = {"id": ident, "macro": m.group(1), "rest": args[2:], "line": _lineno(text, m.start())}
    return out


def parse_builtins(path):
    raw = open(path, encoding="utf-8", errors="replace").read()
    text = _strip_comments(raw)
    defs = _define_spans(text)
    out = {}
    for m in re.finditer(r"\b(BUILTIN[A-Z_]*)\s*\(", text):
        if _in_spans(m.start(), defs):
            continue
        # skip #ifndef/#undef lines
        line_start = text.rfind("\n", 0, m.start()) + 1
        if text[line_start:m.start()].strip().startswith("#"):
            continue
        args, _ = _split_args(text, m.end())
        if len(args) < 2:
            continue
        ident, name = args[0], args[1].strip('"')
        out[name] = {"id": ident, "macro": m.group(1), "rest": args[2:], "line": _lineno(text, m.start())}
    return out


def extract(silnodes, builtins):
    return {"instructions": parse_silnodes(silnodes), "builtins": parse_builtins(builtins)}


def _diff_sets(old, new, reader):
    added = sorted(set(new) - set(old))
    removed = sorted(set(old) - set(new))
    renamed = []
    # definite renames: same C++ ID, different textual name
    old_by_id = {v["id"]: k for k, v in old.items()}
    for n in list(added):
        oid = new[n]["id"]
        if oid in old_by_id and old_by_id[oid] in removed:
            renamed.append((old_by_id[oid], n, "same-id"))
    for o, n, _ in renamed:
        removed.remove(o)
        added.remove(n)
    # heuristic renames: similar names
    for o in list(removed):
        best = difflib.get_close_matches(o, added, n=1, cutoff=0.75)
        if best:
            renamed.append((o, best[0], "similar-name"))
            removed.remove(o)
            added.remove(best[0])
    changed = sorted(n for n in set(old) & set(new)
                     if (old[n]["id"], old[n]["macro"], old[n]["rest"]) != (new[n]["id"], new[n]["macro"], new[n]["rest"]))
    touches = sorted({x for x in added + removed + changed if x in reader} |
                     {x for o, n, _ in renamed for x in (o, n) if x in reader})
    return {"added": added, "removed": removed, "renamed": renamed, "changed": changed, "reader_touched": touches}


def _paths(root):
    return (os.path.join(root, "include/swift/SIL/SILNodes.def"),
            os.path.join(root, "include/swift/AST/Builtins.def"))


def main(argv):
    if argv and argv[0] == "--diff":
        fail = "--fail-on-reader" in argv
        roots = [a for a in argv[1:] if not a.startswith("--")]
        old, new = extract(*_paths(roots[0])), extract(*_paths(roots[1]))
        bad = False
        for key, reader in (("instructions", READER_INSTS), ("builtins", READER_BUILTINS)):
            d = _diff_sets(old[key], new[key], reader)
            print(f"## {key}: {len(old[key])} -> {len(new[key])}")
            print(f"  added   ({len(d['added'])}): {' '.join(d['added'])}")
            print(f"  removed ({len(d['removed'])}): {' '.join(d['removed'])}")
            print(f"  renamed ({len(d['renamed'])}): {' '.join(f'{o}->{n}[{w}]' for o, n, w in d['renamed'])}")
            ch = []
            for n in d["changed"]:
                o, w = old[key][n], new[key][n]
                ch.append(f"{n}: {o['macro']}({o['id']},{','.join(o['rest'])}) -> {w['macro']}({w['id']},{','.join(w['rest'])})")
            print(f"  changed ({len(d['changed'])}):")
            for c in ch:
                print(f"    {c}")
            print(f"  READER-VOCAB TOUCHED: {' '.join(d['reader_touched']) or '(none)'}")
            for n in d["reader_touched"]:
                for side, tab in (("old", old[key]), ("new", new[key])):
                    if n in tab:
                        print(f"    {side} {n} line {tab[n]['line']}: {tab[n]['macro']}({tab[n]['id']}, {', '.join(tab[n]['rest'])})")
            bad = bad or bool(d["reader_touched"])
            if key == "instructions":
                missing = sorted(READER_INSTS - set(new[key]))
                print(f"  reader names absent from NEW SILNodes.def: {' '.join(missing) or '(none)'}")
            else:
                missing = sorted(READER_BUILTINS - set(new[key]))
                print(f"  reader builtins absent from NEW Builtins.def: {' '.join(missing) or '(none)'}")
                bad = bad or bool(missing)
        return 1 if (fail and bad) else 0
    as_json = argv and argv[0] == "--json"
    if as_json:
        argv = argv[1:]
    if len(argv) != 2:
        print(__doc__, file=sys.stderr)
        return 2
    res = extract(argv[0], argv[1])
    if as_json:
        json.dump(res, sys.stdout, indent=1, sort_keys=True)
        print()
        return 0
    for key in ("instructions", "builtins"):
        print(f"# {key} ({len(res[key])})")
        for n in sorted(res[key]):
            v = res[key][n]
            print(f"{n}\t{v['macro']}\t{v['id']}\tline {v['line']}")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
