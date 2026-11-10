"""Measure ordinary Swift control flow and shared-branch expansion without weakening proofs."""

import argparse
from datetime import datetime, timezone
import importlib.util
import json
from pathlib import Path
import shutil
import signal
import subprocess
import sys
import time

import cases


ROOT = Path(__file__).resolve().parent
spec = importlib.util.spec_from_file_location(
    "swiftformal_local_experiment", ROOT.parent / "local-variables" / "run.py",
)
base = importlib.util.module_from_spec(spec)
sys.modules[spec.name] = base
spec.loader.exec_module(base)
sil = base.sil
policy = base.policy
SUCCESS = {
    "model": "MODEL PROVED",
    "translation": "TRANSLATION VALIDATED",
    "decoding": "SIL HANDOFF VALIDATED",
    "full": "SIL CONTRACT PROVED",
}


def snapshot():
    return base.snapshot() | {
        str(path): policy.digest_file(path)
        for path in sorted([ROOT / "VERSION", *ROOT.glob("*.py")])
    }


def select_inventory(inventory, requested):
    names = {entry[0] for entry in inventory}
    if set(requested) - names:
        raise ValueError(f"Unknown cases: {sorted(set(requested) - names)}")
    selected = set(requested) | {"original"} if requested else names
    return [entry for entry in inventory if entry[0] in selected]


def measure(checker, commands, source):
    first = len(commands)
    started = time.monotonic()
    try:
        verdict = checker()
    except policy.CheckFailure as error:
        if not isinstance(error.__cause__, subprocess.TimeoutExpired):
            raise
        verdict = {"status": "LIMIT", "limit": "timeout", "reason": str(error)}
    elapsed = time.monotonic() - started
    digest = policy.digest_bytes(source.encode())
    executions = [
        item for item in commands[first:]
        if item.get("stdin_sha256") == digest
    ]
    if len(executions) != 1:
        raise RuntimeError("Expected exactly one Lean execution for the measured source")
    lean = executions[0]["elapsed_seconds"]
    return {
        "verdict": verdict, "elapsed_seconds": elapsed, "lean_seconds": lean,
        "overhead_seconds": elapsed - lean, "source_sha256": digest,
        "command_start": first, "command_count": len(commands) - first,
    }


def assess(kind, phases, return_names):
    if set(phases) != set(SUCCESS):
        raise RuntimeError("Missing measured proof phase")
    statuses = {name: phase["verdict"]["status"] for name, phase in phases.items()}
    if any(status not in (SUCCESS[name], "UNPROVED", "LIMIT") for name, status in statuses.items()):
        raise RuntimeError(f"Unexpected proof outcome: {statuses}")
    if kind == "growth":
        return "PROVED" if statuses["full"] == SUCCESS["full"] else "UNKNOWN"
    if kind == "ordinary" and statuses == SUCCESS:
        return "PROVED"
    if kind == "seeded" and statuses == SUCCESS | {"model": "UNPROVED", "full": "UNPROVED"}:
        for name in ("model", "full"):
            failed = set(phases[name]["verdict"]["failed_obligations"])
            if not failed or not failed <= return_names:
                raise RuntimeError("Seeded defect failed outside its return-value obligations")
        return "REJECTED"
    raise RuntimeError(f"Unexpected {kind} case outcome: {statuses}")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output", type=Path, default=ROOT / ".artifacts")
    parser.add_argument("--lean", default="lean")
    parser.add_argument("--case", action="append", default=[], help="Check a named case plus the original baseline; repeatable")
    args = parser.parse_args()
    output = args.output.resolve()
    report = {
        "schema_version": 1, "status": "running", "started_at": datetime.now(timezone.utc).isoformat(),
        "commands": [], "cases": {}, "comparisons": [],
    }
    report_path = output / "report.json"
    policy.write_json(report_path, report)
    commands = report["commands"]
    started = time.monotonic()

    def run(argv, expected=(0,), timeout=180):
        process = policy.execute(argv, commands, cwd=ROOT, timeout=timeout)
        if process.returncode not in expected:
            raise RuntimeError(f"Unexpected exit {process.returncode}: {argv}\n{process.stdout}{process.stderr}")
        return process

    try:
        if (ROOT / "VERSION").read_text().strip() != "0.0.7":
            raise RuntimeError("Unsupported experiment version")
        report["experiment_version"] = "0.0.7"
        if policy.digest_file(base.CONTRACT) != base.APPROVED_CONTRACT_SHA256:
            raise RuntimeError("The approved contract changed")
        report["approved_contract_sha256"] = base.APPROVED_CONTRACT_SHA256
        report["source_sha256"] = snapshot()
        run([sys.executable, "-B", "-m", "unittest", "discover", "-s", ROOT, "-p", "test_*.py", "-v"])
        emitters = {}
        for package, product in (("lean-proof", "proof-emitter"), ("translation-validation", "translation-emitter")):
            package_path = ROOT.parent / package
            run(["swift", "build", "--package-path", package_path, "--product", product])
            binary_path = run(["swift", "build", "--package-path", package_path, "--show-bin-path"]).stdout.strip()
            emitters[product] = Path(binary_path) / product
        report["emitter_sha256"] = {str(path): policy.digest_file(path) for path in emitters.values()}
        environment = policy.LeanEnvironment(args.lean, commands)
        policy.write_json(output / "environment.json", environment.data)
        report["environment_sha256"] = environment.digest
        report["setup_seconds"] = time.monotonic() - started
        report["proof_timeouts_seconds"] = {"model": 60, "translation": 60, "decoding": 180, "full": 180}
        original = (base.BRIDGE / "Fixture.swift").read_text()
        inventory = (
            [(name, "ordinary", body, None) for name, body in cases.ordinary().items()]
            + [(name, "seeded", body, None) for name, body in cases.wrong_returns().items()]
            + [(f"diamonds-{count}", "growth", cases.diamonds(count), count) for count in (1, 2, 4, 8)]
            + [(name, "unsupported", body, None) for name, body in cases.extra_syntax().items()]
        )
        selected = select_inventory(inventory, args.case)
        report["requested_cases"] = args.case
        report["scheduled_cases"] = [entry[0] for entry in selected]
        report["matrix_complete"] = len(selected) == len(inventory)
        baseline_samples = None
        final_inputs = []
        for name, kind, body, count in selected:
            print(f"Checking {name} ({kind})", flush=True)
            directory = output / name
            fixtures = directory / "fixtures"
            fixtures.mkdir(parents=True, exist_ok=True)
            (fixtures / "Fixture.swift").write_text(cases.fixture(original, body))
            shutil.copyfile(base.BRIDGE / "main.swift", fixtures / "main.swift")
            before = time.monotonic()
            run([sys.executable, "-B", base.BRIDGE / "collect.py", "--fixtures", fixtures,
                 "--output", directory / "bridge"])
            collection = directory / "bridge" / "report.json"
            collected = json.loads(collection.read_text())
            if collected["status"] != "passed":
                raise RuntimeError(f"Native collector failed: {name}")
            record = {
                "kind": kind, "additional_diamonds": count, "phases": {},
                "collection_seconds": time.monotonic() - before,
                "collection_sha256": policy.digest_file(collection),
                "fixture_sha256": collected["source_sha256"],
                "collector_status": collected["status"],
            }
            report["cases"][name] = record
            generated = {}
            for product, generator in (
                ("proof-emitter", policy.generate), ("translation-emitter", sil.upstream.generate),
            ):
                before = time.monotonic()
                try:
                    bundle = generator(emitters[product], collection, fixtures, base.CONTRACT, commands)
                    generated[product] = bundle
                    policy.write_json(directory / f"{product}.json", bundle)
                    outcome = {"status": "GENERATED"}
                except policy.CheckFailure as error:
                    outcome = {"status": error.status, "reason": str(error)}
                record[product] = outcome | {"elapsed_seconds": time.monotonic() - before}
            if kind == "unsupported":
                marker = {"guard-greater-equal": "cmp_sge_Int64", "deferred-initialization": "alloc_stack"}[name]
                if any(
                    record[product]["status"] != "UNSUPPORTED" or marker not in record[product]["reason"]
                    for product in emitters
                ):
                    raise RuntimeError(f"Unsupported syntax did not fail for the expected instruction: {record}")
                record["status"] = "UNSUPPORTED"
                policy.write_json(report_path, report)
                continue
            if set(generated) != set(emitters):
                raise RuntimeError(f"Supported fixture could not generate its proof: {record}")
            model, prior = generated["proof-emitter"], generated["translation-emitter"]
            if model["proof"]["modelSource"] != prior["modelSource"]:
                raise RuntimeError("Model and translation phases used different models")
            if any(data["contractSHA256"] != base.APPROVED_CONTRACT_SHA256 for data in generated.values()):
                raise RuntimeError("A phase used a different contract")
            raw = (directory / "bridge" / "sil-onone.sil").read_bytes()
            before = time.monotonic()
            full = sil.compose(prior, raw, sil.READER.read_text())
            record["composition_seconds"] = time.monotonic() - before
            policy.write_json(directory / "bundle.json", full)
            sources = {
                "model": model["proof"]["source"], "translation": prior["translation"]["source"],
                "decoding": full["handoff"]["source"], "full": full["proof"]["source"],
            }
            for phase, source in sources.items():
                (directory / f"{phase}.lean").write_text(source)
            returns = {item["name"] for item in model["proof"]["obligations"] if item["kind"] == "return"}
            record["metrics"] = {
                "ir_instructions": prior["fuel"] - 1, "ir_conditionals": prior["program"].count(".conditional"),
                "raw_sil_bytes": len(raw), "certified_chunks": full["chunks"],
                "model_bytes": len(model["proof"]["model"].encode()), "return_obligations": len(returns),
                "proof_bytes": {phase: len(source.encode()) for phase, source in sources.items()},
                "full_root_obligations": len(full["proof"]["expectedTheorems"]),
            }
            if kind == "growth" and (
                record["metrics"]["ir_conditionals"] != count + 1 or len(returns) != 2 ** (count + 1)
            ):
                raise RuntimeError("Compiler/model no longer has the intended shared-diamond structure")
            common = {
                "collection": collection, "fixtures": fixtures, "contract": base.CONTRACT,
                "environment": environment, "commands": commands,
            }
            checks = {
                "model": lambda: policy.verify(
                    emitters["proof-emitter"], collection, fixtures, base.CONTRACT,
                    directory / "proof-emitter.json", environment, commands,
                ),
                "translation": lambda: sil.upstream.check(
                    emitter=emitters["translation-emitter"], bundle=directory / "translation-emitter.json",
                    **common, translation_only=True,
                ),
                "decoding": lambda: sil.check(
                    emitter=emitters["translation-emitter"], bundle=directory / "bundle.json",
                    **common, mode="handoff",
                ),
                "full": lambda: sil.check(
                    emitter=emitters["translation-emitter"], bundle=directory / "bundle.json", **common,
                ),
            }
            for phase, checker in checks.items():
                measured = measure(checker, commands, sources[phase])
                record["phases"][phase] = measured
                policy.write_json(directory / f"{phase}-verdict.json", measured)
                print(f"  {phase}: {measured['verdict']['status']} "
                      f"(Lean {measured['lean_seconds']:.3f}s; bound {measured['elapsed_seconds']:.3f}s)", flush=True)
                policy.write_json(report_path, report)
            record["status"] = assess(kind, record["phases"], returns)
            if baseline_samples is None:
                baseline_samples = prior["samples"]
            if kind in ("ordinary", "growth") and prior["samples"] != baseline_samples:
                raise RuntimeError(f"An equivalent fixture changed its signed-input observations: {name}")
            if len(prior["samples"]) != 51:
                raise RuntimeError("Incomplete boundary/input sample inventory")
            for binary in ("oracle-debug", "oracle-release"):
                executable = directory / "bridge" / binary
                if policy.digest_file(executable) != collected["artifacts"][binary]:
                    raise RuntimeError("Native executable changed after collection")
                for sample in prior["samples"]:
                    native = run([executable, "clamped", *sample["inputs"]],
                                 expected=(0, -signal.SIGTRAP, -signal.SIGILL), timeout=10)
                    observed = (
                        {"status": "RETURNED", "value": native.stdout.strip()} if native.returncode == 0
                        else {"status": "ARITHMETIC TRAP", "signal": signal.Signals(-native.returncode).name}
                    )
                    agrees = sample["status"] == observed["status"] and (
                        sample["status"] != "RETURNED" or sample["value"] == observed["value"]
                    )
                    report["comparisons"].append({
                        "case": name, "binary": binary, "sample": sample, "native": observed, "agrees": agrees,
                    })
                    if not agrees:
                        raise RuntimeError(f"Native/IR disagreement: {report['comparisons'][-1]}")
                if policy.digest_file(executable) != collected["artifacts"][binary]:
                    raise RuntimeError("Native executable changed during comparison")
            if kind == "seeded":
                witness = next(item for item in prior["samples"] if item["inputs"] == ["10", "3"])
                if witness["status"] != "RETURNED" or witness["value"] != "10":
                    raise RuntimeError("Seeded wrong return lacks the distinguishing counterexample")
                record["witness"] = witness
            final_inputs.append((directory, fixtures, collection, model, prior, full))
            policy.write_json(report_path, report)
        for directory, fixtures, collection, model, prior, full in final_inputs:
            if policy.generate(emitters["proof-emitter"], collection, fixtures, base.CONTRACT, commands) != model:
                raise RuntimeError(f"Model input changed: {directory.name}")
            if sil.generate(emitters["translation-emitter"], collection, fixtures, base.CONTRACT, commands) != full:
                raise RuntimeError(f"Full input changed: {directory.name}")
            for filename, expected in (("proof-emitter.json", model), ("translation-emitter.json", prior), ("bundle.json", full)):
                if json.loads((directory / filename).read_text()) != expected:
                    raise RuntimeError(f"Saved bundle changed: {directory.name}/{filename}")
        for name, record in report["cases"].items():
            directory = output / name
            collection = directory / "bridge" / "report.json"
            if policy.digest_file(collection) != record["collection_sha256"]:
                raise RuntimeError(f"Compiler collection changed: {name}")
            collected = json.loads(collection.read_text())
            for filename, digest in record["fixture_sha256"].items():
                if policy.digest_file(directory / "fixtures" / filename) != digest:
                    raise RuntimeError(f"Fixture changed: {name}/{filename}")
            for filename, digest in collected["artifacts"].items():
                if policy.digest_file(directory / "bridge" / filename) != digest:
                    raise RuntimeError(f"Compiler artifact changed: {name}/{filename}")
        environment.validate_unchanged()
        if snapshot() != report["source_sha256"]:
            raise RuntimeError("Experiment sources changed during checking")
        if any(policy.digest_file(path) != digest for path, digest in report["emitter_sha256"].items()):
            raise RuntimeError("An exporter changed during checking")
        report["status"] = "passed"
    except (policy.CheckFailure, RuntimeError, OSError, ValueError, KeyError, TypeError, StopIteration) as error:
        report.update(status="failed", failure=str(error))
    except KeyboardInterrupt:
        report.update(status="failed", failure="Experiment interrupted")
    report["elapsed_seconds"] = time.monotonic() - started
    report["finished_at"] = datetime.now(timezone.utc).isoformat()
    policy.write_json(report_path, report)
    if report["status"] != "passed":
        print(f"SwiftFormal 0.0.7 control-flow experiment: FAIL\n{report['failure']}")
        return 1
    print("SwiftFormal 0.0.7 control-flow experiment: PASS")
    print("Scope: " + ("full matrix" if report["matrix_complete"] else "selected cases plus baseline"))
    for name, record in report["cases"].items():
        print(f"{name}: {record['status']}")
    print(f"{len(report['comparisons'])} native comparisons agree. UNKNOWN and UNSUPPORTED are not proofs.")
    print(f"Report: {report_path}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
