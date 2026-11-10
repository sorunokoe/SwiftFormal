"""Per task: min time per size, per-element time, and the log-log slope over the upper half of the sizes (1 = linear).

    python3 analyze.py results.json                       print every task
    python3 analyze.py results.json --json slopes.json    also write {title: slope}
    python3 analyze.py results.json --baseline base.json  also print a GitHub warning for every task whose slope rose
                                                          by more than 0.25 (report only: the exit status stays 0)
"""
import json
import math
import os
import sys


def slopes(path):
    data = json.load(open(path))
    found = {}
    for task in data["tasks"]:
        rows = []
        for size, samples in task["results"].items():
            # A sample over 1 s that is not whole nanoseconds is an estimate for a run cut short by --max-duration;
            # fast runs are averages.
            clean = [s + a * 1e-18 for s, a in samples if a % 1_000_000_000 == 0 or s + a * 1e-18 < 1.0]
            if clean:
                rows.append((int(size), min(clean)))
        rows.sort()
        if len(rows) < 2:
            continue
        upper = rows[len(rows) // 2:] if len(rows) >= 4 else rows
        xs = [math.log(s) for s, _ in upper]
        ys = [math.log(v) for _, v in upper]
        mx, my = sum(xs) / len(xs), sum(ys) / len(ys)
        slope = sum((x - mx) * (y - my) for x, y in zip(xs, ys)) / max(sum((x - mx) ** 2 for x in xs), 1e-12)
        found[task["title"]] = (slope, rows)
    return found


def fmt(ns):
    return f"{ns:.3g}ns" if ns < 1e3 else (f"{ns / 1e3:.3g}µs" if ns < 1e6 else f"{ns / 1e6:.3g}ms")


def main():
    args = sys.argv[1:]
    found = slopes(args[0])
    for title, (slope, rows) in found.items():
        flag = "SUPER" if slope > 1.25 else ("~lin" if slope > 0.85 else "sub")
        points = ", ".join(f"{s}:{fmt(v / s * 1e9)}" for s, v in rows)
        print(f"{flag:5} slope={slope:4.2f} total@max={rows[-1][1]:.3g}s | {title}\n      per-element: {points}")
    if "--json" in args:
        json.dump({t: round(s, 3) for t, (s, _) in found.items()}, open(args[args.index("--json") + 1], "w"), indent=1, sort_keys=True)
    if "--baseline" in args and os.path.exists(args[args.index("--baseline") + 1]):
        baseline = json.load(open(args[args.index("--baseline") + 1]))
        for title, (slope, _) in found.items():
            if title in baseline and slope > baseline[title] + 0.25:
                print(f"::warning::scaling slope rose for '{title}': {baseline[title]:.2f} -> {slope:.2f}")


if __name__ == "__main__":
    main()
