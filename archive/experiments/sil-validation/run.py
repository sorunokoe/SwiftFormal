"""Reproduce the 0.0.5 independent raw-SIL decoding experiment."""

import argparse
import copy
from datetime import datetime, timezone
import json
from pathlib import Path
import shutil
import sys
import time

import cases
from verify import ROOT, READER, PROPOSALS, STATUSES, check, compose, generate, policy, upstream


BRIDGE = ROOT.parent / "compiler-bridge"
EXPORTER = ROOT.parent / "translation-validation"
CONTRACT = ROOT.parent / "lean-proof" / "contract.json"


def snapshot():
    paths = [BRIDGE / name for name in ("Fixture.swift", "main.swift", "collect.py")]
    for package in (ROOT, EXPORTER, ROOT.parent / "lean-proof", ROOT.parent / "scalar-extraction"):
        paths.append(package / "VERSION")
        if (package / "Package.swift").is_file():
            paths.append(package / "Package.swift")
        paths.extend(package.glob("*.py"))
        for directory in ("Sources", "Tests"):
            for extension in ("*.swift", "*.lean"):
                paths.extend((package / directory).rglob(extension))
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
        "commands": [], "controls": [],
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

    def save(directory, bundle):
        policy.write_json(directory / "bundle.json", bundle)
        for mode in STATUSES:
            (directory / f"{mode}.lean").write_text(bundle[mode]["source"])

    try:
        report["experiment_version"] = (ROOT / "VERSION").read_text().strip()
        if report["experiment_version"] != "0.0.5":
            raise RuntimeError("Unsupported experiment version")
        report["source_sha256"] = snapshot()
        for package in (ROOT, ROOT.parent / "lean-proof", EXPORTER):
            run([sys.executable, "-B", "-m", "unittest", "discover", "-s", package, "-p", "test_*.py", "-v"])
        run(["swift", "test", "--package-path", EXPORTER])
        run(["swift", "build", "--package-path", EXPORTER, "--product", "translation-emitter"])
        binary_path = run(["swift", "build", "--package-path", EXPORTER, "--show-bin-path"]).stdout.strip()
        emitter = Path(binary_path) / "translation-emitter"
        report["emitter_sha256"] = policy.digest_file(emitter)
        environment = policy.LeanEnvironment(args.lean, commands)
        report["environment_sha256"] = environment.digest
        policy.write_json(output / "environment.json", environment.data)
        run([sys.executable, "-B", BRIDGE / "collect.py", "--output", output / "bridge"])
        collection = output / "bridge" / "report.json"
        bundle = generate(emitter, collection, BRIDGE, CONTRACT, commands)
        save(output, bundle)
        report["raw_sil_bytes"] = (output / "bridge" / "sil-onone.sil").stat().st_size
        report["certified_chunks"] = bundle["chunks"]
        common = {
            "emitter": emitter, "collection": collection, "fixtures": BRIDGE, "contract": CONTRACT,
            "bundle": output / "bundle.json", "environment": environment, "commands": commands,
        }

        def attempt(**overrides):
            try:
                return check(**(common | overrides))
            except policy.CheckFailure as error:
                return {"status": error.status, "reason": str(error)}

        def rejected(name, status="INVALID EVIDENCE", **overrides):
            result = require(attempt(**overrides), status, name)
            report["controls"].append({"name": name, "result": result})
            return result

        for mode in ("handoff", "proof"):
            before = time.monotonic()
            report[mode] = require(attempt(mode=mode), STATUSES[mode], mode)
            report[mode]["elapsed_seconds"] = time.monotonic() - before
            policy.write_json(output / f"{mode}-verdict.json", report[mode])
        report["obligations"] = bundle["proof"]["obligations"]
        unit = "import Lean\n" + upstream.REFERENCE.read_text() + "\n" + READER.read_text()
        unit += "\n" + (ROOT / "Tests" / "ReaderTests.lean").read_text()
        report["unit"] = require(
            environment.check_source(unit, ["SILReaderTests.preservesOperandsAndBlockArguments"]),
            "MODEL PROVED", "reader unit",
        )
        for group, inventory in cases.inventory().items():
            source, names = cases.render(
                group, inventory, upstream.REFERENCE.read_text(), READER.read_text(), bundle["program"],
            )
            path = output / "controls" / f"reader-{group}.lean"
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_text(source)
            result = require(environment.check_source(source, names, timeout=180), "MODEL PROVED", group)
            report["controls"].append({
                "name": f"reader-{group}", "cases": list(inventory), "count": len(inventory), "result": result,
            })

        minimal_raw = cases.MODULE.encode()
        prior = upstream.generate(emitter, collection, BRIDGE, CONTRACT, commands)
        prior["silSHA256"] = policy.digest_bytes(minimal_raw)
        minimal = compose(prior, minimal_raw, READER.read_text())["handoff"]
        good = require(environment.check_source(minimal["source"], minimal["expectedTheorems"]),
                       "MODEL PROVED", "proposal fixture baseline")
        bad = minimal["source"].replace(
            "return Lean.toExpr state", "return Lean.toExpr { state with byteCount := state.byteCount + 1 }", 1,
        )
        if bad == minimal["source"]:
            raise RuntimeError("Proposal corruption did not change the helper")
        (output / "controls" / "wrong-native-proposal.lean").write_text(bad)
        result = require(environment.check_source(bad, minimal["expectedTheorems"]), "UNPROVED", "bad proposal")
        if not any("proved that the proposition" in message.get("data", "") for message in result["diagnostics"]):
            raise RuntimeError("Wrong proposal failed for an unexpected reason")
        report["controls"].append({"name": "wrong-native-proposal", "baseline": good, "result": result})

        variant = output / "controls" / "wrong-result"
        fixtures = variant / "fixtures"
        fixtures.mkdir(parents=True, exist_ok=True)
        original = (BRIDGE / "Fixture.swift").read_text()
        changed = original.replace(
            "    return subtotal - discount",
            "    if subtotal < 50 {\n        return subtotal\n    }\n    return subtotal - discount", 1,
        )
        if changed == original:
            raise RuntimeError("Swift mutation did not change the selected body")
        (fixtures / "Fixture.swift").write_text(changed)
        shutil.copyfile(BRIDGE / "main.swift", fixtures / "main.swift")
        run([sys.executable, "-B", BRIDGE / "collect.py", "--fixtures", fixtures, "--output", variant / "bridge"])
        modified_collection = variant / "bridge" / "report.json"
        modified = generate(emitter, modified_collection, fixtures, CONTRACT, commands)
        save(variant, modified)
        inputs = {"collection": modified_collection, "fixtures": fixtures, "bundle": variant / "bundle.json"}
        translation = require(attempt(**inputs, mode="translation"), STATUSES["translation"], "buggy body translation")
        contract = rejected("wrong-result-contract", "UNPROVED", **inputs)
        if not contract["failed_obligations"] or any(
            not name.startswith("SwiftFormalV003.") for name in contract["failed_obligations"]
        ):
            raise RuntimeError("Buggy body failed outside the business contract")
        report["variant"] = {
            "translation": translation, "contract": contract,
            "old_collector_status": json.loads(modified_collection.read_text())["status"],
        }
        rejected("stale-bundle", collection=modified_collection, fixtures=fixtures)
        rejected("stale-source", "INVALID ARTIFACT", fixtures=fixtures)
        for name, mutate in (
            ("missing-decoding-theorem", lambda data: data["proof"]["expectedTheorems"].remove("SwiftFormalV005.decodedProgram")),
            ("altered-reader-identity", lambda data: data.update(readerSHA256="wrong")),
            ("altered-proposal-identity", lambda data: data.update(proposalsSHA256="wrong")),
            ("altered-embedded-byte", lambda data: data["proof"].update(source=data["proof"]["source"].replace("115, 105, 108", "116, 105, 108", 1))),
            ("altered-proof", lambda data: data["proof"].update(source=data["proof"]["source"] + "\n-- modified\n")),
        ):
            altered = copy.deepcopy(bundle)
            mutate(altered)
            if altered == bundle:
                raise RuntimeError(f"Ineffective bundle corruption: {name}")
            path = output / "controls" / f"{name}.json"
            policy.write_json(path, altered)
            result = rejected(name, bundle=path)
            if "checker_returncode" in result:
                raise RuntimeError("Altered production bundle reached Lean")
        altered_bridge = output / "controls" / "changed-raw"
        shutil.copytree(output / "bridge", altered_bridge, dirs_exist_ok=True)
        sil = altered_bridge / "sil-onone.sil"
        sil.write_bytes(sil.read_bytes() + b"\n// changed raw bytes\n")
        rejected("changed-raw-against-old-collection", "INVALID ARTIFACT", collection=altered_bridge / "report.json")
        rejected("missing-bundle", "MISSING PROOF", bundle=output / "missing-bundle.json")
        missing_path = output / "controls" / "missing-tool-verdict.json"
        policy.write_json(missing_path, {"status": STATUSES["proof"]})
        run([
            sys.executable, "-B", ROOT / "verify.py", "--emitter", emitter, "--collection", collection,
            "--fixtures", BRIDGE, "--contract", CONTRACT, "--bundle", output / "bundle.json",
            "--output", missing_path, "--lean", output / "missing-lean",
        ], expected=(1,))
        missing = require(json.loads(missing_path.read_text()), "TOOL ERROR", "missing Lean")
        report["controls"].append({"name": "missing-tool-invalidates-success", "result": missing})
        environment.validate_unchanged()
        if snapshot() != report["source_sha256"] or policy.digest_file(emitter) != report["emitter_sha256"]:
            raise RuntimeError("Experiment sources or exporter changed during checking")
        if generate(emitter, collection, BRIDGE, CONTRACT, commands) != bundle:
            raise RuntimeError("Final regenerated bundle differs")
        report.update(status="passed", root_theorems=len(bundle["proof"]["expectedTheorems"]))
        report["control_count"] = sum(control.get("count", 1) for control in report["controls"])
    except (policy.CheckFailure, RuntimeError, OSError, ValueError, KeyError, TypeError) as error:
        report.update(status="failed", failure=str(error))
    except KeyboardInterrupt:
        report.update(status="failed", failure="Experiment interrupted")
    report["elapsed_seconds"] = time.monotonic() - started
    report["finished_at"] = datetime.now(timezone.utc).isoformat()
    policy.write_json(report_path, report)
    if report["status"] != "passed":
        print(f"SwiftFormal 0.0.5 SIL experiment: FAIL\n{report['failure']}")
        return 1
    print("SwiftFormal 0.0.5 SIL experiment: PASS")
    print("SIL CONTRACT PROVED: independent decoding of the complete compiler artifact.")
    print(f"{report['root_theorems']} root theorem audits; {report['certified_chunks']} checked byte chunks; "
          f"{report['control_count']} controls.")
    print(f"Report: {report_path}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
