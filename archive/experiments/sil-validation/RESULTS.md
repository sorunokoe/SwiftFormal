# SwiftFormal 0.0.5: independently decoding compiler SIL

## Question and result

Do the instructions proved in 0.0.4 actually match the compiler artifact,
without relying on the Swift extractor to identify or decode the function?

**Yes, for the current `clampedDiscount` artifact and supported profile.**
A separate Lean reader consumes all 80,419 bytes of canonical SIL and selects
the function itself. A kernel-checked equality connects its result to the
instruction program exported by the existing Swift implementation.

The full proof transfers the earlier all-signed-input correspondence and the
nonnegative-input business contract onto execution of this independently
decoded program. It is not a proof of the Swift compiler or of SIL semantics.

```bash
python3 -B experiments/sil-validation/run.py
```

Observed result with the pinned tools described in the root README:

```text
SwiftFormal 0.0.5 SIL experiment: PASS
SIL CONTRACT PROVED: independent decoding of the complete compiler artifact.
14 root theorem audits; 158 checked byte chunks; 42 controls.
```

## What is actually checked

The production path reuses the real 0.0.4 `translation-emitter`, unchanged.
Python independently reads the complete `sil-onone.sil`, checks its digest
against the exporter bundle, and encodes its bytes as fixed 512-byte chunks.
There is no Python selection of a function, line, instruction, or source span.
Chunk boundaries can split lines, tokens, quoted text, or UTF-8 sequences.

`Sources/SILReader.lean` implements the reader and carries unfinished lines
across chunks. It independently handles module selection, quoted text,
comments, braces, basic blocks, and the supported instructions.

For each chunk, `Sources/Proposals.lean` uses native evaluation to propose an
ordinary reader-state value. This is only an accelerator:

1. A separate `stepN` theorem checks the proposed transition by kernel reduction.
2. Small `checkedTailN` lemmas compose those transitions.
3. `decodedProgram` proves that reading the complete byte stream returns
   exactly the exported instruction data.

The state proposer is an explicitly unsafe elaboration helper, not a proof
primitive. Its output is quoted data, not a native-evaluation theorem. A
deliberately wrong proposed byte count fails its transition proof. No
`native_decide` axiom, new allowed axiom, or `sorry` acceptance was introduced.

This is equality of normalized instruction data, not equality of every textual
SIL detail. It preserves SSA identifiers, executable operands, instruction
order, block arguments and destinations, arithmetic flags, projections, and
trap instructions. Recognized source/debug metadata is parsed but discarded;
parameter debug instructions remain explicit no-ops.

### Three distinct verdicts

| Mode | Verdict | Meaning | Root audits on the original body |
|---|---|---|---|
| `handoff` | `SIL HANDOFF VALIDATED` | Independent raw-byte decoding equals the exported IR | 1 |
| `translation` | `SIL TRANSLATION VALIDATED` | Additionally, decoded execution equals the model for all signed `Int64` pairs, including traps | 4 |
| `proof` (default) | `SIL CONTRACT PROVED` | Additionally, all nonnegative `Int64` pairs return exact clamped subtraction without a modeled trap | 14 |

The 14 roots include the ten earlier audits plus decoding, decoded
correspondence, total correctness, and no-trap transfer. Root axiom audits
include transitive dependencies on the chunk certificates. The checker also
rejects any error or warning, including in an auxiliary declaration.
The earlier precondition witness remains part of the full inventory.

## Accepted profile and limits

The selected symbol is fixed by the existing contract:
`$s13BridgeFixture15clampedDiscountys5Int64VAD_ADtF`.
The first line must declare canonical SIL. The selected header must have the
exact supported thin, two-`Int64`-argument, `Int64`-result signature.

Supported instructions are `integer_literal` for signed 64-bit words and the
supported bit literals, `struct_extract`, `struct`, signed comparison,
checked addition/subtraction, tuple projections, `cond_fail`, `br`, `cond_br`,
`return`, and the narrow parameter `debug_value` form emitted for this fixture.
Supported block parameter types are `Int64`, `Builtin.Int64`, and `Builtin.Int1`.
Location and scope suffixes must match the recognized grammar.

Definition headers and selected-function lines must be ASCII. Other module
contents may contain UTF-8: unselected bodies and scope/declaration records
undergo byte-based, quote/comment-aware brace scanning, not full SIL type or
instruction validation. Symbol mentions in comments, scope
records, and other functions' references are not selected definitions.
Duplicate or nested selected definitions and unbalanced envelopes are rejected.

The reader checks basic block structure, but is not a replacement for the
existing general SSA/type validator. Unsupported selected syntax fails closed.
This remains a narrow, per-program experiment, not a complete SIL parser or
a proof that the parser implements a separately formalized SIL grammar.

Limits are 256 KiB for the full input, 4,096 bytes per line, and a 180-second
production proof-process timeout. Chunk certificates have finite recursion
and heartbeat limits. These are rejection limits, not performance guarantees
for every input below them.

## Controls and regressions

The 42 controls comprise:

- Five successful reader cases: the fixed body, whitespace/comments, quoted
  paths containing comment/brace/escaped-quote characters, symbol mentions
  outside definitions, and a final line without a newline.
- Seven supported-syntax changes: swapped arithmetic operands, swapped
  branches, a wrong block argument, addition instead of subtraction, a wrong
  overflow projection, a wrong trap operand, and a removed trap. Each theorem
  requires **successful decoding and a different program**. Parser failure
  cannot satisfy these controls.
- Eighteen malformed/unsupported inputs: unknown instructions, builtins or
  types; signature/stage changes; missing, duplicate or nested definitions;
  bad braces, block structure, metadata, quotes, identifiers, projections,
  and out-of-range literals.
- Twelve proposal, business-contract, and evidence controls. These cover a
  wrong native proposal, a buggy Swift body, stale source/bundles, changed
  reader/proposer identities, altered embedded bytes/proofs, a missing
  decoding audit, changed SIL against its old collection, a missing bundle,
  and a missing Lean executable invalidating an old successful verdict.

The buggy Swift body still passes the old collector and receives
`SIL TRANSLATION VALIDATED`. Its business contract is `UNPROVED`, specifically
at `SwiftFormalV003.return_1`. Faithful decoding and translation do not imply
correct business logic.

The runner also executes five new Python tests, the seven existing 0.0.3
Python tests, the three 0.0.4 Python tests, the existing Swift exporter test,
and a Lean block-argument ordering theorem.

The only older implementation change is an optional proof timeout in the
shared checker; its default remains 60 seconds. Complete 0.0.3 and 0.0.4
workflows were rerun: their 23 and 18 controls still pass, respectively, and
0.0.4's 306 native comparisons still agree. Their regenerated evidence is
current. The original fixture, Swift packages, and 0.0.2 implementation were
not changed.

## Measurements and learning

One recorded local run, not a controlled benchmark:

| Work | Seconds |
|---|---:|
| Lean handoff proof | 25.251 |
| Bound handoff check, including regeneration and identity checks | 27.796 |
| Lean full proof, 14 roots | 58.344 |
| Bound full check | 62.510 |
| Entire experiment, including collection, controls, and buggy variant | 240.912 |

The initial monolithic string reader encountered opaque library operations,
deep-reduction failures, and multi-minute timeouts. Lean's kernel models
arrays using lists: a natively cheap indexed operation need not be cheap
during proof reduction.

The useful design change was raw byte lists, sequential processing, small
certified states, and a reusable composition lemma. Native computation can
suggest intermediate data without being trusted to establish its correctness.
The proof-producing path is still expensive; a fast runtime parser does not
imply a fast certificate checker. These measurements justify investigating
certificate reuse before expanding the language surface.

## Evidence and standalone checking

`.artifacts/` contains the fresh compiler collection, `bundle.json`, all three
generated proof sources, `environment.json`, handoff/full verdicts, the report,
reader control sources, the bad-proposal source, and the buggy-body evidence.
The report records commands, diagnostics, timings, source identities, and
individual control outcomes. It is initialized to `running` before version
or tool checks; a failed run cannot leave its old report marked successful.
Use `--output PATH` for a separate, single-writer run.

After running the experiment, from the workspace root:

```bash
EMITTER="$(swift build --package-path experiments/translation-validation --show-bin-path)/translation-emitter"
python3 -B experiments/sil-validation/verify.py \
  --emitter "$EMITTER" \
  --collection experiments/sil-validation/.artifacts/bridge/report.json \
  --fixtures experiments/compiler-bridge \
  --contract experiments/lean-proof/contract.json \
  --bundle experiments/sil-validation/.artifacts/bundle.json \
  --output experiments/sil-validation/.artifacts/cli-verdict.json
```

Use `--mode handoff` or `--mode translation` only when that narrower claim is
intended. The checker regenerates the bundle before and after Lean, binds the
raw artifact, contract, compiler collection, exporter, reader, proposer,
checker sources, and pinned Lean environment, and demands the exact audit
inventory. Altered production proof text is rejected before execution.
Fixed low-level test snippets are not an arbitrary-user-Lean endpoint.

## Remaining trust

The Swift extractor/direct encoder no longer has to be assumed correct for
this checked handoff: its instruction data must agree with the independent
reader. This is not a proof that either extractor is correct for every input.

Still trusted are the Swift compiler and collection/configuration binding;
the independently written SIL grammar and reference semantics as descriptions
of real SIL; host byte serialization and hashing; and Lean's kernel,
foundations, installed toolchain, operating system, and checking infrastructure.
The native state proposer is checked, not assumed correct.

No source-to-native-code refinement theorem, whole-language Swift verifier,
stable Swift library API, or production performance claim is established.
