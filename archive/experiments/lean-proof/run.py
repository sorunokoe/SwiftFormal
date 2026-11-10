"""Run the source-linked, single-contract 0.0.3 Lean proof experiment."""

import argparse
import copy
from datetime import datetime, timezone
import json
from pathlib import Path
import shutil
import signal
import sys
import time

from check import CheckFailure, LeanEnvironment, digest_file, execute, generate, verify, write_json


ROOT = Path(__file__).resolve().parent
BRIDGE = ROOT.parent / "compiler-bridge"
EXTRACTION = ROOT.parent / "scalar-extraction"


def source_snapshot():
    paths = [
        ROOT / "VERSION", ROOT / "Package.swift", ROOT / "contract.json",
        *ROOT.glob("*.py"), *(ROOT / "Sources").rglob("*.swift"), *(ROOT / "Tests").rglob("*.swift"),
        EXTRACTION / "Package.swift", *(EXTRACTION / "Sources").rglob("*.swift"),
        BRIDGE / "collect.py", BRIDGE / "Fixture.swift", BRIDGE / "main.swift",
    ]
    return {str(path): digest_file(path) for path in sorted(paths)}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output", type=Path, default=ROOT / ".artifacts")
    parser.add_argument("--lean", default="lean")
    args = parser.parse_args()
    output = args.output.resolve()
    report = {
        "schema_version": 1, "status": "running",
        "started_at": datetime.now(timezone.utc).isoformat(), "commands": [], "controls": [],
    }
    report_path = output / "report.json"
    write_json(report_path, report)
    before = time.monotonic()
    commands = report["commands"]

    def run(argv, expected=(0,), timeout=180):
        process = execute(argv, commands, cwd=ROOT, timeout=timeout)
        if process.returncode not in expected:
            raise RuntimeError(f"Unexpected exit {process.returncode}: {argv}\n{process.stdout}{process.stderr}")
        return process

    try:
        report["experiment_version"] = (ROOT / "VERSION").read_text().strip()
        if report["experiment_version"] != "0.0.3":
            raise RuntimeError("Unsupported experiment version")
        report["source_sha256"] = source_snapshot()
        run([sys.executable, "-B", "-m", "unittest", "discover", "-s", ROOT, "-p", "test_*.py", "-v"])
        run(["swift", "test", "--package-path", ROOT, "--quiet"])
        run(["swift", "build", "--package-path", ROOT, "--product", "proof-emitter"])
        binary_path = run(["swift", "build", "--package-path", ROOT, "--show-bin-path"]).stdout.strip()
        emitter = Path(binary_path) / "proof-emitter"
        report["emitter_sha256"] = digest_file(emitter)
        environment = LeanEnvironment(args.lean, commands)
        write_json(output / "environment.json", environment.data)
        report["environment_sha256"] = environment.digest
        run([sys.executable, BRIDGE / "collect.py", "--output", output / "bridge"])
        collection = output / "bridge" / "report.json"
        contract = ROOT / "contract.json"
        bundle_path = output / "bundle.json"
        bundle = generate(emitter, collection, BRIDGE, contract, commands)
        write_json(bundle_path, bundle)
        (output / "Generated.lean").write_text(bundle["proof"]["source"])
        common = {
            "emitter": emitter, "collection": collection, "fixtures": BRIDGE, "contract": contract,
            "bundle_path": bundle_path, "environment": environment, "commands": commands,
        }

        def check(**overrides):
            try:
                return verify(**(common | overrides))
            except CheckFailure as error:
                return {"status": error.status, "reason": str(error)}

        def rejected(name, status, **overrides):
            result = check(**overrides)
            if result["status"] != status:
                raise RuntimeError(f"Wrong outcome for {name}: {result}")
            report["controls"].append({"name": name, "result": result})
            return result

        report["proof"] = check()
        if report["proof"]["status"] != "MODEL PROVED":
            raise RuntimeError(f"Baseline proof failed: {report['proof']}")
        if len(report["proof"]["axioms"]) != 6:
            raise RuntimeError("Unexpected baseline theorem inventory")
        report["obligations"] = bundle["proof"]["obligations"]
        report["native_baseline"] = []
        for binary in ("oracle-debug", "oracle-release"):
            native = run([output / "bridge" / binary, "clamped", "10", "3"])
            if native.stdout.strip() != "7":
                raise RuntimeError("Unexpected native baseline")
            report["native_baseline"].append({"binary": binary, "inputs": ["10", "3"], "value": "7"})

        for name, replacement, failure_kind in (
            ("wrong-result", "subtotal", "return_"),
            ("overflow", "discount + 9223372036854775807", "safety_"),
        ):
            directory = output / "controls" / name
            fixtures = directory / "fixtures"
            fixtures.mkdir(parents=True, exist_ok=True)
            original = (BRIDGE / "Fixture.swift").read_text()
            changed = original.replace(
                "    return subtotal - discount",
                f"    if subtotal < 50 {{\n        return {replacement}\n    }}\n    return subtotal - discount",
                1,
            )
            if changed == original:
                raise RuntimeError("Mutation did not change the intended function")
            (fixtures / "Fixture.swift").write_text(changed)
            shutil.copyfile(BRIDGE / "main.swift", fixtures / "main.swift")
            run([sys.executable, BRIDGE / "collect.py", "--fixtures", fixtures, "--output", directory / "bridge"])
            changed_collection = directory / "bridge" / "report.json"
            changed_bundle = generate(emitter, changed_collection, fixtures, contract, commands)
            changed_path = directory / "bundle.json"
            write_json(changed_path, changed_bundle)
            (directory / "Generated.lean").write_text(changed_bundle["proof"]["source"])
            if changed_bundle["proof"]["model"] == bundle["proof"]["model"]:
                raise RuntimeError("Changed Swift did not change the generated model")
            rejected(f"{name}-stale-bundle", "INVALID EVIDENCE", collection=changed_collection, fixtures=fixtures)
            rejected(f"{name}-stale-source", "INVALID ARTIFACT", fixtures=fixtures)
            result = rejected(
                f"{name}-unproved", "UNPROVED",
                collection=changed_collection, fixtures=fixtures, bundle_path=changed_path,
            )
            if not any(f".{failure_kind}" in item for item in result["failed_obligations"]):
                raise RuntimeError(f"The intended {failure_kind} obligation did not fail: {result}")
            control = report["controls"][-1]
            control["old_collector_status"] = json.loads(changed_collection.read_text())["status"]
            control["native_replays"] = []
            for binary in ("oracle-debug", "oracle-release"):
                native = run(
                    [directory / "bridge" / binary, "clamped", "10", "3"],
                    expected=(0, -signal.SIGTRAP, -signal.SIGILL), timeout=10,
                )
                if name == "wrong-result":
                    if native.returncode != 0 or native.stdout.strip() != "10":
                        raise RuntimeError("Wrong-result mutation was not reproduced")
                    observed = {"value": "10"}
                else:
                    if native.returncode not in (-signal.SIGTRAP, -signal.SIGILL):
                        raise RuntimeError("Overflow mutation did not trap")
                    observed = {"signal": signal.Signals(-native.returncode).name}
                control["native_replays"].append({"binary": binary, "inputs": ["10", "3"], **observed})

        rejected("missing-bundle", "MISSING PROOF", bundle_path=output / "missing-bundle.json")
        for name, mutate in (
            ("altered-model", lambda proof: proof.update(model="def implementation := 0")),
            ("altered-proof", lambda proof: proof.update(source=proof["source"].replace("by decide", "by sorry", 1))),
            ("weakened-statement", lambda proof: proof["obligations"][-2].update(statement="theorem totalCorrectness : True")),
            ("missing-theorem", lambda proof: proof["expectedTheorems"].pop()),
            ("empty-inventory", lambda proof: proof.update(expectedTheorems=[], obligations=[])),
            ("missing-source", lambda proof: proof.pop("source")),
        ):
            modified = copy.deepcopy(bundle)
            mutate(modified["proof"])
            path = output / "controls" / f"{name}.json"
            write_json(path, modified)
            rejected(name, "INVALID EVIDENCE", bundle_path=path)

        for name, change in (
            ("false-precondition", {"requires": "False"}),
            ("weakened-contract", {"ensures": "always-zero"}),
            ("changed-witness", {"witness": ["1", "0"]}),
        ):
            path = output / "controls" / f"{name}.json"
            write_json(path, json.loads(contract.read_text()) | change)
            status = "INVALID EVIDENCE" if name == "changed-witness" else "INVALID CONTRACT"
            rejected(name, status, contract=path)
        negative_witness = output / "controls" / "negative-witness.json"
        write_json(negative_witness, json.loads(contract.read_text()) | {"witness": ["-1", "0"]})
        witness_bundle = output / "controls" / "negative-witness-bundle.json"
        write_json(witness_bundle, generate(emitter, collection, BRIDGE, negative_witness, commands))
        witness_result = rejected("failed-witness", "UNPROVED", contract=negative_witness, bundle_path=witness_bundle)
        if "SwiftFormalV003.preconditionWitness" not in witness_result["failed_obligations"]:
            raise RuntimeError("Non-vacuity witness did not fail")

        configuration = json.loads(collection.read_text())
        configuration["compiler_version"] = "Unrecognized compiler"
        bad_configuration = collection.parent / "unknown-configuration.json"
        write_json(bad_configuration, configuration)
        rejected("unknown-configuration", "INVALID ARTIFACT", collection=bad_configuration)

        policy_sources = [
            ("sorry", "theorem claim : False := by sorry\n#print axioms claim\n", ["claim"]),
            ("foreign-axiom", "axiom inventedAssumption : False\ntheorem claim : False := inventedAssumption\n#print axioms claim\n", ["claim"]),
            ("native-evaluation", "theorem claim : 1 + 1 = 2 := by native_decide\n#print axioms claim\n", ["claim"]),
            ("missing-theorem-audit", "", ["claim"]),
        ]
        for name, source, names in policy_sources:
            result = environment.check_source("import Lean\n" + source, names)
            if result["checker_returncode"] != 0 or result["status"] != "UNPROVED":
                raise RuntimeError(f"Zero-exit acceptance control failed: {name}: {result}")
            report["controls"].append({"name": name, "result": result})

        missing_tool_report = output / "controls" / "missing-tool-verdict.json"
        write_json(missing_tool_report, {"status": "MODEL PROVED"})
        run([
            sys.executable, ROOT / "check.py", "--emitter", emitter, "--collection", collection,
            "--fixtures", BRIDGE, "--contract", contract, "--bundle", bundle_path,
            "--lean", output / "missing-lean", "--output", missing_tool_report,
        ], expected=(1,))
        missing_tool = json.loads(missing_tool_report.read_text())
        if missing_tool["status"] != "TOOL ERROR":
            raise RuntimeError("Missing tool retained a prior successful verdict")
        report["controls"].append({"name": "missing-lean-invalidates-success", "result": missing_tool})
        environment.validate_unchanged()
        if source_snapshot() != report["source_sha256"] or digest_file(emitter) != report["emitter_sha256"]:
            raise RuntimeError("Experiment sources or emitter changed during the run")
        if generate(emitter, collection, BRIDGE, contract, commands) != bundle:
            raise RuntimeError("Baseline inputs changed during the experiment")
        report["status"] = "passed"
    except (CheckFailure, OSError, ValueError, KeyError, TypeError, RuntimeError) as error:
        report.update(status="failed", failure=str(error))
    except KeyboardInterrupt:
        report.update(status="failed", failure="Experiment interrupted")
    report["elapsed_seconds"] = time.monotonic() - before
    write_json(report_path, report)
    if report["status"] != "passed":
        print(f"SwiftFormal 0.0.3 proof experiment: FAIL\n{report['failure']}", file=sys.stderr)
        return 1
    print("SwiftFormal 0.0.3 proof experiment: PASS")
    print("MODEL PROVED: exact clamped subtraction and no modeled trap for all nonnegative Int64 inputs.")
    print(f"{len(report['proof']['axioms'])} theorem audits; {len(report['controls'])} negative controls.")
    print("The compiler and Swift-to-Lean translation remain trusted.")
    print(f"Report: {report_path}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
