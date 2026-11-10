#!/usr/bin/env python3
"""The compiler-corpus lane (plan item V3): Scan on real compiler output at scale, against a checked-in baseline.

    python3 Scripts/corpus-lane.py [--sfverify PATH] [--jobs N] [--only SUBSTRING]... [--update]

It fetches the `.swift` tests of `test/SIL` and `test/SILOptimizer` of the pinned compiler's source
(swift-6.4.0-RELEASE, by commit SHA, with a blobless sparse fetch into .build/corpus/; nothing is vendored), runs
`sfverify --json` on each file, which compiles it with Scan's own flags, and checks:

- no crash (a signal) and no hang (more than --timeout seconds, default 120, per file);
- no `INVALID SIL` and no prover error on real compiler output, except the ones listed in the baseline's
  `knownInvalid` (which may only shrink);
- no verdict flip: per file, a hash of the sorted (symbol, status) pairs must equal the baseline's.

The baseline, Scripts/baseline/corpus.json, holds counts and per-file hashes only, never compiler test sources. It is
keyed to the compiler and the SDK: with a compiler outside `SILFrontendVersion.verifiedCompilers` the lane is skipped
with a warning. `--update` records a new baseline (review the printed differences first). `--only` limits the run to
files whose path contains the text, and compares only those (no counts, no --update). Use a release `sfverify`
(`swift build -c release --product sfverify`): a debug build is several times slower and can exceed the timeout.
"""
import argparse
import concurrent.futures
import hashlib
import json
import os
import pathlib
import re
import shutil
import signal
import subprocess
import sys
import time

ROOT = pathlib.Path(__file__).resolve().parent.parent
BASELINE = ROOT / "Scripts/baseline/corpus.json"
PIN = ROOT / "Sources/SFSIL/ProofCacheVersions.swift"
REPOSITORY = "https://github.com/swiftlang/swift.git"
TAG = "swift-6.4.0-RELEASE"
SHA = "b8189d766d86ad7fc8106787d6ce9e402f38dd72"
DIRECTORIES = ("test/SIL", "test/SILOptimizer")
BUDGET = "50000"


def git(directory, *arguments):
    subprocess.run([shutil.which("git") or "git", "-C", str(directory), *arguments], check=True, capture_output=True, text=True)


def fetch(directory):
    """A blobless, depth-1, sparse checkout of the corpus at SHA; reused when it is already there."""
    marker = directory / ".fetched"
    if marker.exists():
        return
    if directory.exists():
        shutil.rmtree(directory)
    directory.mkdir(parents=True)
    git(directory, "init", "-q")
    git(directory, "remote", "add", "origin", REPOSITORY)
    git(directory, "sparse-checkout", "set", "--no-cone", *[f"/{d}/**/*.swift" for d in DIRECTORIES])
    git(directory, "fetch", "-q", "--depth", "1", "--filter=blob:none", "origin", SHA)
    git(directory, "checkout", "-q", "--detach", SHA)
    head = subprocess.run([shutil.which("git") or "git", "-C", str(directory), "rev-parse", "HEAD"], capture_output=True, text=True).stdout.strip()
    if head != SHA:
        sys.exit(f"corpus-lane: fetched {head}, expected {SHA}")
    marker.write_text(SHA + "\n")


def toolchain():
    def out(*arguments):
        result = subprocess.run(["xcrun", *arguments], capture_output=True, text=True)
        return (result.stdout + result.stderr).strip()

    first = out("swiftc", "--version").splitlines()[0]
    compiler = first[first.index("Apple Swift") :] if "Apple Swift" in first else first
    return {"compiler": compiler, "sdk": out("--show-sdk-version") + " (" + out("--show-sdk-build-version") + ")"}


def scan(sfverify, path, relative, timeout):
    """One file: ("ok", functions) | ("no-compile", None) | ("error", message) | ("crash", message) | ("hang", None)."""
    arguments = [str(sfverify), "--module", "M", "--json", "--budget", BUDGET]
    if "parse-stdlib" in path.read_text(errors="replace"):
        arguments += ["--swiftc-arg", "-parse-stdlib"]
    started = time.time()
    process = subprocess.Popen(arguments + [str(path)], stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True, start_new_session=True)
    try:
        stdout, stderr = process.communicate(timeout=timeout)
    except subprocess.TimeoutExpired:
        os.killpg(process.pid, signal.SIGKILL)
        process.communicate()
        return relative, "hang", None, time.time() - started
    seconds = time.time() - started
    if process.returncode < 0:
        return relative, "crash", f"signal {-process.returncode}: {stderr.strip()[-300:]}", seconds
    if process.returncode == 2:
        if "COMPILER FAILED" in stderr:
            return relative, "no-compile", None, seconds
        return relative, "error", stderr.strip().splitlines()[-1][:300] if stderr.strip() else "exit 2", seconds
    try:
        report = json.loads(stdout)
    except json.JSONDecodeError:
        return relative, "crash", f"exit {process.returncode} without a JSON report: {stderr.strip()[-300:]}", seconds
    functions = [(f["symbol"], f["status"], f.get("detail", "")) for f in report["functions"]]
    return relative, "ok", functions, seconds


def is_invalid(status, detail):
    return status == "internalError" or detail.startswith("INVALID SIL")


def file_hash(outcome, payload):
    if outcome != "ok":
        return outcome if outcome != "error" else "error:" + hashlib.sha256(payload.encode()).hexdigest()[:12]
    pairs = sorted((symbol, status) for symbol, status, _ in payload)
    return hashlib.sha256(json.dumps(pairs).encode()).hexdigest()[:16]


def main():
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--sfverify", default=str(ROOT / ".build/release/sfverify"))
    parser.add_argument("--corpus", default=str(ROOT / f".build/corpus/swift-{SHA[:12]}"))
    parser.add_argument("--jobs", type=int, default=max(1, (os.cpu_count() or 2) // 2))
    parser.add_argument("--timeout", type=int, default=120)
    parser.add_argument("--only", action="append", default=[])
    parser.add_argument("--update", action="store_true")
    options = parser.parse_args()
    if options.update and options.only:
        sys.exit("corpus-lane: --update records the whole corpus; drop --only")

    found = toolchain()
    if found["compiler"] not in re.findall(r'"(Apple Swift version [^"]+)"', PIN.read_text()):
        message = f"corpus lane skipped: '{found['compiler']}' is not a pinned compiler"
        print(f"::warning::{message}" if os.environ.get("GITHUB_ACTIONS") else message)
        return 0
    sfverify = pathlib.Path(options.sfverify)
    if not sfverify.exists():
        sys.exit(f"corpus-lane: no {sfverify}; build it with swift build -c release --product sfverify")
    corpus = pathlib.Path(options.corpus)
    fetch(corpus)
    files = sorted(p for d in DIRECTORIES for p in (corpus / d).rglob("*.swift"))
    if options.only:
        files = [p for p in files if any(text in str(p.relative_to(corpus)) for text in options.only)]
    print(f"corpus lane: {len(files)} files at {TAG} ({SHA[:12]}), {options.jobs} jobs, {sfverify}", flush=True)

    started = time.time()
    results = {}
    with concurrent.futures.ThreadPoolExecutor(options.jobs) as pool:
        futures = [pool.submit(scan, sfverify, p, str(p.relative_to(corpus)), options.timeout) for p in files]
        for done, future in enumerate(concurrent.futures.as_completed(futures), 1):
            relative, outcome, payload, seconds = future.result()
            results[relative] = (outcome, payload, seconds)
            if done % 50 == 0:
                print(f"  {done}/{len(files)} files, {time.time() - started:.0f} s", flush=True)

    counts = {"files": len(results)}
    statuses = {}
    invalid = []
    failures = []
    for relative, (outcome, payload, seconds) in sorted(results.items()):
        counts[outcome] = counts.get(outcome, 0) + 1
        if outcome in ("crash", "hang"):
            failures.append(f"{outcome}: {relative}" + (f" ({payload})" if payload else f" (over {options.timeout} s)"))
        if outcome == "ok":
            for symbol, status, detail in payload:
                statuses[status] = statuses.get(status, 0) + 1
                if is_invalid(status, detail):
                    invalid.append(f"{relative} {symbol}: {detail[:160]}")
    counts["functions"] = sum(statuses.values())
    counts.update({f"status.{k}": v for k, v in sorted(statuses.items())})
    hashes = {relative: file_hash(outcome, payload) for relative, (outcome, payload, _) in results.items()}
    slowest = sorted(results.items(), key=lambda item: -item[1][2])[:3]
    print(f"corpus lane: {time.time() - started:.0f} s; " + ", ".join(f"{k} {v}" for k, v in counts.items()))
    print("  slowest: " + ", ".join(f"{r} {v[2]:.0f} s" for r, v in slowest))

    measured = {**found, "tag": TAG, "sha": SHA, "budget": int(BUDGET), "counts": counts, "knownInvalid": sorted(invalid), "files": dict(sorted(hashes.items()))}
    baseline = json.loads(BASELINE.read_text()) if BASELINE.exists() else None
    if options.update:
        BASELINE.write_text(json.dumps(measured, indent=0, sort_keys=True) + "\n")
        print(f"recorded {BASELINE.relative_to(ROOT)}")
        for failure in failures:
            print(f"  {failure}")
        return 0
    if baseline is None:
        print(f"no {BASELINE.relative_to(ROOT)}: run with --update")
        return 1
    for key in ("compiler", "sdk"):
        if baseline.get(key) != found[key]:
            failures.append(f"{key}: baseline '{baseline.get(key)}', here '{found[key]}' (rerun with --update and review)")
    known = set(baseline.get("knownInvalid", []))
    failures += [f"INVALID on real compiler output: {line}" for line in invalid if line not in known]
    for relative, value in sorted(hashes.items()):
        old = baseline["files"].get(relative)
        if old != value:
            outcome, payload, _ = results[relative]
            shown = ", ".join(f"{s.removeprefix('$s1M')[:24]}={st}" for s, st, _ in payload[:8]) if outcome == "ok" else payload or outcome
            failures.append(f"verdict flip: {relative}: baseline {old}, now {value} ({shown})")
    if not options.only and baseline.get("counts") != counts:
        print(f"counts changed: baseline {baseline.get('counts')}")
    if failures:
        print(f"corpus lane FAILED ({len(failures)}):")
        for failure in failures:
            print(f"  {failure}")
        return 1
    print("corpus lane ok")
    return 0


if __name__ == "__main__":
    sys.exit(main())
