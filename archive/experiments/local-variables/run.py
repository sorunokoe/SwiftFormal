"""Reproduce 0.0.6: local Swift variables under the unchanged discount contract."""

import argparse
import copy
from datetime import datetime, timezone
import importlib.util
import json
from pathlib import Path
import shutil
import signal
import sys
import time


ROOT = Path(__file__).resolve().parent
BRIDGE = ROOT.parent / "compiler-bridge"
EXPORTER = ROOT.parent / "translation-validation"
CONTRACT = ROOT.parent / "lean-proof" / "contract.json"
APPROVED_CONTRACT_SHA256 = "afffc343970ceb49c1b0d1917cab677ba3cc47ca8add17785d76ae588d3abd4b"
spec = importlib.util.spec_from_file_location(
    "swiftformal_sil_policy", ROOT.parent / "sil-validation" / "verify.py",
)
sil = importlib.util.module_from_spec(spec)
sys.modules[spec.name] = sil
spec.loader.exec_module(sil)
policy = sil.policy
UNIT_THEOREMS = [
    "LocalDebugTests." + name for name in (
        "acceptsParameterDebug", "acceptsLocalDebug", "acceptsLocatedLocalDebug",
        "returnsActualOperand", "rejectsUnsupportedDebugForms",
    )
]


def snapshot():
    paths = [BRIDGE / name for name in ("Fixture.swift", "main.swift", "collect.py")]
    for package in (
        ROOT, ROOT.parent / "sil-validation", EXPORTER,
        ROOT.parent / "lean-proof", ROOT.parent / "scalar-extraction",
    ):
        paths.append(package / "VERSION")
        if (package / "Package.swift").is_file():
            paths.append(package / "Package.swift")
        paths.extend(package.glob("*.py"))
        for directory in ("Sources", "Tests"):
            for extension in ("*.swift", "*.lean"):
                paths.extend((package / directory).rglob(extension))
    paths.append(CONTRACT)
    return {str(path): policy.digest_file(path) for path in sorted(paths)}


def variants(original):
    selected_return = "    return subtotal - discount\n"
    if original.count(selected_return) != 1:
        raise RuntimeError("Expected exactly one selected return to refactor")
    local = "    let result = subtotal - discount\n    return result\n"
    wrong = (
        "    let result = subtotal - discount\n"
        "    if subtotal < 50 {\n        return subtotal\n    }\n"
        "    return result\n"
    )
    return {
        "original": original,
        "local-result": original.replace(selected_return, local, 1),
        "wrong-return": original.replace(selected_return, wrong, 1),
    }


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output", type=Path, default=ROOT / ".artifacts")
    parser.add_argument("--lean", default="lean")
    args = parser.parse_args()
    output = args.output.resolve()
    report = {
        "schema_version": 1, "status": "running", "started_at": datetime.now(timezone.utc).isoformat(),
        "commands": [], "variants": {}, "comparisons": [], "controls": [],
    }
    report_path = output / "report.json"
    policy.write_json(report_path, report)
    started = time.monotonic()
    commands = report["commands"]

    def run(argv, expected=(0,), timeout=180):
        process = policy.execute(argv, commands, cwd=ROOT, timeout=timeout)
        if process.returncode not in expected:
            raise RuntimeError(f"Unexpected exit {process.returncode}: {argv}\n{process.stdout}{process.stderr}")
        return process

    def require(result, status, name):
        if result["status"] != status:
            raise RuntimeError(f"{name}: expected {status}: {result}")
        return result

    try:
        report["experiment_version"] = (ROOT / "VERSION").read_text().strip()
        if report["experiment_version"] != "0.0.6":
            raise RuntimeError("Unsupported experiment version")
        if policy.digest_file(CONTRACT) != APPROVED_CONTRACT_SHA256:
            raise RuntimeError("The approved contract changed")
        report["approved_contract_sha256"] = APPROVED_CONTRACT_SHA256
        report["source_sha256"] = snapshot()
        run([sys.executable, "-B", "-m", "unittest", "discover", "-s", ROOT, "-p", "test_*.py", "-v"])
        run(["swift", "test", "--package-path", ROOT.parent / "scalar-extraction"])
        run(["swift", "test", "--package-path", EXPORTER])
        run(["swift", "build", "--package-path", EXPORTER, "--product", "translation-emitter"])
        binary_path = run(["swift", "build", "--package-path", EXPORTER, "--show-bin-path"]).stdout.strip()
        emitter = Path(binary_path) / "translation-emitter"
        report["emitter_sha256"] = policy.digest_file(emitter)
        environment = policy.LeanEnvironment(args.lean, commands)
        report["environment_sha256"] = environment.digest
        policy.write_json(output / "environment.json", environment.data)

        unit = "import Lean\n" + sil.upstream.REFERENCE.read_text() + "\n" + sil.READER.read_text()
        unit += "\n" + (ROOT / "Tests" / "LocalDebugTests.lean").read_text()
        (output / "reader-tests.lean").write_text(unit)
        report["reader_tests"] = require(
            environment.check_source(unit, UNIT_THEOREMS), "MODEL PROVED", "local debug reader tests",
        )

        inputs = {}
        bundles = {}
        for name, source in variants((BRIDGE / "Fixture.swift").read_text()).items():
            directory = output / name
            fixtures = directory / "fixtures"
            fixtures.mkdir(parents=True, exist_ok=True)
            (fixtures / "Fixture.swift").write_text(source)
            shutil.copyfile(BRIDGE / "main.swift", fixtures / "main.swift")
            run([sys.executable, "-B", BRIDGE / "collect.py", "--fixtures", fixtures,
                 "--output", directory / "bridge"])
            collection = directory / "bridge" / "report.json"
            collected = require(json.loads(collection.read_text()), "passed", f"{name} native collector")
            bundle = sil.generate(emitter, collection, fixtures, CONTRACT, commands)
            if bundle["contractSHA256"] != APPROVED_CONTRACT_SHA256:
                raise RuntimeError("A variant used a different contract")
            bundles[name] = bundle
            policy.write_json(directory / "bundle.json", bundle)
            for mode in sil.STATUSES:
                (directory / f"{mode}.lean").write_text(bundle[mode]["source"])
            inputs[name] = {
                "emitter": emitter, "collection": collection, "fixtures": fixtures, "contract": CONTRACT,
                "bundle": directory / "bundle.json", "environment": environment, "commands": commands,
            }
            record = {
                "collector_status": collected["status"],
                "instruction_count": bundle["fuel"] - 1,
                "raw_sil_bytes": (directory / "bridge" / "sil-onone.sil").stat().st_size,
                "certified_chunks": bundle["chunks"],
                "proof_source_bytes": len(bundle["proof"]["source"].encode()),
                "root_theorems": len(bundle["proof"]["expectedTheorems"]),
            }
            report["variants"][name] = record
            if name == "wrong-return":
                record["translation"] = require(
                    sil.check(**inputs[name], mode="translation"),
                    sil.STATUSES["translation"], "wrong return still translates faithfully",
                )
                policy.write_json(directory / "translation-verdict.json", record["translation"])
            before = time.monotonic()
            record["proof"] = require(
                sil.check(**inputs[name]),
                "UNPROVED" if name == "wrong-return" else sil.STATUSES["proof"], name,
            )
            record["proof"]["elapsed_seconds"] = time.monotonic() - before
            policy.write_json(directory / "proof-verdict.json", record["proof"])
            if name == "wrong-return":
                failed = set(record["proof"]["failed_obligations"])
                returns = {entry["name"] for entry in bundle["proof"]["obligations"] if entry["kind"] == "return"}
                if not failed or not failed <= returns:
                    raise RuntimeError("Wrong return failed outside its return-value obligations")
            if len(bundle["samples"]) != 51:
                raise RuntimeError("Incomplete boundary/input sample inventory")
            for binary in ("oracle-debug", "oracle-release"):
                executable = directory / "bridge" / binary
                if policy.digest_file(executable) != collected["artifacts"][binary]:
                    raise RuntimeError("Native executable changed after collection")
                for sample in bundle["samples"]:
                    native = run(
                        [executable, "clamped", *sample["inputs"]],
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
                if policy.digest_file(executable) != collected["artifacts"][binary]:
                    raise RuntimeError("Native executable changed during comparison")

        if bundles["original"]["samples"] != bundles["local-result"]["samples"]:
            raise RuntimeError("The local refactor changed the recorded behavior")
        for name, expected in (("original", "7"), ("local-result", "7"), ("wrong-return", "10")):
            witness = next(item for item in bundles[name]["samples"] if item["inputs"] == ["10", "3"])
            if witness["status"] != "RETURNED" or witness["value"] != expected:
                raise RuntimeError(f"Unexpected actual return at the distinguishing input: {name}")
            report["variants"][name]["witness"] = witness

        altered = copy.deepcopy(bundles["local-result"])
        altered["proof"]["expectedTheorems"].remove("SwiftFormalV005.decodedProgram")
        altered_path = output / "controls" / "missing-decoding-theorem.json"
        policy.write_json(altered_path, altered)
        for name, path in (
            ("original-evidence-for-refactor", inputs["original"]["bundle"]),
            ("missing-decoding-theorem", altered_path),
        ):
            try:
                result = sil.check(**(inputs["local-result"] | {"bundle": path}))
            except policy.CheckFailure as error:
                result = {"status": error.status, "reason": str(error)}
            require(result, "INVALID EVIDENCE", name)
            if "checker_returncode" in result:
                raise RuntimeError("Invalid bundle reached Lean")
            report["controls"].append({"name": name, "result": result})

        for name, item in inputs.items():
            if sil.generate(emitter, item["collection"], item["fixtures"], CONTRACT, commands) != bundles[name]:
                raise RuntimeError(f"Final regenerated bundle differs: {name}")
            if json.loads(item["bundle"].read_text()) != bundles[name]:
                raise RuntimeError(f"Saved bundle changed: {name}")
        environment.validate_unchanged()
        if snapshot() != report["source_sha256"] or policy.digest_file(emitter) != report["emitter_sha256"]:
            raise RuntimeError("Experiment sources or exporter changed during checking")
        report["status"] = "passed"
    except (policy.CheckFailure, RuntimeError, OSError, ValueError, KeyError, TypeError, StopIteration) as error:
        report.update(status="failed", failure=str(error))
    except KeyboardInterrupt:
        report.update(status="failed", failure="Experiment interrupted")
    report["elapsed_seconds"] = time.monotonic() - started
    report["finished_at"] = datetime.now(timezone.utc).isoformat()
    policy.write_json(report_path, report)
    if report["status"] != "passed":
        print(f"SwiftFormal 0.0.6 local-variable experiment: FAIL\n{report['failure']}")
        return 1
    print("SwiftFormal 0.0.6 local-variable experiment: PASS")
    print("Original and local refactor: SIL CONTRACT PROVED under the same frozen contract.")
    print("Wrong return: SIL TRANSLATION VALIDATED, business contract UNPROVED.")
    print(f"{len(report['comparisons'])} native comparisons agree; 5 reader theorem audits; "
          f"{len(report['controls'])} evidence controls.")
    print(f"Report: {report_path}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
