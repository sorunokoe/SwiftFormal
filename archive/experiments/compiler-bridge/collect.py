"""Collect Swift compiler and executable evidence, not implementation proofs."""

import argparse
from datetime import datetime, timezone
import hashlib
import json
from pathlib import Path
import platform
import signal
import subprocess
import sys
import time


ROOT = Path(__file__).resolve().parent


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output", type=Path, default=ROOT / ".artifacts")
    parser.add_argument("--fixtures", type=Path, default=ROOT)
    parser.add_argument("--swiftc", help="Compiler executable; defaults to xcrun's swiftc")
    args = parser.parse_args()
    output = args.output.resolve()
    fixtures = args.fixtures.resolve()
    output.mkdir(parents=True, exist_ok=True)
    report = {
        "schema_version": 1,
        "status": "running",
        "started_at": datetime.now(timezone.utc).isoformat(),
        "host": platform.platform(),
        "commands": [],
        "observations": [],
    }
    started = time.monotonic()

    def save_report():
        temporary = output / "report.json.tmp"
        temporary.write_text(json.dumps(report, indent=2) + "\n")
        temporary.replace(output / "report.json")

    def run(command, *, required=True):
        before = time.monotonic()
        result = subprocess.run(
            [str(argument) for argument in command],
            cwd=fixtures,
            capture_output=True,
            text=True,
            timeout=60,
        )
        report["commands"].append({
            "argv": [str(argument) for argument in command],
            "cwd": str(fixtures),
            "elapsed_seconds": time.monotonic() - before,
            "returncode": result.returncode,
            "stdout": result.stdout,
            "stderr": result.stderr,
        })
        if required and result.returncode != 0:
            raise RuntimeError(
                f"Command failed ({result.returncode}): {command!r}\n"
                f"{result.stdout}{result.stderr}"
            )
        return result

    save_report()
    try:
        report["experiment_version"] = (ROOT / "VERSION").read_text().strip()
        report["collector_sha256"] = hashlib.sha256(Path(__file__).read_bytes()).hexdigest()
        report["source_sha256"] = {
            name: hashlib.sha256((fixtures / name).read_bytes()).hexdigest()
            for name in ["Fixture.swift", "main.swift"]
        }
        compiler = args.swiftc or run(["xcrun", "--find", "swiftc"]).stdout.strip()
        report["compiler"] = compiler
        report["compiler_version"] = run([compiler, "--version"]).stdout.strip()
        report["sdk_path"] = run(["xcrun", "--sdk", "macosx", "--show-sdk-path"]).stdout.strip()
        report["sdk_version"] = run(["xcrun", "--sdk", "macosx", "--show-sdk-version"]).stdout.strip()
        compiler_flags = ["-sdk", report["sdk_path"]]
        report["target_info"] = json.loads(
            run([compiler, *compiler_flags, "-print-target-info"]).stdout
        )

        modes = [
            ("silgen", ["-emit-silgen", "-Onone"]),
            ("sil-onone", ["-emit-sil", "-Onone"]),
            ("sil-optimized", ["-emit-sil", "-O"]),
        ]
        report["artifacts"] = {}
        for name, flags in modes:
            destination = output / f"{name}.sil"
            run([
                compiler, *compiler_flags, "-parse-as-library", "-module-name", "BridgeFixture",
                "-g", *flags, "Fixture.swift", "-o", destination,
            ])
            content = destination.read_bytes()
            if not content:
                raise RuntimeError(f"Empty compiler artifact: {destination}")
            report["artifacts"][destination.name] = hashlib.sha256(content).hexdigest()

        binaries = {}
        for mode, name in [("-Onone", "oracle-debug"), ("-O", "oracle-release")]:
            binary = output / name
            run([compiler, *compiler_flags, "-g", mode, "Fixture.swift", "main.swift", "-o", binary])
            binaries[mode] = binary
            report["artifacts"][name] = hashlib.sha256(binary.read_bytes()).hexdigest()

        maximum = str(2**63 - 1)
        minimum = str(-(2**63))
        cases = [
            ("clamped", "0", "1", "0"),
            ("clamped", "100", "20", "80"),
            ("clamped", maximum, "0", maximum),
            ("clamped", maximum, maximum, "0"),
            ("raw", "0", "1", "-1"),
            ("zero", "100", "20", "0"),
            ("increment", "0", "0", "1"),
            ("wrapping", maximum, "0", minimum),
            ("custom", "10", "3", "42"),
            ("effectful", "100", "20", "effect\n80"),
        ]
        for mode, binary in binaries.items():
            for operation, a, b, expected in cases:
                result = run([binary, operation, a, b])
                report["observations"].append({
                    "mode": mode,
                    "operation": operation,
                    "inputs": [a, b],
                    "kind": "returned",
                    "expected_stdout": expected,
                    "stdout": result.stdout,
                    "returncode": result.returncode,
                })
                if result.stdout.strip() != expected:
                    raise RuntimeError(
                        f"Behavior mismatch: {mode} {operation}({a}, {b}): "
                        f"expected {expected!r}, got {result.stdout.strip()!r}"
                    )

            for operation, a, b in [
                ("increment", maximum, "0"),
                ("raw", minimum, "1"),
                ("clamped", maximum, "-1"),
            ]:
                result = run([binary, operation, a, b], required=False)
                # A normal failure exit is not a trap observation.
                if result.returncode not in (-signal.SIGILL, -signal.SIGTRAP):
                    raise RuntimeError(
                        f"Expected trap signal: {mode} {operation}({a}, {b}); "
                        f"got exit {result.returncode}\n{result.stderr}"
                    )
                report["observations"].append({
                    "mode": mode,
                    "operation": operation,
                    "inputs": [a, b],
                    "kind": "expected_trap",
                    "returncode": result.returncode,
                    "signal": signal.Signals(-result.returncode).name,
                    "stdout": result.stdout,
                    "stderr": result.stderr,
                })

        for name, digest in report["source_sha256"].items():
            if hashlib.sha256((fixtures / name).read_bytes()).hexdigest() != digest:
                raise RuntimeError(f"Source changed during collection: {name}")
        report["status"] = "passed"
    except (OSError, ValueError, RuntimeError, subprocess.SubprocessError) as error:
        report["status"] = "failed"
        report["error"] = str(error)
    except KeyboardInterrupt:
        report["status"] = "failed"
        report["error"] = "Collection interrupted"
    report["elapsed_seconds"] = time.monotonic() - started
    save_report()
    if report["status"] != "passed":
        print(f"EXPERIMENT FAILED: {report['error']}", file=sys.stderr)
        return 1
    print(f"SwiftFormal {report['experiment_version']} compiler experiment: PASS")
    print(f"Captured 3 SIL artifacts and {len(report['observations'])} executions.")
    print(f"Report: {output / 'report.json'}")
    print("This is a compiler experiment, not a verifier.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
