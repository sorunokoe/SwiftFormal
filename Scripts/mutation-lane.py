#!/usr/bin/env python3
"""The mutation lane (plan item V6): the tests must notice a wrong S0, encoder trap plumbing or literal parser.

    python3 Scripts/mutation-lane.py                 every mutant (by hand; about 30 to 60 minutes in a debug build)
    python3 Scripts/mutation-lane.py --only M01,M10  some of them
    python3 Scripts/mutation-lane.py --check         offline: every mutant still applies to today's sources (safety net)
    python3 Scripts/mutation-lane.py --restore       put back a file left mutated by a killed run

Each mutant is an exact source replacement in the trusted semantic code (Sources/SFSemantics/S0.swift, the trap and
undefined-behaviour plumbing of the encoder (Sources/SFSIL/SILRun*.swift), literals in SILInstructionReaders.swift, failure detection in SILFunctionParser.swift).
For each one the lane applies it, builds the tests, and runs its killing tests, fastest first, stopping at the first
failure: the mutant is killed. A mutant that survives all of its tests, does not build, or no longer applies (the
code moved: update the mutant) fails the lane. Before mutating, every killing test must pass on the clean tree, or a
red tree would look like a perfect kill rate. The original file is restored after every mutant, also on Ctrl-C or
SIGTERM; a backup in .build/mutation-lane/ survives even a killed process (`--restore`).
"""
import argparse
import json
import pathlib
import re
import shutil
import signal
import subprocess
import sys
import time

ROOT = pathlib.Path(__file__).resolve().parent.parent
STATE = ROOT / ".build/mutation-lane"
BACKUP = STATE / "backup"
ACTIVE = STATE / "active.json"
S0 = "Sources/SFSemantics/S0.swift"
RUNARR = "Sources/SFSIL/SILRunArrays.swift"
RUNCALL = "Sources/SFSIL/SILRunCalls.swift"
PAR = "Sources/SFSIL/SILInstructionReaders.swift"
FUN = "Sources/SFSIL/SILFunctionParser.swift"

# Killing tests, fastest first (debug build). Swift Testing ids: Suite/test.
ENCODER = [
    "S0SlowTests/encoderMatchesInterpreterOnCastsAndWideValues",
    "S0SlowTests/encoderMatchesInterpreterThroughSolverOnSamples",
    "S0SlowTests/encoderMatchesInterpreterExhaustivelyAt8Bits",
]

# (id, file, old, new, what it breaks, killing tests)
MUTANTS = [
    ("M01", S0, "let bad = c.or(c.eq(b, c.constant(0, width: width)), c.and(isMin, minusOne))",
     "let bad = c.or(c.eq(b, c.constant(0, width: width)), c.and(c.and(isMin, minusOne), c.falseLit))",
     "encode sdiv/srem: INT_MIN / -1 no longer undefined", ENCODER),
    ("M02", S0, "case .shl: return ([c.shiftLeft(a, by: b)], c.shiftAmountOutOfRange(a, b))",
     "case .shl: return ([c.shiftLeft(a, by: b)], none)", "encode shl: oversize shift not undefined", ENCODER),
    ("M03", S0, "case .ugt: return ([flag(c.ult(b, a))], none)", "case .ugt: return ([flag(c.ult(a, b))], none)",
     "encode ugt: operands swapped", ENCODER),
    ("M04", S0, "case .sext: return ([c.signExtend(a, to: resultWidth)], none)",
     "case .sext: return ([c.zeroExtend(a, to: resultWidth)], none)", "encode sext as zext", ENCODER),
    ("M05", S0, "case .ssubOverflow: return ([c.subSigned(a, b), flag(c.signedSubOverflows(a, b))], none)",
     "case .ssubOverflow: return ([c.subSigned(a, b), flag(c.signedAddOverflows(a, b))], none)",
     "encode ssub overflow flag from add", ENCODER),
    ("M06", S0, "return ([op == .udiv ? q : r], c.eq(b, c.constant(0, width: width)))",
     "return ([op == .udiv ? q : r], none)", "encode udiv/urem: division by zero not undefined", ENCODER),
    ("M07", S0, "case .sle: return ([flag(c.sle(a, b))], none)", "case .sle: return ([flag(c.slt(a, b))], none)",
     "encode sle as slt (boundary)", ENCODER),
    ("M08", S0, "case .ashr: return b >= UInt64(width) ? .undefined : .values([UInt64(bitPattern: sa >> Int64(b)) & m])",
     "case .ashr: return b >= UInt64(width) ? .undefined : .values([a >> b])",
     "evaluate ashr as lshr (reference interpreter only)",
     ["S0Tests/interpreterMatchesNativeExhaustivelyAt8Bits", "S0FolderOracleTests"]),
    ("M09", S0, "case .umulOverflow: return ([c.mul(a, b, narrowing: false), flag(c.unsignedMulOverflows(a, b))], none)",
     "case .umulOverflow: return ([c.mul(a, b, narrowing: false), flag(c.signedMulOverflows(a, b))], none)",
     "encode umul overflow flag signed", ENCODER),
    ("M10", RUNARR,
     'let index = try intArgument(call, 1)\n            trap(-c.ult(index, n), site: call.site("Index out of range"))',
     'let index = try intArgument(call, 1)\n            trap(-c.ule(index, n), site: call.site("Index out of range"))',
     "array subscript get: index == count accepted (off by one)", ["SILArrayTests/indexOutOfRangeIsFound"]),
    ("M11", RUNCALL,
     "out.traps.append(TrapEvent(block: blockIndex, condition: c.and(at, result.trap), site: site))\n"
     "        live = c.and(live, -c.and(at, result.trap))",
     "live = c.and(live, -c.and(at, result.trap))",
     "callee traps dropped at call sites", ["TrapSiteTests/aTrapInACalleeIsReportedAtItsOwnLine"]),
    ("M12", PAR, "    let mask: UInt64 = w == 64 ? ~0 : (1 << UInt64(w)) - 1\n    return .literal(",
     "    let mask: UInt64 = w == 64 ? ~0 : (1 << UInt64(w - 1)) - 1\n    return .literal(",
     "integer_literal mask drops the top bit",
     ["SILArrayTests/aTrapThatDependsOnElementsIsUnknownNotABug", "SILFrontendTests/averageTrapsOnlyWhenTheSumOverflows"]),
    ("M13", FUN, '            return value == "-1" || value == "1" ? String(line[..<eq.lowerBound]) : nil',
     '            return value == "-1" || value == "1" || value == "0" ? String(line[..<eq.lowerBound]) : nil',
     "unconditional-failure detector also accepts a 0 literal",
     ["SILFailureBlockTests/aCondFailThatNeverFiresDoesNotMakeUnreachableATrap"]),
    ("M14", RUNCALL,
     "out.traps.append(TrapEvent(block: blockIndex, condition: c.and(live, v.bits[0]), site: .condFail(operand: id)))\n"
     "        live = c.and(live, -v.bits[0])",
     "out.traps.append(TrapEvent(block: blockIndex, condition: c.and(live, v.bits[0]), site: .condFail(operand: id)))",
     "cond_fail no longer stops execution (later traps reachable after failure)",
     ["SILFrontendTests/encodingsAgreeWithNativeExecution", "SILAggregateTests/encodingsAgreeWithNativeExecution"]),
]


class Interrupted(Exception):
    pass


def on_signal(number, _frame):
    raise Interrupted(f"signal {number}")


def stale():
    """Mutants whose `old` text no longer occurs exactly once in their file."""
    problems = []
    for mid, path, old, _new, desc, _killers in MUTANTS:
        count = (ROOT / path).read_text().count(old)
        if count != 1:
            problems.append(f"{mid} ({desc}): the original text occurs {count} times in {path}; update the mutant")
    return problems


def restore():
    if not ACTIVE.exists():
        return False
    path = ACTIVE.read_text().strip()
    shutil.copyfile(BACKUP / path, ROOT / path)
    ACTIVE.unlink()
    shutil.rmtree(BACKUP)
    return True


def swift(arguments, release, timeout):
    config = ["-c", "release", "-Xswiftc", "-enable-testing"] if release else []
    try:
        return subprocess.run(["swift", *arguments[:1], *config, *arguments[1:]], cwd=ROOT, capture_output=True, text=True, timeout=timeout)
    except subprocess.TimeoutExpired as error:
        return subprocess.CompletedProcess(error.cmd, 124, error.stdout or "", f"timed out after {timeout} s")


def tests_ran(result):
    """The number of tests Swift Testing ran (0 when the filter matched nothing)."""
    found = re.findall(r"Test run with (\d+) tests?", result.stdout + result.stderr)
    return sum(int(n) for n in found)


def build(release):
    return swift(["build", "--build-tests"], release, 3600)


def main():
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--only", default="")
    parser.add_argument("--check", action="store_true")
    parser.add_argument("--restore", action="store_true")
    parser.add_argument("--release", action="store_true", help="build and test in release (slower build, faster tests)")
    parser.add_argument("--timeout", type=int, default=1800, help="seconds per test run")
    options = parser.parse_args()

    if options.restore:
        print("restored the mutated file" if restore() else "nothing to restore")
        return 0
    problems = stale()
    if options.check:
        for problem in problems:
            print(problem)
        print(f"mutation lane: {len(MUTANTS)} mutants apply" if not problems else "mutation lane: stale mutants")
        return 1 if problems else 0
    if ACTIVE.exists():
        sys.exit("mutation-lane: a previous run left a file mutated; run with --restore first")
    if problems:
        for problem in problems:
            print(problem)
        return 1
    chosen = [m for m in MUTANTS if not options.only or m[0] in options.only.split(",")]
    files = sorted({m[1] for m in chosen})
    if subprocess.run(["git", "diff", "--quiet", "--", *files], cwd=ROOT).returncode != 0:
        sys.exit(f"mutation-lane: {', '.join(files)} have uncommitted changes; commit or stash them first")
    for number in (signal.SIGTERM, signal.SIGHUP):
        signal.signal(number, on_signal)

    print("mutation lane: building the clean tree", flush=True)
    clean = build(options.release)
    if clean.returncode != 0:
        sys.exit("mutation-lane: the clean tree does not build:\n" + clean.stderr[-2000:])
    for killer in sorted({k for m in chosen for k in m[5]}):
        result = swift(["test", "--skip-build", "--filter", killer], options.release, options.timeout)
        if tests_ran(result) == 0:
            sys.exit(f"mutation-lane: the killing test {killer} matches no test; fix its name")
        if result.returncode != 0:
            sys.exit(f"mutation-lane: the killing test {killer} fails on the clean tree")
    print(f"mutation lane: {len({k for m in chosen for k in m[5]})} killing tests pass on the clean tree", flush=True)

    rows, failed = [], False
    STATE.mkdir(parents=True, exist_ok=True)
    try:
        for mid, path, old, new, desc, killers in chosen:
            source = (ROOT / path).read_text()
            (BACKUP / path).parent.mkdir(parents=True, exist_ok=True)
            shutil.copyfile(ROOT / path, BACKUP / path)
            ACTIVE.write_text(path)
            started = time.time()
            try:
                (ROOT / path).write_text(source.replace(old, new))
                built = build(options.release)
                if built.returncode != 0:
                    rows.append((mid, "STILLBORN", desc, "-", time.time() - started))
                    failed = True
                    continue
                verdict, by = "SURVIVED", "-"
                for killer in killers:
                    result = swift(["test", "--skip-build", "--filter", killer], options.release, options.timeout)
                    if result.returncode != 0:
                        verdict, by = "KILLED", killer
                        break
                failed = failed or verdict != "KILLED"
                rows.append((mid, verdict, desc, by, time.time() - started))
            finally:
                (ROOT / path).write_text(source)
                ACTIVE.unlink()
            print(f"  {mid} {rows[-1][1]:9} {rows[-1][4]:5.0f} s  {desc}  [{rows[-1][3]}]", flush=True)
    except (KeyboardInterrupt, Interrupted) as reason:
        print(f"mutation lane: stopped ({reason}); sources restored")
        return 130
    finally:
        if BACKUP.exists():
            shutil.rmtree(BACKUP)
    dirty = subprocess.run(["git", "diff", "--quiet", "--", *files], cwd=ROOT).returncode != 0
    killed = sum(1 for r in rows if r[1] == "KILLED")
    summary = {"mutants": len(rows), "killed": killed, "rows": [dict(zip(("id", "verdict", "what", "killedBy", "seconds"), r)) for r in rows]}
    (STATE / "results.json").write_text(json.dumps(summary, indent=1) + "\n")
    print(f"mutation lane: {killed} of {len(rows)} killed ({100 * killed // max(1, len(rows))} %)")
    if dirty:
        print("mutation lane: a mutated file was not restored; run git diff")
        return 1
    # Leave the build matching the sources.
    build(options.release)
    return 1 if failed else 0


if __name__ == "__main__":
    sys.exit(main())
