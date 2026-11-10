"""Compare extracted SIL with compiled Swift. This is not a proof checker."""

import argparse
import copy
from datetime import datetime, timezone
import hashlib
import itertools
import json
from pathlib import Path
import random
import shutil
import signal
import subprocess
import sys
import time


ROOT = Path(__file__).resolve().parent
BRIDGE = ROOT.parent / "compiler-bridge"
SYMBOLS = {
    "clamped": "$s13BridgeFixture15clampedDiscountys5Int64VAD_ADtF",
    "raw": "$s13BridgeFixture11rawDiscountys5Int64VAD_ADtF",
    "zero": "$s13BridgeFixture10alwaysZeroys5Int64VAD_ADtF",
    "increment": "$s13BridgeFixture9incrementys5Int64VADF",
    "wrapping": "$s13BridgeFixture17wrappingIncrementys5Int64VADF",
    "effectful": "$s13BridgeFixture17effectfulDiscountys5Int64VAD_ADtF",
    "custom": "$s13BridgeFixture14customSubtractys5Int64VAA6AmountV_AFtF",
}
SUPPORTED = ("clamped", "raw", "zero", "increment")
MINIMUM = -(2**63)
MAXIMUM = 2**63 - 1


def sha256(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def write_json(path, value):
    path.parent.mkdir(parents=True, exist_ok=True)
    temporary = path.with_suffix(path.suffix + ".tmp")
    temporary.write_text(json.dumps(value, indent=2) + "\n")
    temporary.replace(path)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output", type=Path, default=ROOT / ".artifacts")
    args = parser.parse_args()
    output = args.output.resolve()
    output.mkdir(parents=True, exist_ok=True)
    started = time.monotonic()
    report = {
        "schema_version": 1,
        "started_at": datetime.now(timezone.utc).isoformat(),
        "status": "running",
        "commands": [],
        "comparisons": [],
        "controls": [],
    }
    report_path = output / "report.json"
    write_json(report_path, report)

    def run(command, expected=(0,), timeout=120):
        before = time.monotonic()
        result = subprocess.run(
            [str(part) for part in command],
            cwd=ROOT,
            capture_output=True,
            text=True,
            timeout=timeout,
        )
        report["commands"].append({
            "argv": [str(part) for part in command],
            "cwd": str(ROOT),
            "elapsed_seconds": time.monotonic() - before,
            "returncode": result.returncode,
            "stdout": result.stdout,
            "stderr": result.stderr,
        })
        if result.returncode not in expected:
            raise RuntimeError(
                f"Unexpected exit {result.returncode}: {command}\n{result.stdout}{result.stderr}"
            )
        return result

    try:
        report["experiment_version"] = (ROOT / "VERSION").read_text().strip()
        source_files = [
            ROOT / "Package.swift", ROOT / "VERSION", ROOT / "run.py", ROOT / "test_run.py",
            BRIDGE / "Fixture.swift", BRIDGE / "main.swift", BRIDGE / "collect.py",
            *sorted((ROOT / "Sources").rglob("*.swift")),
            *sorted((ROOT / "Tests").rglob("*.swift")),
        ]
        report["source_sha256"] = {str(path): sha256(path) for path in source_files}
        run([sys.executable, "-B", "-m", "unittest", "discover", "-s", ROOT, "-p", "test_*.py", "-v"])
        run(["swift", "test", "--package-path", ROOT, "--quiet"])
        run(["swift", "build", "--package-path", ROOT, "--product", "scalar-probe"])
        binary_path = run(["swift", "build", "--package-path", ROOT, "--show-bin-path"]).stdout.strip()
        binary = Path(binary_path) / "scalar-probe"
        report["probe_sha256"] = sha256(binary)
        collection_dir = output / "bridge"
        run([sys.executable, BRIDGE / "collect.py", "--output", collection_dir])
        collection_path = collection_dir / "report.json"
        collection = json.loads(collection_path.read_text())
        report["collection_report_sha256"] = sha256(collection_path)
        report["configuration"] = {
            key: collection[key]
            for key in ("compiler_version", "sdk_path", "sdk_version", "target_info")
        }

        def probe(name, requests, *, collected=collection_path, fixtures=BRIDGE, expected=0):
            request_path = output / "requests" / f"{name}.json"
            write_json(request_path, requests)
            result = run([binary, collected, fixtures, request_path], expected=(expected,))
            return json.loads(result.stdout)

        generator = random.Random(0x5F002)
        boundary = [MINIMUM, MINIMUM + 1, -1, 0, 1, MAXIMUM - 1, MAXIMUM]
        requests = []
        for operation in SUPPORTED:
            arity = 1 if operation == "increment" else 2
            cases = list(itertools.product(boundary, repeat=arity))
            cases += [
                tuple(generator.randint(MINIMUM, MAXIMUM) for _ in range(arity))
                for _ in range(32)
            ]
            cases = list(dict.fromkeys(cases))
            requests.append({
                "symbol": SYMBOLS[operation],
                "inputs": [[str(value) for value in case] for case in cases],
            })
        for operation in ("wrapping", "effectful", "custom"):
            requests.append({"symbol": SYMBOLS[operation], "inputs": []})
        response = probe("baseline", requests, expected=2)
        write_json(output / "probe.json", response)
        if response["version"] != report["experiment_version"] or response["reportSHA256"] != sha256(collection_path):
            raise RuntimeError("Probe did not bind to the collected report")
        if len(response["results"]) != len(requests):
            raise RuntimeError("Incomplete extraction result inventory")

        for operation, request, result in zip(SYMBOLS, requests, response["results"]):
            if result["symbol"] != request["symbol"]:
                raise RuntimeError("Result symbol does not match request")
            if operation not in SUPPORTED:
                if result["status"] != "UNSUPPORTED":
                    raise RuntimeError(f"Expected explicit rejection of {operation}: {result}")
                report["controls"].append({"name": f"reject-{operation}", "result": result})
                continue
            if result["status"] != "EXTRACTED" or len(result["answers"]) != len(request["inputs"]):
                raise RuntimeError(f"Incomplete interpretation for {operation}: {result}")
            for inputs, answer in zip(request["inputs"], result["answers"]):
                if inputs != answer["inputs"]:
                    raise RuntimeError("Input/result association changed")
                for mode, executable in (("-Onone", "oracle-debug"), ("-O", "oracle-release")):
                    native_args = inputs if len(inputs) == 2 else [*inputs, "0"]
                    native = run(
                        [collection_dir / executable, operation, *native_args],
                        expected=(0, -signal.SIGTRAP, -signal.SIGILL),
                        timeout=10,
                    )
                    if native.returncode == 0:
                        agrees = answer["status"] == "RETURNED" and answer["value"] == native.stdout.strip()
                        observed = {"status": "RETURNED", "value": native.stdout.strip()}
                    else:
                        agrees = answer["status"] == "ARITHMETIC TRAP"
                        observed = {
                            "status": "ARITHMETIC TRAP",
                            "signal": signal.Signals(-native.returncode).name,
                        }
                    report["comparisons"].append({
                        "operation": operation, "inputs": inputs, "mode": mode,
                        "interpreted": answer, "native": observed, "agrees": agrees,
                    })
                    if not agrees:
                        raise RuntimeError(f"Interpreter/native disagreement: {report['comparisons'][-1]}")

        baseline_request = [{"symbol": SYMBOLS["clamped"], "inputs": [["10", "3"]]}]
        baseline_value = probe("before-change", baseline_request)["results"][0]["answers"][0]["value"]
        for executable in ("oracle-debug", "oracle-release"):
            native = run([collection_dir / executable, "clamped", "10", "3"])
            if native.stdout.strip() != baseline_value:
                raise RuntimeError("Original interpretation did not match original native code")
        changed_fixtures = output / "changed-fixtures"
        changed_fixtures.mkdir(exist_ok=True)
        original = (BRIDGE / "Fixture.swift").read_text()
        changed = original.replace(
            "    return subtotal - discount",
            "    if subtotal < 50 {\n        return subtotal\n    }\n    return subtotal - discount",
            1,
        )
        if changed == original:
            raise RuntimeError("Changed-source control did not change the intended body")
        (changed_fixtures / "Fixture.swift").write_text(changed)
        shutil.copyfile(BRIDGE / "main.swift", changed_fixtures / "main.swift")
        changed_dir = output / "changed-bridge"
        run([
            sys.executable, BRIDGE / "collect.py", "--fixtures", changed_fixtures,
            "--output", changed_dir,
        ])
        changed_response = probe(
            "after-change", baseline_request,
            collected=changed_dir / "report.json", fixtures=changed_fixtures,
        )
        changed_value = changed_response["results"][0]["answers"][0]["value"]
        if baseline_value != "7" or changed_value != "10":
            raise RuntimeError("Changed-body control did not affect interpretation")
        for executable in ("oracle-debug", "oracle-release"):
            native = run([changed_dir / executable, "clamped", "10", "3"])
            if native.stdout.strip() != changed_value:
                raise RuntimeError("Changed interpretation did not match changed native code")
        report["controls"].append({
            "name": "changed-body-passes-old-samples",
            "baseline": baseline_value, "changed": changed_value,
            "response": changed_response,
            "collection_report_sha256": sha256(changed_dir / "report.json"),
        })

        def rejected(name, *, collected=collection_path, fixtures=BRIDGE, detail):
            result = probe(name, baseline_request, collected=collected, fixtures=fixtures, expected=1)
            if result.get("status") != "INVALID ARTIFACT" or detail not in result.get("detail", ""):
                raise RuntimeError(f"Wrong rejection for {name}: {result}")
            report["controls"].append({"name": name, "result": result})

        rejected("stale-source", fixtures=changed_fixtures, detail="Source digest mismatch")
        rejected("missing-report", collected=collection_dir / "missing.json", detail="Cannot read collection")
        mutations = [
            ("failed-report", lambda value: value.update(status="failed"), "not a passed"),
            ("running-report", lambda value: value.update(status="running"), "not a passed"),
            ("missing-status", lambda value: value.pop("status"), "Cannot read collection"),
            ("null-sources", lambda value: value.update(source_sha256=None), "Cannot read collection"),
            ("unknown-compiler", lambda value: value.update(compiler_version="unknown"), "Unrecognized compiler"),
            ("unknown-sdk", lambda value: value.update(sdk_version="999"), "Unrecognized compiler"),
            ("stale-source-digest", lambda value: value["source_sha256"].update({"Fixture.swift": "0" * 64}), "Source digest mismatch"),
        ]
        for name, mutate, detail in mutations:
            invalid = copy.deepcopy(collection)
            mutate(invalid)
            invalid_path = collection_dir / f"{name}.json"
            write_json(invalid_path, invalid)
            rejected(name, collected=invalid_path, detail=detail)
        invalid = copy.deepcopy(collection)
        for command in invalid["commands"]:
            if "-emit-sil" in command["argv"] and "-Onone" in command["argv"]:
                command["argv"].insert(1, "-Ounchecked")
        invalid_path = collection_dir / "changed-flags.json"
        write_json(invalid_path, invalid)
        rejected("changed-flags", collected=invalid_path, detail="Unexpected compiler command")

        sil_path = collection_dir / "sil-onone.sil"
        original_sil = sil_path.read_bytes()
        try:
            sil_path.write_bytes(original_sil + b"\n")
            rejected("changed-artifact", detail="Artifact digest mismatch")
        finally:
            sil_path.write_bytes(original_sil)

        for path, expected in report["source_sha256"].items():
            if sha256(Path(path)) != expected:
                raise RuntimeError(f"Experiment source changed during run: {path}")
        if sha256(binary) != report["probe_sha256"] or sha256(collection_path) != report["collection_report_sha256"]:
            raise RuntimeError("Probe or baseline report changed during run")
        for name, expected in collection["artifacts"].items():
            if sha256(collection_dir / name) != expected:
                raise RuntimeError(f"Baseline artifact changed: {name}")
        report["summary"] = {
            "selected": len(SYMBOLS),
            "extracted": len(SUPPORTED),
            "unsupported": len(SYMBOLS) - len(SUPPORTED),
            "interpreted_inputs": sum(len(request["inputs"]) for request in requests),
            "native_comparisons": len(report["comparisons"]),
            "native_traps": sum(item["native"]["status"] == "ARITHMETIC TRAP" for item in report["comparisons"]),
            "negative_controls": len(report["controls"]),
            "seed": "0x5F002",
        }
        report["status"] = "passed"
    except (OSError, ValueError, KeyError, IndexError, RuntimeError, subprocess.SubprocessError) as error:
        report["status"] = "failed"
        report["error"] = str(error)
    except KeyboardInterrupt:
        report["status"] = "failed"
        report["error"] = "Experiment interrupted"
    report["elapsed_seconds"] = time.monotonic() - started
    write_json(report_path, report)
    if report["status"] != "passed":
        print(f"EXPERIMENT FAILED: {report['error']}", file=sys.stderr)
        return 1
    counts = report["summary"]
    print(f"SwiftFormal {report['experiment_version']} extraction experiment: PASS")
    print(f"Extracted {counts['extracted']}/{counts['selected']} functions; explicitly rejected {counts['unsupported']}.")
    print(f"{counts['native_comparisons']} native comparisons agree ({counts['native_traps']} traps).")
    print(f"{counts['negative_controls']} negative controls behaved as expected.")
    print(f"Report: {report_path}")
    print("This is sampled agreement, not a formal proof.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
