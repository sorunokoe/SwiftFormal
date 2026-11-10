"""Reproduce the 0.0.4 instruction-to-model correspondence experiment."""

import argparse
import copy
from datetime import datetime, timezone
import json
from pathlib import Path
import shutil
import signal
import sys
import time

from verify import ROOT, REFERENCE, check, generate, policy


BRIDGE = ROOT.parent / "compiler-bridge"
PREVIOUS = ROOT.parent / "lean-proof"
CONTRACT = PREVIOUS / "contract.json"


def snapshot():
    paths = [BRIDGE / name for name in ("Fixture.swift", "main.swift", "collect.py")]
    for package in (ROOT, PREVIOUS, ROOT.parent / "scalar-extraction"):
        paths.extend([package / "Package.swift", package / "VERSION"])
        paths.extend(package.glob("*.py"))
        for directory in ("Sources", "Tests"):
            paths.extend((package / directory).rglob("*.swift"))
            paths.extend((package / directory).rglob("*.lean"))
    paths.append(CONTRACT)
    return {str(path): policy.digest_file(path) for path in sorted(paths)}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output", type=Path, default=ROOT / ".artifacts")
    parser.add_argument("--lean", default="lean")
    args = parser.parse_args()
    output = args.output.resolve()
    report = {
        "schema_version": 1, "status": "running", "started_at": datetime.now(timezone.utc).isoformat(),
        "commands": [], "controls": [], "variants": [], "comparisons": [],
    }
    path = output / "report.json"
    policy.write_json(path, report)
    started = time.monotonic()
    commands = report["commands"]

    def run(argv, expected=(0,), timeout=180):
        result = policy.execute(argv, commands, cwd=ROOT, timeout=timeout)
        if result.returncode not in expected:
            raise RuntimeError(f"Unexpected exit {result.returncode}: {argv}\n{result.stdout}{result.stderr}")
        return result

    def save(directory, bundle):
        policy.write_json(directory / "bundle.json", bundle)
        for key in ("translation", "proof"):
            (directory / f"{key}.lean").write_text(bundle[key]["source"])

    try:
        report["experiment_version"] = (ROOT / "VERSION").read_text().strip()
        if report["experiment_version"] != "0.0.4":
            raise RuntimeError("Unsupported experiment version")
        report["source_sha256"] = snapshot()
        run([sys.executable, "-B", "-m", "unittest", "discover", "-s", ROOT, "-p", "test_*.py", "-v"])
        run(["swift", "test", "--package-path", ROOT])
        run(["swift", "build", "--package-path", ROOT, "--product", "translation-emitter"])
        binary_path = run(["swift", "build", "--package-path", ROOT, "--show-bin-path"]).stdout.strip()
        emitter = Path(binary_path) / "translation-emitter"
        report["emitter_sha256"] = policy.digest_file(emitter)
        environment = policy.LeanEnvironment(args.lean, commands)
        report["environment_sha256"] = environment.digest
        policy.write_json(output / "environment.json", environment.data)
        reference_test = "import Lean\n" + REFERENCE.read_text() + "\n" + (ROOT / "Tests/Lean/ReferenceIRTests.lean").read_text()
        report["reference_tests"] = environment.check_source(reference_test, ["ReferenceIRTests.instructionSemantics"])
        if report["reference_tests"]["status"] != "MODEL PROVED":
            raise RuntimeError(f"Reference instruction tests failed: {report['reference_tests']}")
        run([sys.executable, BRIDGE / "collect.py", "--output", output / "bridge"])
        collection = output / "bridge" / "report.json"
        bundle = generate(emitter, collection, BRIDGE, CONTRACT, commands)
        save(output, bundle)
        common = {
            "emitter": emitter, "collection": collection, "fixtures": BRIDGE, "contract": CONTRACT,
            "bundle": output / "bundle.json", "environment": environment, "commands": commands,
        }

        def attempt(**overrides):
            try:
                return check(**(common | overrides))
            except policy.CheckFailure as error:
                return {"status": error.status, "reason": str(error)}

        def require_status(result, expected, name):
            if result["status"] != expected:
                raise RuntimeError(f"Wrong result for {name}: {result}")
            return result

        def rejected(name, expected="INVALID EVIDENCE", **overrides):
            result = require_status(attempt(**overrides), expected, name)
            report["controls"].append({"name": name, "result": result})
            return result

        def compare_native(name, data, directory):
            if len(data["samples"]) != 51:
                raise RuntimeError("Incomplete boundary/input sample inventory")
            for sample in data["samples"]:
                for binary in ("oracle-debug", "oracle-release"):
                    native = run(
                        [directory / binary, "clamped", *sample["inputs"]],
                        expected=(0, -signal.SIGTRAP, -signal.SIGILL), timeout=10,
                    )
                    if native.returncode == 0:
                        observed = {"status": "RETURNED", "value": native.stdout.strip()}
                        agrees = sample["status"] == "RETURNED" and sample["value"] == observed["value"]
                    else:
                        observed = {"status": "ARITHMETIC TRAP", "signal": signal.Signals(-native.returncode).name}
                        agrees = sample["status"] == "ARITHMETIC TRAP"
                    report["comparisons"].append({
                        "variant": name, "binary": binary, "sample": sample, "native": observed, "agrees": agrees,
                    })
                    if not agrees:
                        raise RuntimeError(f"Native/IR disagreement: {report['comparisons'][-1]}")

        report["translation"] = require_status(attempt(translation_only=True), "TRANSLATION VALIDATED", "baseline translation")
        report["proof"] = require_status(attempt(), "IR CONTRACT PROVED", "baseline contract")
        report["obligations"] = bundle["proof"]["obligations"]
        compare_native("original", bundle, output / "bridge")

        for name, replacement in (("wrong-result", "subtotal"), ("overflow", "discount + 9223372036854775807")):
            directory = output / "controls" / name
            fixtures = directory / "fixtures"
            fixtures.mkdir(parents=True, exist_ok=True)
            original = (BRIDGE / "Fixture.swift").read_text()
            changed = original.replace(
                "    return subtotal - discount",
                f"    if subtotal < 50 {{\n        return {replacement}\n    }}\n    return subtotal - discount", 1,
            )
            if changed == original:
                raise RuntimeError("Source mutation did not change the selected body")
            (fixtures / "Fixture.swift").write_text(changed)
            shutil.copyfile(BRIDGE / "main.swift", fixtures / "main.swift")
            run([sys.executable, BRIDGE / "collect.py", "--fixtures", fixtures, "--output", directory / "bridge"])
            modified_collection = directory / "bridge" / "report.json"
            modified = generate(emitter, modified_collection, fixtures, CONTRACT, commands)
            save(directory, modified)
            inputs = {"collection": modified_collection, "fixtures": fixtures, "bundle": directory / "bundle.json"}
            translation = require_status(attempt(**inputs, translation_only=True), "TRANSLATION VALIDATED", name)
            contract_result = rejected(f"{name}-contract", "UNPROVED", **inputs)
            if any(name.startswith("SwiftFormalV004.") for name in contract_result["failed_obligations"]):
                raise RuntimeError("Contract control failed in translation/transfer rather than the business contract")
            rejected(f"{name}-stale-bundle", collection=modified_collection, fixtures=fixtures)
            rejected(f"{name}-stale-source", "INVALID ARTIFACT", fixtures=fixtures)
            report["variants"].append({
                "name": name, "translation": translation, "contract": contract_result,
                "old_collector_status": json.loads(modified_collection.read_text())["status"],
            })
            compare_native(name, modified, directory / "bridge")

        marker = "def implementation (subtotal discount : Int) : Outcome :=\n"
        body = bundle["modelSource"].split(marker, 1)[1].split("\n\nend SwiftFormalV003", 1)[0]
        mutations = [
            ("reversed-branch", body.replace("(subtotal < discount)", "(discount < subtotal)", 1), [10, 3]),
            ("addition-for-subtraction", body.replace("subtotal - discount", "subtotal + discount"), [10, 3]),
            ("ignored-overflow", body.replace("if Fits ((subtotal - discount)) then", "if True then", 1), [2**63 - 1, -1]),
            ("negative-input-only", body.replace("(0 : Int)", "(if subtotal < 0 then (1 : Int) else 0)", 1), [-10, -3]),
        ]
        source_mutations = []
        for name, mutated, witness in mutations:
            if mutated == body:
                raise RuntimeError(f"Translation mutation did not change the model: {name}")
            candidate = bundle["modelSource"].replace(marker + body, marker + mutated, 1)
            source_mutations.append((name, bundle["translation"]["source"].replace(bundle["modelSource"], candidate, 1), witness))
        for name, old, new, witness in (
            ("miswired-block-argument", "arguments := [9]", "arguments := [0]", [3, 10]),
            ("dropped-trap", ".trap 16", ".debug", [2**63 - 1, -1]),
        ):
            if old not in bundle["program"]:
                raise RuntimeError(f"Missing intended instruction mutation: {name}")
            modified_program = bundle["program"].replace(old, new, 1)
            source_mutations.append((name, bundle["translation"]["source"].replace(bundle["program"], modified_program, 1), witness))
        correspondence = bundle["translation"]["obligations"][0]["statement"]
        agreement = bundle["translation"]["obligations"][1]["statement"]
        for name, source, witness in source_mutations:
            (output / "controls" / f"{name}.lean").write_text(source)
            result = require_status(environment.check_source(source, bundle["translation"]["expectedTheorems"]), "UNPROVED", name)
            start = source[:source.index(correspondence)].count("\n") + 1
            end = source[:source.index(agreement)].count("\n") + 1
            if not any(
                item.get("kind") == "Tactic.unsolvedGoals" and start <= item.get("pos", {}).get("line", 0) < end
                for item in result["diagnostics"]
            ):
                raise RuntimeError(f"Mutation did not fail its correspondence obligation: {name}: {result}")
            prefix = source.split("set_option linter.unusedSimpArgs false in\n" + correspondence, 1)[0]
            counterexample = prefix + f"""
theorem mismatchAtWitness : Not (
    ReferenceIR.execute {bundle['fuel']} program ({witness[0]}) ({witness[1]}) =
      lift (SwiftFormalV003.implementation ({witness[0]}) ({witness[1]}))) := by decide
#print axioms SwiftFormalV004.mismatchAtWitness
end SwiftFormalV004
"""
            (output / "controls" / f"{name}-counterexample.lean").write_text(counterexample)
            witness_proof = require_status(
                environment.check_source(counterexample, ["SwiftFormalV004.mismatchAtWitness"]), "MODEL PROVED", f"{name} witness",
            )
            report["controls"].append({"name": name, "result": result, "witness": witness, "counterexample": witness_proof})

        for name, mutate in (
            ("missing-correspondence", lambda data: data["translation"]["expectedTheorems"].remove("SwiftFormalV004.correspondence")),
            ("altered-program", lambda data: data.update(program="def program : ReferenceIR.Program := []")),
            ("altered-interpreter-identity", lambda data: data.update(referenceSHA256="wrong")),
            ("altered-proof", lambda data: data["proof"].update(source=data["proof"]["source"] + "\n-- changed\n")),
        ):
            modified = copy.deepcopy(bundle)
            mutate(modified)
            altered = output / "controls" / f"{name}.json"
            policy.write_json(altered, modified)
            rejected(name, bundle=altered)
        rejected("missing-bundle", "MISSING PROOF", bundle=output / "missing-bundle.json")
        missing_report = output / "controls" / "missing-tool-verdict.json"
        policy.write_json(missing_report, {"status": "IR CONTRACT PROVED"})
        run([
            sys.executable, ROOT / "verify.py", "--emitter", emitter, "--collection", collection,
            "--fixtures", BRIDGE, "--contract", CONTRACT, "--bundle", output / "bundle.json",
            "--output", missing_report, "--lean", output / "missing-lean",
        ], expected=(1,))
        missing = json.loads(missing_report.read_text())
        require_status(missing, "TOOL ERROR", "missing Lean")
        report["controls"].append({"name": "missing-lean-invalidates-success", "result": missing})
        environment.validate_unchanged()
        if snapshot() != report["source_sha256"] or policy.digest_file(emitter) != report["emitter_sha256"]:
            raise RuntimeError("Experiment sources or emitter changed")
        if generate(emitter, collection, BRIDGE, CONTRACT, commands) != bundle:
            raise RuntimeError("Baseline inputs changed")
        report["status"] = "passed"
    except (policy.CheckFailure, OSError, ValueError, KeyError, TypeError, RuntimeError) as error:
        report.update(status="failed", failure=str(error))
    except KeyboardInterrupt:
        report.update(status="failed", failure="Experiment interrupted")
    report["elapsed_seconds"] = time.monotonic() - started
    policy.write_json(path, report)
    if report["status"] != "passed":
        print(f"SwiftFormal 0.0.4 translation experiment: FAIL\n{report['failure']}", file=sys.stderr)
        return 1
    print("SwiftFormal 0.0.4 translation experiment: PASS")
    print("TRANSLATION VALIDATED for all signed Int64 input pairs; IR CONTRACT PROVED for nonnegative inputs.")
    print(f"{len(report['proof']['axioms'])} contract theorem audits; {len(report['comparisons'])} native comparisons; {len(report['controls'])} controls.")
    print("The compiler, SIL reader, direct IR encoding, and reference semantics remain trusted.")
    print(f"Report: {path}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
