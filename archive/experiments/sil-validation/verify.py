"""Bind raw compiler SIL to an independently decoded and proved instruction program."""

import argparse
import copy
import importlib.util
from pathlib import Path
import sys


ROOT = Path(__file__).resolve().parent
READER = ROOT / "Sources" / "SILReader.lean"
PROPOSALS = ROOT / "Sources" / "Proposals.lean"
UPSTREAM = ROOT.parent / "translation-validation" / "verify.py"
spec = importlib.util.spec_from_file_location("swiftformal_translation_policy", UPSTREAM)
upstream = importlib.util.module_from_spec(spec)
sys.modules[spec.name] = upstream
spec.loader.exec_module(upstream)
policy = upstream.policy
SYMBOL = "$s13BridgeFixture15clampedDiscountys5Int64VAD_ADtF"
STATUSES = {
    "handoff": "SIL HANDOFF VALIDATED",
    "translation": "SIL TRANSLATION VALIDATED",
    "proof": "SIL CONTRACT PROVED",
}


def quote_lean(text):
    marks = "#"
    while '"' + marks in text:
        marks += "#"
    return "r" + marks + '"' + text + '"' + marks


def obligation(name, kind, statement):
    return {"name": f"SwiftFormalV005.{name}", "kind": kind, "statement": statement}


def chunks(raw):
    result = [raw[index:index + 512] for index in range(0, len(raw), 512)]
    if b"".join(result) != raw:
        raise policy.CheckFailure("INVALID EVIDENCE", "Byte serialization changed the raw input")
    return result


def input_declarations(raw):
    groups = chunks(raw)
    declarations = ["namespace SwiftFormalV005", f"def selectedSymbol : String := {quote_lean(SYMBOL)}"]
    for index, group in enumerate(groups):
        declarations.append(f"""def chunk{index} : List UInt8 := [{', '.join(str(byte) for byte in group)}]
def state{index} : SILInput.State := proposed_state%
  (SILInput.step selectedSymbol {'{}' if index == 0 else f'state{index - 1}'} chunk{index})
set_option maxRecDepth 8192 in
set_option maxHeartbeats 4000000 in
theorem step{index} : SILInput.step selectedSymbol {'{}' if index == 0 else f'state{index - 1}'} chunk{index} =
    Except.ok state{index} := by decide +kernel
""")
    for index in reversed(range(len(groups))):
        tail = f"tail{index + 1}" if index + 1 < len(groups) else "[]"
        next_proof = f"checkedTail{index + 1}" if index + 1 < len(groups) else "(by rfl)"
        declarations.append(f"""def tail{index} : List (List UInt8) := chunk{index} :: {tail}
theorem checkedTail{index} :
    tail{index}.foldlM (SILInput.step selectedSymbol) {'{}' if index == 0 else f'state{index - 1}'} =
      Except.ok state{len(groups) - 1} := by
  exact SILInput.checked_cons selectedSymbol {'{}' if index == 0 else f'state{index - 1}'}
    state{index} state{len(groups) - 1} chunk{index} {tail} step{index} {next_proof}
""")
    declarations.append(f"def chunks : List (List UInt8) := {'tail0' if groups else '[]'}")
    return "\n\n".join(declarations), len(groups)


def compose(prior, raw, reader):
    if policy.digest_bytes(raw) != prior["silSHA256"]:
        raise policy.CheckFailure("INVALID EVIDENCE", "Raw SIL bytes differ from the exported collection")
    if len(raw) > 262144:
        raise policy.CheckFailure("UNSUPPORTED", "SIL exceeds the 256 KiB experiment limit")
    prefix, count = input_declarations(raw)
    decoded = obligation("decodedProgram", "decode", """theorem decodedProgram :
    SILInput.readChunks chunks selectedSymbol = Except.ok SwiftFormalV004.program""")
    decoded_source = f"""set_option maxRecDepth 8192 in
set_option maxHeartbeats 4000000 in
{decoded['statement']} := by
  simp only [SILInput.readChunks, chunks, {'checkedTail0, SILInput.bind_ok' if count else 'List.foldlM_nil, pure_bind'}]
  decide +kernel
"""
    correspondence = obligation("correspondence", "correspondence", f"""theorem correspondence (subtotal discount : Int)
    (_subtotal : SwiftFormalV003.Fits subtotal) (_discount : SwiftFormalV003.Fits discount) :
    SILInput.executeChunks {prior['fuel']} chunks selectedSymbol subtotal discount =
      SwiftFormalV004.lift (SwiftFormalV003.implementation subtotal discount)""")
    correspondence_source = f"""{correspondence['statement']} := by
  unfold SILInput.executeChunks
  rw [decodedProgram]
  exact SwiftFormalV004.correspondence subtotal discount _subtotal _discount
"""
    total = obligation("totalCorrectness", "transfer", f"""theorem totalCorrectness (subtotal discount : Int)
    (_inputs : SwiftFormalV003.Inputs subtotal discount) :
    SILInput.executeChunks {prior['fuel']} chunks selectedSymbol subtotal discount =
      ReferenceIR.Outcome.returned (SwiftFormalV003.expectedResult subtotal discount)""")
    total_source = f"""{total['statement']} := by
  unfold SILInput.executeChunks
  rw [decodedProgram]
  exact SwiftFormalV004.totalCorrectness subtotal discount _inputs
"""
    no_trap = obligation("noTrap", "no-trap", f"""theorem noTrap (subtotal discount : Int)
    (_inputs : SwiftFormalV003.Inputs subtotal discount) :
    Not (SILInput.executeChunks {prior['fuel']} chunks selectedSymbol subtotal discount =
      ReferenceIR.Outcome.arithmeticTrap)""")
    no_trap_source = f"""{no_trap['statement']} := by
  rw [totalCorrectness subtotal discount _inputs]
  intro impossible
  cases impossible
"""
    bare_program = (
        "import Lean\n" + upstream.REFERENCE.read_text()
        + "\nnamespace SwiftFormalV004\n" + prior["program"] + "\nend SwiftFormalV004\n"
    )
    result = copy.deepcopy(prior)
    proposals = PROPOSALS.read_text()
    result.update(
        version="0.0.5", upstreamVersion=prior["version"],
        readerSHA256=policy.digest_bytes(reader.encode()),
        proposalsSHA256=policy.digest_bytes(proposals.encode()), chunks=count,
    )
    for key, base, extra, declarations in (
        ("handoff", bare_program, [decoded], [decoded_source]),
        ("translation", prior["translation"]["source"], [decoded, correspondence],
         [decoded_source, correspondence_source]),
        ("proof", prior["proof"]["source"], [decoded, correspondence, total, no_trap],
         [decoded_source, correspondence_source, total_source, no_trap_source]),
    ):
        existing = [] if key == "handoff" else prior[key]["obligations"]
        audits = "\n".join(f"#print axioms {item['name']}" for item in extra)
        source = "\n\n".join([base, reader, proposals, prefix, *declarations, audits, "end SwiftFormalV005\n"])
        result[key] = {
            "source": source, "obligations": existing + extra,
            "expectedTheorems": [item["name"] for item in existing + extra],
        }
    return result


def generate(emitter, collection, fixtures, contract, commands):
    prior = upstream.generate(emitter, collection, fixtures, contract, commands)
    raw = (Path(collection).parent / "sil-onone.sil").read_bytes()
    return compose(prior, raw, READER.read_text())


def check(emitter, collection, fixtures, contract, bundle, environment, commands, *, mode="proof"):
    if mode not in STATUSES:
        raise policy.CheckFailure("INVALID EVIDENCE", "Unknown proof mode")
    result = policy.verify(
        emitter, collection, fixtures, contract, bundle, environment, commands,
        generator=generate, proof_key=mode,
        identity_paths=(Path(__file__), READER, PROPOSALS, UPSTREAM, upstream.REFERENCE),
        proof_timeout=180,
    )
    if result["status"] == "MODEL PROVED":
        result["status"] = STATUSES[mode]
    return result


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    for name in ("emitter", "collection", "fixtures", "contract", "bundle", "output"):
        parser.add_argument(f"--{name}", type=Path, required=True)
    parser.add_argument("--lean", default="lean")
    parser.add_argument("--mode", choices=STATUSES, default="proof")
    args = parser.parse_args()
    result = {"status": "RUNNING", "commands": []}
    policy.write_json(args.output, result)
    try:
        environment = policy.LeanEnvironment(args.lean, result["commands"])
        policy.write_json(args.output.with_suffix(".environment.json"), environment.data)
        result.update(check(
            args.emitter.resolve(), args.collection.resolve(), args.fixtures.resolve(),
            args.contract.resolve(), args.bundle.resolve(), environment, result["commands"], mode=args.mode,
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
    return 0 if result["status"] == STATUSES[args.mode] else 1


if __name__ == "__main__":
    raise SystemExit(main())
