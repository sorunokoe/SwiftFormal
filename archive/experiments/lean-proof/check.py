"""Fail-closed checking of mechanically generated Lean proof bundles."""

import argparse
import hashlib
import json
import os
from pathlib import Path
import re
import subprocess
import tempfile
import time


ALLOWED_AXIOMS = frozenset({"propext", "Classical.choice", "Quot.sound"})
LEAN_COMMIT = "eb6cafb7290e8bd5f2937522d8d804f58f02bafc"
LEAN_FLAGS = ["--json", "--stdin", "-t", "0"]
IMPORT_PROBE = """import Lean
run_cmd do
  let environment <- Lean.getEnv
  let names := environment.header.moduleNames.map toString
  Lean.logInfo (Lean.Json.compress (Lean.toJson names))
"""


class CheckFailure(Exception):
    def __init__(self, status, reason):
        self.status = status
        super().__init__(reason)


def digest_bytes(data):
    return hashlib.sha256(data).hexdigest()


def digest_file(path):
    with Path(path).open("rb") as stream:
        return hashlib.file_digest(stream, "sha256").hexdigest()


def write_json(path, value):
    path = Path(path)
    path.parent.mkdir(parents=True, exist_ok=True)
    temporary = path.with_suffix(path.suffix + ".tmp")
    temporary.write_text(json.dumps(value, indent=2) + "\n")
    temporary.replace(path)


def execute(argv, commands, *, source=None, cwd=None, environment=None, timeout=60):
    argv = [str(value) for value in argv]
    record = {"argv": argv, "cwd": str(cwd or Path.cwd())}
    if source is not None:
        record["stdin_sha256"] = digest_bytes(source.encode())
    commands.append(record)
    before = time.monotonic()
    try:
        result = subprocess.run(
            argv, input=source, capture_output=True, text=True, cwd=cwd,
            env=environment, timeout=timeout,
        )
        record.update(returncode=result.returncode, stdout=result.stdout, stderr=result.stderr)
        return result
    except (OSError, subprocess.SubprocessError) as error:
        record["error"] = str(error)
        raise CheckFailure("TOOL ERROR", str(error)) from error
    finally:
        record["elapsed_seconds"] = time.monotonic() - before


def require_success(result):
    if result.returncode != 0 or result.stderr.strip():
        raise CheckFailure("TOOL ERROR", f"Command failed: {result.stdout}{result.stderr}")


def audit(returncode, stdout, stderr, expected):
    rejected = lambda reason: {"status": "UNPROVED", "reason": reason}
    if not expected or len(set(expected)) != len(expected):
        return rejected("Missing or duplicate theorem inventory")
    if returncode != 0:
        return rejected(f"Lean rejected the proof (exit {returncode})")
    if stderr.strip():
        return rejected(f"Unexpected checker stderr: {stderr}")
    axioms = {}
    try:
        for line in stdout.splitlines():
            if not line.strip():
                continue
            message = json.loads(line)
            if message.get("severity") != "information":
                return rejected(f"Lean diagnostic: {message.get('data', message)}")
            detail = message["data"]
            empty = re.fullmatch(r"'([^']+)' does not depend on any axioms", detail)
            dependencies = re.fullmatch(r"'([^']+)' depends on axioms: \[([^\]]*)\]", detail, re.DOTALL)
            if empty:
                name, used = empty[1], []
            elif dependencies:
                name = dependencies[1]
                used = [item.strip() for item in dependencies[2].split(",") if item.strip()]
            else:
                return rejected(f"Unrecognized checker information: {detail}")
            if name not in expected or name in axioms:
                return rejected(f"Unexpected or duplicate theorem audit: {name}")
            forbidden = set(used) - ALLOWED_AXIOMS
            if forbidden:
                return rejected(f"Forbidden axioms for {name}: {sorted(forbidden)}")
            axioms[name] = used
    except (ValueError, KeyError, TypeError, AttributeError) as error:
        return rejected(f"Malformed checker output: {error}")
    if set(axioms) != set(expected):
        return rejected(f"Missing theorem audits: {sorted(set(expected) - set(axioms))}")
    return {"status": "MODEL PROVED", "axioms": axioms}


class LeanEnvironment:
    def __init__(self, command, commands):
        self.commands = commands
        self.environment = {key: value for key, value in os.environ.items() if not key.startswith("LEAN_")}
        with tempfile.TemporaryDirectory() as directory:
            prefix = execute([command, "--print-prefix"], commands, cwd=directory, environment=self.environment)
            require_success(prefix)
            self.prefix = Path(prefix.stdout.strip()).resolve()
            self.executable = self.prefix / "bin" / "lean"
            version = execute([self.executable, "--version"], commands, cwd=directory, environment=self.environment)
            commit = execute([self.executable, "--githash"], commands, cwd=directory, environment=self.environment)
            require_success(version)
            require_success(commit)
            if not version.stdout.startswith("Lean (version 4.35.0,") or commit.stdout.strip() != LEAN_COMMIT:
                raise CheckFailure("TOOL ERROR", "Unsupported Lean version or revision")
            modules_result = execute(
                [self.executable, *LEAN_FLAGS], commands, source=IMPORT_PROBE,
                cwd=directory, environment=self.environment,
            )
            require_success(modules_result)
        messages = [json.loads(line) for line in modules_result.stdout.splitlines() if line.strip()]
        if len(messages) != 1 or messages[0].get("severity") != "information":
            raise CheckFailure("TOOL ERROR", "Cannot establish Lean import closure")
        modules = json.loads(messages[0]["data"])
        if not modules or "Lean" not in modules:
            raise CheckFailure("TOOL ERROR", "Incomplete Lean import closure")
        library = self.prefix / "lib" / "lean"
        files = {self.executable}
        for name in modules:
            if not isinstance(name, str) or not re.fullmatch(r"[A-Za-z0-9_]+(?:\.[A-Za-z0-9_]+)*", name):
                raise CheckFailure("TOOL ERROR", "Unrecognized Lean module name")
            module_path = library / name.replace(".", "/")
            public = Path(str(module_path) + ".olean")
            if not public.is_file():
                raise CheckFailure("TOOL ERROR", f"Missing imported module: {public}")
            files.add(public)
            for suffix in (".olean.private", ".ir"):
                path = Path(str(module_path) + suffix)
                if path.is_file():
                    files.add(path)
        runtime = list(library.glob("libleanshared*.dylib")) + [library / "libInit_shared.dylib"]
        if not runtime or not all(path.is_file() for path in runtime):
            raise CheckFailure("TOOL ERROR", "Missing pinned macOS Lean runtime")
        files.update(runtime)
        self.data = {
            "version": version.stdout.strip(),
            "commit": commit.stdout.strip(),
            "executable": str(self.executable),
            "flags": LEAN_FLAGS,
            "allowed_axioms": sorted(ALLOWED_AXIOMS),
            "module_count": len(modules),
            "files": {str(path): digest_file(path) for path in sorted(files)},
        }
        self.digest = digest_bytes(json.dumps(self.data, sort_keys=True).encode())

    def validate_unchanged(self):
        for name, expected in self.data["files"].items():
            if digest_file(name) != expected:
                raise CheckFailure("INVALID EVIDENCE", f"Lean environment changed: {name}")

    def check_source(self, source, expected, *, timeout=60):
        # This low-level method is for generated sources and fixed policy-test fixtures,
        # not a public interface for executing user-supplied Lean programs.
        with tempfile.TemporaryDirectory() as directory:
            process = execute(
                [self.executable, *LEAN_FLAGS], self.commands, source=source,
                cwd=directory, environment=self.environment, timeout=timeout,
            )
        result = audit(process.returncode, process.stdout, process.stderr, expected)
        result["checker_returncode"] = process.returncode
        result["proof_source_sha256"] = digest_bytes(source.encode())
        result["environment_sha256"] = self.digest
        try:
            messages = [json.loads(line) for line in process.stdout.splitlines() if line.strip()]
            result["diagnostics"] = [message for message in messages if message.get("severity") in ("warning", "error")]
        except (ValueError, AttributeError):
            result["diagnostics"] = []
        return result


def read_bundle(emitter, collection, fixtures, contract, commands):
    process = execute([emitter, collection, fixtures, contract], commands)
    if process.returncode != 0:
        try:
            failure = json.loads(process.stdout)
        except ValueError:
            raise CheckFailure("TOOL ERROR", process.stderr or process.stdout)
        if not isinstance(failure, dict):
            raise CheckFailure("TOOL ERROR", "Malformed emitter failure")
        status = failure.get("status")
        if status not in ("UNSUPPORTED", "INVALID ARTIFACT", "INVALID CONTRACT", "TOOL ERROR"):
            status = "TOOL ERROR"
        raise CheckFailure(status, failure.get("detail", "Emitter failed"))
    if process.stderr.strip():
        raise CheckFailure("TOOL ERROR", process.stderr)
    try:
        bundle = json.loads(process.stdout)
        if not isinstance(bundle, dict):
            raise ValueError("Expected an object")
        return bundle
    except ValueError as error:
        raise CheckFailure("INVALID EVIDENCE", f"Malformed generated bundle: {error}") from error


def generate(emitter, collection, fixtures, contract, commands):
    bundle = read_bundle(emitter, collection, fixtures, contract, commands)
    try:
        proof = bundle["proof"]
        names = proof["expectedTheorems"]
        obligations = proof["obligations"]
        mandatory = {
            "SwiftFormalV003.preconditionWitness", "SwiftFormalV003.totalCorrectness", "SwiftFormalV003.noTrap",
        }
        if (
            bundle["schemaVersion"] != 1 or bundle["version"] != "0.0.3"
            or not mandatory <= set(names) or len(set(names)) != len(names)
            or [entry["name"] for entry in obligations] != names
            or not any(entry["kind"] == "return" for entry in obligations)
            or [line for line in proof["source"].splitlines() if line.startswith("import ")] != ["import Lean"]
            or bundle["reportSHA256"] != digest_file(collection)
            or bundle["contractSHA256"] != digest_file(contract)
        ):
            raise CheckFailure("INVALID EVIDENCE", "Invalid generated proof inventory or binding")
        return bundle
    except (ValueError, KeyError, TypeError) as error:
        raise CheckFailure("INVALID EVIDENCE", f"Malformed generated bundle: {error}") from error


def verify(
    emitter, collection, fixtures, contract, bundle_path, environment, commands,
    *, generator=None, proof_key="proof", identity_paths=(), proof_timeout=None,
):
    generator = generator or generate
    try:
        proof_bytes = Path(bundle_path).read_bytes()
    except FileNotFoundError as error:
        raise CheckFailure("MISSING PROOF", str(error)) from error
    try:
        supplied = json.loads(proof_bytes)
    except ValueError as error:
        raise CheckFailure("INVALID EVIDENCE", f"Malformed proof bundle: {error}") from error
    emitter_digest = digest_file(emitter)
    checker_digest = digest_file(__file__)
    additional_digests = {str(path): digest_file(path) for path in identity_paths}
    expected = generator(emitter, collection, fixtures, contract, commands)
    if supplied != expected:
        raise CheckFailure("INVALID EVIDENCE", "Proof bundle differs from current generated source, contract, or collection")
    proof = expected[proof_key]
    options = {} if proof_timeout is None else {"timeout": proof_timeout}
    result = environment.check_source(proof["source"], proof["expectedTheorems"], **options)
    declaration_lines = [
        (proof["source"][:proof["source"].index(entry["statement"])].count("\n") + 1, entry["name"])
        for entry in proof["obligations"]
    ]
    result["failed_obligations"] = sorted({
        max(candidates)[1]
        for diagnostic in result["diagnostics"]
        if diagnostic["severity"] == "error"
        if (candidates := [entry for entry in declaration_lines if entry[0] <= diagnostic.get("pos", {}).get("line", 0)])
    })
    if generator(emitter, collection, fixtures, contract, commands) != expected:
        raise CheckFailure("INVALID EVIDENCE", "Inputs changed while Lean was checking")
    if (
        digest_file(emitter) != emitter_digest or digest_file(__file__) != checker_digest
        or Path(bundle_path).read_bytes() != proof_bytes
        or any(digest_file(path) != digest for path, digest in additional_digests.items())
    ):
        raise CheckFailure("INVALID EVIDENCE", "Proof checker, emitter, or supplied proof changed")
    environment.validate_unchanged()
    result["binding"] = {
        "collection_sha256": expected["reportSHA256"],
        "sil_sha256": expected["silSHA256"],
        "contract_sha256": expected["contractSHA256"],
        "bundle_sha256": digest_bytes(proof_bytes),
        "emitter_sha256": emitter_digest,
        "checker_sha256": checker_digest,
        "additional_sources_sha256": additional_digests,
        "proof_kind": proof_key,
    }
    result["expected_theorems"] = proof["expectedTheorems"]
    if proof_timeout is not None:
        result["proof_timeout_seconds"] = proof_timeout
    return result


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    for name in ("emitter", "collection", "fixtures", "contract", "bundle", "output"):
        parser.add_argument(f"--{name}", type=Path, required=True)
    parser.add_argument("--lean", default="lean")
    args = parser.parse_args()
    result = {"status": "RUNNING", "commands": []}
    write_json(args.output, result)
    try:
        environment = LeanEnvironment(args.lean, result["commands"])
        write_json(args.output.with_suffix(".environment.json"), environment.data)
        result.update(verify(
            args.emitter.resolve(), args.collection.resolve(), args.fixtures.resolve(),
            args.contract.resolve(), args.bundle.resolve(), environment, result["commands"],
        ))
    except CheckFailure as error:
        result.update(status=error.status, reason=str(error))
    except (OSError, ValueError, KeyError, TypeError) as error:
        result.update(status="TOOL ERROR", reason=str(error))
    except KeyboardInterrupt:
        result.update(status="TOOL ERROR", reason="Checking interrupted")
    write_json(args.output, result)
    print(result["status"])
    if "reason" in result:
        print(result["reason"])
    return 0 if result["status"] == "MODEL PROVED" else 1


if __name__ == "__main__":
    raise SystemExit(main())
