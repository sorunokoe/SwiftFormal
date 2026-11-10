#!/usr/bin/env python3
"""Deterministic cost of the prover on Examples/Metrics, compared with Scripts/baseline/metrics.json.

    python3 Scripts/metrics.py                 compare with the baseline (exit 1 on a regression)
    python3 Scripts/metrics.py --record        write the baseline (review the diff, then commit it)
    python3 Scripts/metrics.py --out FILE      also write what was measured (for a report)

Per function: the verdict, solver conflicts, CNF variables and CNF clauses, all exact counts from `sfverify --json --stats`.
A verdict must be identical. Conflicts and clauses may grow by at most 10 percent. Wall time is printed, never compared.
It also checks that the JSON validates against docs/schemas/scan-report.schema.json, with and without --stats, and
with --mutate.
"""
import argparse
import json
import math
import pathlib
import subprocess
import sys

sys.path.insert(0, str(pathlib.Path(__file__).resolve().parent))
from validate_schema import check  # noqa: E402

ROOT = pathlib.Path(__file__).resolve().parent.parent
BASELINE = ROOT / "Scripts/baseline/metrics.json"
SCHEMA = ROOT / "docs/schemas/scan-report.schema.json"
SOURCE = "Examples/Metrics/Kernels.swift"
MODULE = "Metrics"
BUDGET = 20_000
TOLERANCE = 0.10
COMPARED = ("solverConflicts", "cnfClauses")


_built = False


def sfverify(*extra):
    global _built
    if not _built:
        # Same flags as the release test lanes (test-lane.sh), so alternating between them does not rebuild everything.
        build = ["swift", "build", "-c", "release", "-Xswiftc", "-enable-testing", "--product", "sfverify"]
        subprocess.run(build, cwd=ROOT, check=True, capture_output=True)
        _built = True
    command = [str(ROOT / ".build/release/sfverify"), "--module", MODULE, "--budget", str(BUDGET), "--json", *extra, SOURCE]
    # Exit code 1 means "a contract failed"; the report is still on stdout.
    result = subprocess.run(command, cwd=ROOT, capture_output=True, text=True)
    if result.returncode not in (0, 1):
        sys.exit(f"sfverify failed ({result.returncode}):\n{result.stderr}")
    return json.loads(result.stdout)


def measure():
    plain = sfverify("--only", "adder")
    bad = check(plain, SCHEMA)
    if bad or any("solverConflicts" in f for f in plain["functions"]):
        sys.exit("sfverify --json (without --stats) does not match the schema, or leaks stats keys:\n" + "\n".join(bad))
    mutated = sfverify("--mutate", "--only", "clamp")
    bad = check(mutated, SCHEMA)
    if bad or "weakContracts" not in mutated["summary"]:
        sys.exit("sfverify --json --mutate does not match the schema, or has no summary.weakContracts:\n" + "\n".join(bad))
    report = sfverify("--stats")
    bad = check(report, SCHEMA)
    if bad:
        sys.exit("sfverify --json --stats does not match docs/schemas/scan-report.schema.json:\n" + "\n".join(bad))
    functions = {}
    for f in report["functions"]:
        functions[f["name"]] = {
            "status": f["status"],
            "solverConflicts": f["solverConflicts"],
            "cnfVariables": f["cnfVariables"],
            "cnfClauses": f["cnfClauses"],
        }
    return functions, report["timing"]["verifySeconds"]


def compare(baseline, current):
    problems = []
    for name in sorted(set(baseline) | set(current)):
        if name not in current:
            problems.append(f"{name}: in the baseline but not measured")
        elif name not in baseline:
            problems.append(f"{name}: measured but not in the baseline (run with --record)")
        else:
            old, new = baseline[name], current[name]
            if old["status"] != new["status"]:
                problems.append(f"{name}: verdict changed from {old['status']} to {new['status']}")
            for key in COMPARED:
                limit = math.floor(old[key] * (1 + TOLERANCE))
                if new[key] > limit:
                    problems.append(f"{name}: {key} {old[key]} -> {new[key]} (limit {limit}, +{int(TOLERANCE * 100)}%)")
    return problems


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--record", action="store_true")
    parser.add_argument("--out", type=pathlib.Path)
    args = parser.parse_args()

    current, verify_seconds = measure()
    document = {
        "_note": "Deterministic prover cost per kernel (Scripts/metrics.py). Re-record with --record in the change that "
        "legitimately alters it, and explain why in the commit message.",
        "source": SOURCE,
        "conflictBudget": BUDGET,
        "functions": current,
    }
    print(f"{'function':28} {'status':14} {'conflicts':>9} {'variables':>9} {'clauses':>8}")
    for name, m in current.items():
        print(f"{name:28} {m['status']:14} {m['solverConflicts']:>9} {m['cnfVariables']:>9} {m['cnfClauses']:>8}")
    print(f"verify wall time {verify_seconds:.2f} s (informational, never compared)")
    if args.out:
        args.out.parent.mkdir(parents=True, exist_ok=True)
        args.out.write_text(json.dumps(document, indent=1, sort_keys=True) + "\n")
    if args.record:
        BASELINE.write_text(json.dumps(document, indent=1, sort_keys=True) + "\n")
        print(f"recorded {BASELINE.relative_to(ROOT)}")
        return
    baseline = json.loads(BASELINE.read_text())
    if baseline["conflictBudget"] != BUDGET:
        sys.exit("baseline was recorded with another conflict budget: run with --record")
    problems = compare(baseline["functions"], current)
    if problems:
        print("\nmetrics regression:")
        print("\n".join("  " + p for p in problems))
        sys.exit(1)
    print("\nmetrics within the baseline (status identical, conflicts and clauses within +10%)")


if __name__ == "__main__":
    main()
