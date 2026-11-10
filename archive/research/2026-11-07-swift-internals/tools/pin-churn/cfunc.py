#!/usr/bin/env python3
"""Print the body of a C++ function (first definition matching NAME followed by '(', or NAME literally if it contains "(") with
real file line numbers. Usage: python3 -I cfunc.py FILE NAME"""
import re, sys
path, name = sys.argv[1], sys.argv[2]
lines = open(path, encoding="utf-8", errors="replace").read().split("\n")
for i, l in enumerate(lines):
    pat = re.escape(name) if "(" in name else r"\b" + re.escape(name) + r"\s*\("
    if re.search(pat, l) and not l.rstrip().endswith(";") and not l.lstrip().startswith(("//", "return", "if", "auto")):
        depth, started = 0, False
        for j in range(i, len(lines)):
            depth += lines[j].count("{") - lines[j].count("}")
            started = started or "{" in lines[j]
            print(f"{j+1}: {lines[j]}")
            if started and depth == 0:
                sys.exit(0)
sys.exit(1)
