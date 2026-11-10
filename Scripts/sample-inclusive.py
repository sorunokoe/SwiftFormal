#!/usr/bin/env python3
"""Inclusive sample counts per symbol from a macOS `sample` report (docs/PERFORMANCE.md, Profiling).

Usage: Scripts/sample-inclusive.py out.txt proveExactly LRATChecker SILEncoder.run ...

Each argument is a substring of a frame name. A frame counts with the samples under it, once: a match inside an outer
match of the same argument is not counted again, so recursion does not inflate the total.
"""
import re
import sys


def main():
    if len(sys.argv) < 3:
        sys.exit(__doc__)
    text = open(sys.argv[1]).read()
    graph = text.split("Call graph:")[1].split("Total number in stack")[0].splitlines()
    symbols = sys.argv[2:]
    totals = {s: 0 for s in symbols}
    open_matches = {s: [] for s in symbols}
    frame = re.compile(r"^([\s+!:|]*)(\d+)\s+(.*)$")
    for line in graph:
        m = frame.match(line)
        if not m:
            continue
        depth, count, name = len(m.group(1)), int(m.group(2)), m.group(3)
        for s in symbols:
            outer = open_matches[s]
            while outer and outer[-1] >= depth:
                outer.pop()
            if s in name:
                if not outer:
                    totals[s] += count
                outer.append(depth)
    for s in symbols:
        print(f"{totals[s]:7d}  {s}")


if __name__ == "__main__":
    main()
