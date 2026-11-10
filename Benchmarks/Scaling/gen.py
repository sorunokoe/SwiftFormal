#!/usr/bin/env python3
"""gen.py kernels N | chain N: Swift sources for the SIL scaling tasks."""
import sys
kind, n = sys.argv[1], int(sys.argv[2])
if kind == "chain":
    print("func chain0(_ a: Int32) -> Int32 { a &+ 1 }")
    for i in range(1, n): print(f"func chain{i}(_ a: Int32) -> Int32 {{ chain{i-1}(a) &+ {i % 7 + 1} }}")
    sys.exit(0)
long_body = len(sys.argv) > 2 and sys.argv[2] == "long"
out = ["struct P { var x: Int16; var y: Int16 }", ""]
for h in range(10):
    out.append(f"func helper{h}(_ a: Int16) -> Int16 {{ a &* {h + 3} &+ {h} }}")
out.append("")
for i in range(n):
    kind = i % 6
    if long_body:
        lines = [f"func long{i}(_ a: Int32, _ b: Int32) -> Int32 {{", "    var x = a"]
        for j in range(40):
            op = ["&+", "&-", "^", "&+"][j % 4]
            lines.append(f"    x = (x {op} b) &+ {j + i % 13}")
            if j % 8 == 0:
                lines.append(f"    if x > b {{ x = x &- {j + 1} }}")
        lines.append("    return x")
        lines.append("}")
        out += lines
        continue
    if kind == 0:
        out.append(
            f"func k{i}(_ a: Int32, _ b: Int32) -> Int32 {{ let x = a &+ {i}; if x > b {{ return x &- b }} else {{ return (b &- x) / 2 }} }}")
    elif kind == 1:
        out.append(f"func s{i}(_ a: UInt8, _ b: UInt8) -> UInt8 {{ a &+ b &* {i % 7 + 1} }}")
    elif kind == 2:
        out.append(f"func c{i}(_ a: Int16) -> Int16 {{ helper{i % 10}(a) &+ helper{(i + 1) % 10}(a) }}")
    elif kind == 3:
        out.append(f"func t{i}(_ a: Int32) -> Int32 {{ a + {i + 1} }}")  # may trap
    elif kind == 4:
        out.append(f"func q{i}(_ a: Int32, _ b: Int32) -> Int32 {{ b == 0 ? 0 : a / b }}")
        # mayTrap: Int32.min / -1
    else:
        out.append(f"func p{i}(_ p: P) -> Int16 {{ p.x > p.y ? p.x &- p.y : p.y &- p.x }}")
        out.append(f"func p{i}_ensures(_ p: P, _ r: Int16) -> Bool {{ true }}")
print("\n".join(out))
