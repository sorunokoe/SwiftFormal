#!/usr/bin/env python3
"""Run a test lane with every test bundle in parallel, after one build. A faster local loop; not what CI runs.

    python3 Scripts/test-bundles.py fast        same tests as Scripts/test-lane.sh fast
    python3 Scripts/test-bundles.py slow-dev    same tests as Scripts/test-lane.sh slow-dev

`swift test` runs the bundles one after another. This builds once, then starts SwiftPM's own runner
(`swiftpm-testing-helper`, the program `swift test` itself uses on macOS) for every bundle at the same time. That runner
is a private interface of the toolchain: when it is missing or behaves differently, use Scripts/test-lane.sh, which stays
the definition of the lanes. Bundles are picked by test target here (not by name filters), every bundle must report a
`Test run with N tests` line, and the totals are printed so they can be compared with Scripts/test-lane.sh.
"""
import json
import os
import pathlib
import re
import subprocess
import sys
import time
from concurrent.futures import ThreadPoolExecutor

ROOT = pathlib.Path(__file__).resolve().parent.parent
SLOW_TARGETS = {"SFBVTests", "SFProveTests", "SFSATTests", "SFSILTests"}
ORACLE_TARGETS = {"SFOracleTests"}
SLOW_SUITES = "SlowTests"
RUN_LINE = re.compile(r"Test run with (\d+) tests?")
# The runner exits with EX_UNAVAILABLE, printing nothing, when the filter selects no test of a bundle.
NO_MATCHING_TESTS = 69


def lane_plan(lane, targets):
    """(target, extra runner arguments) for every bundle the lane runs."""
    plan = []
    for target in sorted(targets):
        if target in ORACLE_TARGETS:
            continue
        slow = target in SLOW_TARGETS
        if lane == "fast" and not slow:
            plan.append((target, ["--skip", SLOW_SUITES]))
        elif lane == "slow-dev":
            plan.append((target, [] if slow else ["--filter", SLOW_SUITES]))
    return plan


def run(command, **kwargs):
    return subprocess.run(command, cwd=ROOT, check=True, capture_output=True, text=True, **kwargs).stdout


def main():
    lane = sys.argv[1] if len(sys.argv) > 1 else ""
    if lane not in ("fast", "slow-dev"):
        print(__doc__, file=sys.stderr)
        return 2
    build = ["swift", "build", "--build-tests"]
    environment = dict(os.environ)
    if lane == "slow-dev":
        build += ["--scratch-path", ".build/dev-optimize"]
        environment["SWIFTFORMAL_DEV_OPTIMIZE"] = "1"
    started = time.monotonic()
    subprocess.run(build, cwd=ROOT, check=True, env=environment)
    built = time.monotonic()
    products = pathlib.Path(run(build + ["--show-bin-path"], env=environment).strip())
    manifest = json.loads(run(["swift", "package", "dump-package"]))
    targets = {target["name"] for target in manifest["targets"] if target["type"] == "test"}

    toolchain = pathlib.Path(run(["xcrun", "--find", "swift"]).strip()).parent.parent
    helper = toolchain / "libexec/swift/pm/swiftpm-testing-helper"
    developer = pathlib.Path(run(["xcode-select", "-p"]).strip()) / "Platforms/MacOSX.platform/Developer"
    if not helper.exists():
        print(f"no {helper}: use Scripts/test-lane.sh {lane}", file=sys.stderr)
        return 2
    runner_environment = dict(environment)
    runner_environment["DYLD_FRAMEWORK_PATH"] = str(developer / "Library/Frameworks")
    runner_environment["DYLD_LIBRARY_PATH"] = str(developer / "usr/lib")

    def run_bundle(item):
        target, arguments = item
        binary = products / f"{target}.xctest/Contents/MacOS/{target}"
        if not binary.exists():
            return target, 1, f"no test bundle at {binary}", 0.0
        start = time.monotonic()
        result = subprocess.run(
            [str(helper), "--test-bundle-path", str(binary), str(binary), "--testing-library", "swift-testing", *arguments],
            cwd=ROOT, env=runner_environment, capture_output=True, text=True)
        return target, result.returncode, result.stdout + result.stderr, time.monotonic() - start

    plan = lane_plan(lane, targets)
    with ThreadPoolExecutor(max_workers=len(plan)) as pool:
        results = list(pool.map(run_bundle, plan))

    total = 0
    failed = []
    for target, code, output, seconds in results:
        counts = RUN_LINE.findall(output)
        count = int(counts[-1]) if counts else None
        if code == NO_MATCHING_TESTS and count is None and not output.strip():
            code, count = 0, 0
        if code != 0 or count is None:
            failed.append((target, code, output))
        total += count or 0
        print(f"  {target:32} {'?' if count is None else count:>4} tests  {seconds:6.1f} s  exit {code}")
    for target, code, output in failed:
        print(f"\n== {target} (exit {code}), last lines:\n" + "\n".join(output.strip().splitlines()[-30:]))
    print(f"{lane}: {total} tests in {len(plan)} bundles; build {built - started:.1f} s, tests {time.monotonic() - built:.1f} s")
    return 1 if failed else 0


if __name__ == "__main__":
    sys.exit(main())
