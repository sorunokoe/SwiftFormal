"""Check a current, regenerated 0.0.4 bundle using the shared fail-closed policy."""

import argparse
import importlib.util
from pathlib import Path
import sys


ROOT = Path(__file__).resolve().parent
REFERENCE = ROOT / "Sources" / "TranslationValidation" / "Resources" / "ReferenceIR.lean"
spec = importlib.util.spec_from_file_location("swiftformal_proof_policy", ROOT.parent / "lean-proof" / "check.py")
policy = importlib.util.module_from_spec(spec)
sys.modules[spec.name] = policy
spec.loader.exec_module(policy)

TRANSLATION_NAMES = ["SwiftFormalV004.correspondence", "SwiftFormalV004.sampledAgreement"]
REQUIRED_NAMES = set(TRANSLATION_NAMES) | {
    "SwiftFormalV003.preconditionWitness", "SwiftFormalV003.totalCorrectness", "SwiftFormalV003.noTrap",
    "SwiftFormalV004.totalCorrectness", "SwiftFormalV004.noTrap",
}


def generate(emitter, collection, fixtures, contract, commands):
    bundle = policy.read_bundle(emitter, collection, fixtures, contract, commands)
    try:
        if bundle["referenceSHA256"] != policy.digest_file(REFERENCE):
            raise policy.CheckFailure("INVALID EVIDENCE", "Packaged reference interpreter differs from current source")
        if (
            bundle["schemaVersion"] != 1 or bundle["version"] != "0.0.4"
            or bundle["reportSHA256"] != policy.digest_file(collection)
            or bundle["contractSHA256"] != policy.digest_file(contract)
            or bundle["translation"]["expectedTheorems"] != TRANSLATION_NAMES
            or not REQUIRED_NAMES <= set(bundle["proof"]["expectedTheorems"])
        ):
            raise policy.CheckFailure("INVALID EVIDENCE", "Invalid translation inventory or binding")
        reference = REFERENCE.read_text()
        for key in ("translation", "proof"):
            proof = bundle[key]
            names = proof["expectedTheorems"]
            if (
                len(set(names)) != len(names)
                or [entry["name"] for entry in proof["obligations"]] != names
                or proof["source"].count(reference) != 1
                or proof["source"].count(bundle["program"]) != 1
                or [line for line in proof["source"].splitlines() if line.startswith("import ")] != ["import Lean"]
            ):
                raise policy.CheckFailure("INVALID EVIDENCE", "Incomplete proof or independent IR interpreter")
        if not bundle["translation"]["source"].startswith(bundle["modelSource"]):
            raise policy.CheckFailure("INVALID EVIDENCE", "Candidate model differs from the correspondence source")
        return bundle
    except (ValueError, KeyError, TypeError, AttributeError) as error:
        raise policy.CheckFailure("INVALID EVIDENCE", f"Malformed translation bundle: {error}") from error


def check(emitter, collection, fixtures, contract, bundle, environment, commands, *, translation_only=False):
    result = policy.verify(
        emitter, collection, fixtures, contract, bundle, environment, commands,
        generator=generate, proof_key="translation" if translation_only else "proof",
        identity_paths=(Path(__file__), REFERENCE),
    )
    if result["status"] == "MODEL PROVED":
        result["status"] = "TRANSLATION VALIDATED" if translation_only else "IR CONTRACT PROVED"
    return result


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    for name in ("emitter", "collection", "fixtures", "contract", "bundle", "output"):
        parser.add_argument(f"--{name}", type=Path, required=True)
    parser.add_argument("--lean", default="lean")
    parser.add_argument("--translation-only", action="store_true")
    args = parser.parse_args()
    result = {"status": "RUNNING", "commands": []}
    policy.write_json(args.output, result)
    try:
        environment = policy.LeanEnvironment(args.lean, result["commands"])
        policy.write_json(args.output.with_suffix(".environment.json"), environment.data)
        result.update(check(
            args.emitter.resolve(), args.collection.resolve(), args.fixtures.resolve(), args.contract.resolve(),
            args.bundle.resolve(), environment, result["commands"], translation_only=args.translation_only,
        ))
    except policy.CheckFailure as error:
        result.update(status=error.status, reason=str(error))
    except (OSError, ValueError, KeyError, TypeError) as error:
        result.update(status="TOOL ERROR", reason=str(error))
    except KeyboardInterrupt:
        result.update(status="TOOL ERROR", reason="Checking interrupted")
    policy.write_json(args.output, result)
    print(result["status"])
    if "reason" in result:
        print(result["reason"])
    return 0 if result["status"] in ("TRANSLATION VALIDATED", "IR CONTRACT PROVED") else 1


if __name__ == "__main__":
    raise SystemExit(main())
