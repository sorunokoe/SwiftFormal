#!/usr/bin/env python3
"""Line coverage per module, from a coverage-enabled test run (Task Q.6, Step 4).

    python3 Scripts/measure-coverage.py            # runs the fast lane with coverage, then reports
    python3 Scripts/measure-coverage.py --no-run   # reuse the last coverage run in .build
    python3 Scripts/measure-coverage.py --lane slow   # a lane other than fast (see Scripts/test-lane.sh)

Writes .build/coverage-by-module.json ({"SFCheck": 92.1, ...}) for `Scripts/check-ratchet.py --coverage`.
`swift test --enable-code-coverage` only exports the files of one test binary, so this merges every test target's binary
with `llvm-cov export` and groups the files of Sources/<Module>/ by module. Tests, generated entry points and the
`.build` directory are not counted.
"""
import argparse
import collections
import json
import pathlib
import subprocess
import sys

ROOT = pathlib.Path(__file__).resolve().parent.parent
OUT = ROOT / ".build" / "coverage-by-module.json"


def run(cmd, **kw):
    return subprocess.run(cmd, cwd=ROOT, check=True, text=True, **kw)


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--no-run", action="store_true")
    ap.add_argument("--lane", default="fast", choices=["fast", "slow", "oracle"])
    args = ap.parse_args()
    if not args.no_run:
        run(["Scripts/test-lane.sh", args.lane, "--enable-code-coverage"])
    codecov = pathlib.Path(run(["swift", "test", "--show-codecov-path"], capture_output=True).stdout.strip().splitlines()[-1])
    products = codecov.parent.parent
    profdata = codecov.parent / "default.profdata"
    pkg = json.loads(run(["swift", "package", "describe", "--type", "json"], capture_output=True).stdout)
    objects = []
    for t in pkg["targets"]:
        if t["type"] != "test":
            continue
        binary = products / f'{t["name"]}.xctest' / "Contents" / "MacOS" / t["name"]
        if binary.exists():
            objects.append(str(binary))
    if not profdata.exists() or not objects:
        print(f"no coverage data under {codecov.parent}: run without --no-run", file=sys.stderr)
        return 1
    cmd = ["xcrun", "llvm-cov", "export", "-summary-only", f"-instr-profile={profdata}", objects[0]]
    for o in objects[1:]:
        cmd += ["-object", o]
    export = json.loads(run(cmd, capture_output=True).stdout)
    lines = collections.defaultdict(lambda: [0, 0])  # module -> [covered, total]
    sources = str(ROOT / "Sources") + "/"
    for f in export["data"][0]["files"]:
        name = f["filename"]
        if not name.startswith(sources):
            continue
        module = name[len(sources):].split("/")[0]
        lines[module][0] += f["summary"]["lines"]["covered"]
        lines[module][1] += f["summary"]["lines"]["count"]
    result = {m: round(100.0 * c / t, 1) for m, (c, t) in sorted(lines.items()) if t}
    OUT.write_text(json.dumps(result, indent=2) + "\n")
    print(f'{"module":24} {"lines":>7} {"covered":>8} {"percent":>8}')
    for m, (c, t) in sorted(lines.items()):
        print(f"{m:24} {t:7d} {c:8d} {result.get(m, 0.0):8.1f}")
    print(f"wrote {OUT.relative_to(ROOT)}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
