# Should SwiftFormal replace Lean with its own "Lean"?

Research note, 2026-11-05.

- Lean version studied: 4.35.0 (source commit `eb6cafb`).
- All timings are from one machine: Apple M4 Pro, 14 cores, 24 GB of memory.
- Experiment files are outside the repository, in the session scratch folder (Appendix C).

## 1. Short answer

**No. Keep Lean.** Use it better, and add a second, independent check of
every proof.

Why:

1. **Most of our slowness comes from how we write proofs, not from Lean.**
   One small 8-line general lemma made the 0.0.5 proof about twice as fast
   (68 s → 32 s). It also cut peak memory from 6.5 GiB to 1.9 GiB. I applied
   the same change to 13 generated proofs from 0.0.5, 0.0.6 and 0.0.7, and no
   result changed. In the 5 proofs I measured both ways, CPU time fell by
   39–51% and memory by about 3×.
2. **Our own checker could not remove most of the remaining time.** I
   switched Lean's final checker off completely, and about 21 s of work
   remained. That work is reading the file, filling in details, running proof
   tactics and compiling. The final checker is only about 15–17 s of about
   36 s CPU. A home-made checker, even an instant one, only replaces that part.
3. **Our real trust problems are in our own glue code, not in Lean's
   checker.** I wrote 5 small files that "prove" false things or fake Lean's
   output. Our current audit accepts all 5 as `MODEL PROVED`. The fix is
   small and needs no new Lean:
   - accept a proof only if Lean wrote the compiled file;
   - re-check that file with one of the independent checkers that already ship
     with Lean.

   All six of them reject both false proofs. On our real proof, the three
   fastest take 1.5–3.5 s; Lean's own re-checker takes about 15 s.
4. **Building our own Lean is a very large, slow and risky project, and Lean
   is already building what we need.**
   - Lean's source is about 513,000 lines.
   - Even around its small trusted checker (6,215 lines), more than 15
     soundness and hardening fixes landed in July–August 2026.
   - Independent checkers took years, or an expert plus AI writing about
     150,000 lines of proof.
   - Lean's official plan for September 2026 to February 2027 is to make
     outside checking a routine step for every user.

A real example from today shows why this matters now. In the project's 0.0.7
run, the `wrong-guard-return` full proof (a wrong program that must be
rejected) hit the 180 s limit (180.6 s), and the whole run failed. A retry 6 minutes later finished the same file in 74.3 s. The
fixed version of this proof ran in 27.4 s using 2 GiB.

What to do instead, in order (details in §11):

1. Put the 8-line lemma into the proof generator (Appendix A).
2. Change acceptance: require Lean's compiled file, export it, and re-check
   it with an independent checker. Add the 5 bad files as must-reject tests
   (Appendix B).
3. Correct one wrong statement in our notes (`-t 0`). Don't depend on the
   `lean4lean` checker until its ordering bug is fixed.
4. Then work on the remaining speed:
   - reuse decoded SIL;
   - pack bytes compactly;
   - share repeated branches;
   - import less.

## 2. Words used in this note

| Word | Meaning here |
|---|---|
| **Kernel** | Lean's small final checker (6,215 lines of C++). It is the part of Lean we have to trust, together with the low-level runtime it runs on. If it has a bug, a false proof can pass. |
| **Front end** | Everything in Lean before the kernel: reading the file, filling in details ("elaboration"), running tactics such as `simp`, compiling code. It is not trusted; the kernel re-checks its output. |
| **Outside checker** | A separate program that re-checks finished proofs from the export. Lean 4.35.0 ships six (§7.4). `leanchecker` and `leanchecker-paranoid` run Lean's own kernel again; the second uses a hardened memory allocator. `nanoda`, `con-leche` and `con-ron` are independent implementations. `lean4lean` is a port of Lean's kernel into Lean. |
| **Export** | A text file listing every definition and proof a theorem depends on, made by `leanexport`. Outside checkers read it. |
| **`.olean`** | Lean's compiled module file. Lean writes it only when the whole file compiles. |
| **Axiom** | Something assumed without proof. We allow only Lean's three standard ones: `propext`, `Classical.choice` and `Quot.sound`. |
| **`sorry`** | Lean's placeholder for a missing proof. |
| **Wall time** | Clock time. |
| **CPU time** | User time summed over all threads. It can be larger than wall time because Lean uses several cores. |
| **Peak memory** | macOS "peak memory footprint" from `/usr/bin/time -l`, in GiB. |

## 3. What I looked at

- **Our experiments.**
  - All `experiments/*` folders and their `RESULTS.md` files.
  - `experiments/lean-proof/check.py`.
  - The roadmap
    (`archive/design/plans/2026-11-03-swiftformal-evidence-driven-roadmap.md`).
  - The other research note here
    (`docs/research/2026-11-05-nl2vc-dafny-paper-analysis.md`).
- **Lean's source code.**
  - Version 4.35.0, cloned and read.
  - The kernel, how declarations are added, the `-t` trust option, the
    `lake check` and `lake comparator` tools, and the export format.
  - Code sizes by directory.
- **Measurements.**
  - Lean's built-in profiler (`-Dprofiler=true`), `/usr/bin/time -l`, and
    small test files.
  - Most points were run 1–3 times.
  - The machine was often busy (load average 7–23), because another agent was
    running the 0.0.7 experiments at the same time. §6.4 shows where this
    matters.
- **Outside research.**
  - Two research agents covered Lean's internals and the wider field: other
    checkers, Lean's plans, and how others use AI with Lean.
  - I then checked the key quotes and numbers myself.

I changed no project files except adding this note. All test files are in the
session scratch folder (Appendix C).

## 4. The options

| Option | What it means |
|---|---|
| **A. Keep Lean, use it better** | Change the shape of generated proofs and how we run Lean. |
| **B. A + outside check** | Also accept a proof only from the compiled file, and re-check that file with an independent checker. |
| **C. Own kernel** | Keep Lean's front end. Write our own final checker (for example in Swift) that reads Lean's export. |
| **D. Fork Lean** | Copy Lean's code (Apache-2.0 allows this) and change it, for example to make the kernel faster on our byte data. |
| **E. Own language and tool** | Write our own proof language, front end and checker: a true "own Lean". |

## 5. What reading Lean's code taught us

Seven things in Lean's source matter for this decision:

1. **The trusted part is small; the rest is huge.**
   - The kernel is 6,215 lines out of 513,335 lines of source (1.2%).
   - The front end and libraries are almost all the rest.
   - Option C replaces only the small part. Option E must replace everything.
2. **The kernel has no "do not unfold" switch.** The `@[irreducible]`
   marking only affects the front end. The word does not appear anywhere in
   `src/kernel`. When the kernel compares two terms it may unfold any
   definition, including running our SIL decoder on all 80,419 bytes. This is
   the cause of our slowest step (§6.1).
3. **The kernel has built-in speed-ups only for natural numbers and
   strings.**
   - Big numbers use the GMP library. There is nothing similar for arrays or
     byte arrays.
   - A 512-byte chunk is checked as 512 nested list cells. Lean issue #14050
     (open) and the compiler roadmap concern arrays.
4. **A normal option can switch the kernel off.**
   - `set_option debug.skipKernelTC true` is defined in
     `src/Lean/Environment.lean:76–79`. Lean's own help text says it "may
     compromise soundness".
   - `src/Lean/AddDecl.lean:22–33` checks only this option.
   - The `-t` trust level our checker passes plays no part there.
5. **`-t 0` does not re-check imports in Lean 4.**
   - The trust level is only passed along and printed
     (`src/Lean/Shell.lean:554`, `src/Lean/Language/Lean.lean:504`,
     `src/Lean/Environment.lean:2506`).
   - The help text at `src/Lean/Shell.lean:158–159` still describes old
     behaviour.
   - Measured: `import Lean` (207,958 constants) loads in 1.75 s with or
     without `-t 0`.
   - So `experiments/lean-proof/RESULTS.md:134` ("the zero trust level also
     type-checks imported modules") is wrong.
6. **Lean already ships outside checking.**
   - Version 4.35.0 includes `leanexport`, six checkers that re-check exports,
     `lake check` and `lake comparator` (§7.4, §7.6).
7. **Lean changes often.**
   - Releases come about monthly. `RELEASES.md` says "There is not yet a
     strong guarantee of backwards compatibility between versions".
   - Version 4.22.0 alone had 468 changes.
   - Kernel rules still change. After 4.35 came the definitional-equality
     changes #15103 and #15371–#15373. Issue #14896 (open) would make
     theorems opaque to the kernel.
   - An own kernel or a fork must follow all of this.

## 6. Finding 1: the slowness comes mostly from our proof shape

### 6.1 Where the time went

I profiled the 0.0.5 full proof (my copy has sha `4ce51b6c`; see Appendix C).
The kernel spent 92.3 s in total:

| Kernel work | Time |
|---|---:|
| `SwiftFormalV005.correspondence` | 43.3–43.5 s |
| `SwiftFormalV005.totalCorrectness` | 17.9–31.9 s |
| 158 checks that each 512-byte SIL chunk decodes correctly | 16.8 s (50–230 ms each) |

The two ranges come from two profiled runs.

The two slow theorems are short "transfer" proofs. They carry the result proved
about the model over to the program decoded from SIL. Their proof says:

1. unfold "run the chunks";
2. replace the decoder's output with the known program;
3. use the model result.

While checking this, the kernel ends up running the decoder again over all
80,419 bytes. Point 2 of §5 explains why it can do that.

### 6.2 The fix

Prove one small fact once, for any input: "if decoding these chunks gives
program `p`, then running the chunks is the same as running `p`". The two
transfer theorems then just use it.

The kernel checks the general fact without ever seeing the 80 KB of data. In a
cut-down test the old, concrete form took about 18 s and the general lemma
under 0.2 s.

```lean
theorem executeChunks_of_read {cs : List (List UInt8)} {sym : String} {p : ReferenceIR.Program}
    (h : SILInput.readChunks cs sym = Except.ok p) (fuel : Nat) (s d : Int) :
    SILInput.executeChunks fuel cs sym s d = ReferenceIR.execute fuel p s d := by
  unfold SILInput.executeChunks
  rw [h]

theorem correspondence ... :=
  (executeChunks_of_read decodedProgram 20 subtotal discount).trans
    (SwiftFormalV004.correspondence subtotal discount _subtotal _discount)
```

Appendix A has the full diff, and a script applies it to any generated proof.
The theorem statements do not change. The new lemma uses only `propext`. The
profiled kernel time drops from 92.3 s to 17.1 s, which is now almost entirely
the 158 chunk checks.

### 6.3 Results on 13 proofs

**Both versions measured by me** (wall / CPU / peak memory):

| Proof | Before | After |
|---|---|---|
| 0.0.5 (median of 3 runs) | 68.2 s / 69.2 s / 6.5 GiB | 32.1 s / 35.9 s / 1.9 GiB |
| 0.0.6 original | 78.0 / 70.6 / 6.50 | 30.1 / 36.3 / 1.95 |
| 0.0.6 local result (2 runs each) | 160.7 and 93.1 / 76.4 and 73.0 / 6.53 | 30.2 and 31.8 / 37.2 and 36.7 / 1.97 |
| 0.0.7 guard, before the generator repair (2 runs each) | 146.3 and 113.6 / 72.5 and 72.7 / 6.50 | 28.8 and 31.4 / 36.2 and 37.1 / 1.95 |
| 0.0.7 eight diamonds\* | 100.8 / 93.9 / 7.56 | 40.6 / 57.1 / 2.46 |

The first four are accepted before and after. Eight diamonds is rejected
before and after, with the same 4 `simp` errors.

**Only "after" measured by me.** "Before" is the time the project recorded
for the same file. These are less strict comparisons:

| 0.0.7 case | Recorded before (s) | After: wall / CPU / peak | Result after |
|---|---:|---|---|
| early-return | 93.9 | 33.1 / 39.6 / 1.95 | proved (same) |
| joined | 71.5 | 32.0 / 41.5 / 1.96 | proved (same) |
| reused | 137.1 | 70.7 (very busy machine) / 43.4 / 1.97 | proved (same) |
| wrong-joined-return | 62.2 | 32.9 / 39.3 / 2.00 | rejected, same 2 errors |
| wrong-guard-return | 115.8 | 27.4 / 36.7 / 1.97 | rejected, same error |
| diamonds-1 | 64.1 | 29.4 / 39.0 / 2.03 | rejected, same 4 `simp` errors\* |
| diamonds-2 | 68.4 | 28.5 / 38.3 / 2.02 | same\* |
| diamonds-4 | 87.9 | 31.4 / 42.1 / 2.08 | same\* |

\* These diamond versions, in both tables, came from before the other agent
repaired a generator defect, the "`simp` made no progress" errors
(`experiments/control-flow/RESULTS.md:94–110`). The fix does not touch those
lines, and the errors stayed the same.

In summary:

- **In the 5 proofs measured both ways:**
  - CPU time fell by 39–51%;
  - peak memory fell 3.1–3.4×;
  - wall time fell 2.1–5.3×.
- **In the other 8,** wall time went from 62–137 s (recorded) to 27–33 s,
  except one 71 s run on a very busy machine.
- **Every proof that was accepted is still accepted. Every proof that was
  rejected is still rejected with the same errors.**

### 6.4 Why wall times jumped around: memory pressure

The old shape needs 6.5–7.6 GiB of memory. Besides CPU time,
`/usr/bin/time -l` reports:

- **system time:** time macOS spends working for Lean, mostly on memory;
- **page reclaims:** how many times macOS had to supply a page of memory when
  Lean touched it.

| Runs | System time per run | Page reclaims per run | Peak memory |
|---|---:|---:|---:|
| Old shape (10 runs) | 4–71 s | 1.0–25.4 million | 6.5–7.6 GiB |
| Fixed shape (18 runs) | 1.5–2.6 s (one run 4.5 s) | 0.3–0.5 million | 1.9–2.5 GiB |

- In the old shape, system time grew in step with page reclaims.
- The four old-shape runs made before 06:00 had 4–9 s of system time. The six
  made after 06:00 had 14–71 s. Fixed runs made in between stayed at about
  2 s.
- The most likely cause is memory pressure from the other agent's runs. When
  memory is short, macOS takes pages away from a large process and must supply
  them again when it touches them. A 2 GiB process is hit much less than a
  6.5 GiB one. I did not measure memory pressure directly.

Examples:

- **Same old guard file, run twice:** 146.3 s and 113.6 s wall, with the same
  CPU time (72.5 s and 72.7 s). Each run also spent 43–47 s of system time.
  The fixed file, run in between, spent 1.5–1.8 s.
- **Today's 0.0.7 run:** `wrong-guard-return` timed out at 180.6 s, then took
  74.3 s on a retry 6 minutes later. The input was the same, sha `44ccb3bf`
  (`.artifacts/wrong-guard-return/full-verdict.json` and
  `full-retry-verdict.json`). The fixed version of this proof took 27.4 s. My
  copy differs from today's file only in the 5 repaired `simp`→`rw` lines; the
  slow transfer part is identical.
- **The 0.0.6 local-result case:** it was recorded at 123.0 s against 70.7 s
  for the original (`experiments/local-variables/RESULTS.md:143–159`), which
  "does not isolate the cause". In my runs its CPU time was only 3–8% higher
  than the original's. Memory pressure is the most likely cause of the gap.

So the old shape is not only slow; on a busy machine its timing is
unreliable, and that can push proofs past the 180 s limit.

### 6.5 What remains with Lean's checker switched off

To learn what a perfect home-made kernel could save at most, I compiled the
fixed 0.0.5 proof with the kernel switched off
(`set_option debug.skipKernelTC true`) and profiled it:

| Work left with the kernel off | Time |
|---|---:|
| Elaboration (filling in details, running tactics) | 8.4 s |
| Compiling definitions to code | 4.9 s |
| Running Lean code during the build | 2.9 s |
| Type class search | 2.7 s |
| Loading imports | 2.4 s |
| Linting, parsing and other small items | about 2.1 s |
| Kernel | 0.05 s |
| **Total CPU (user time)** | **20.7 s**, plus 2.3 s system time; wall 22.3 s |

The profiler's items add up to about 23 s, a little more than the CPU time,
so treat them as rough shares. A second kernel-off build, made later on a
busier machine, used 25.8 s of CPU.

- **About 21 s of CPU remains without any kernel** (26 s in the busier run).
  With the kernel, the same proof needs about 36 s CPU. Even an infinitely
  fast home-made kernel would save only about 15–17 s per proof. Option C does
  not touch the rest, and Option E would have to rebuild all of it.
- **The export from the kernel-off build is byte-identical to the normal
  export** (sha `31713272…`). So "build without the kernel, then check the
  export with an outside checker" already works on our proofs. Lean's roadmap
  plans exactly this mode (§9).

### 6.6 Other measurements

- **The library part is cheap; per-function work dominates.** I split the
  fixed proof:
  - the shared library part (lines 1–762) builds in 2.6 s;
  - the per-function part takes 25.6–25.8 s wall and 34.6–34.8 s CPU.

  So about 95% of the CPU time is per-function work.
- **The decoding stage and the full stage both check the 158 chunks.** In
  0.0.7, `decoding.lean` and `full.lean` contain the same 159
  `decide +kernel` checks and the same `decodedProgram` theorem. In today's
  project run:
  - the decoding stage alone took 27.4 s of Lean time for `original`;
  - after the fix, the full proof costs about the same as that stage.

  Reusing the checked decoding would remove repeated work.
- **The kernel is slow on byte lists.** I ran a benchmark that scans the real
  80,419-byte SIL file (158 chunks of 512 bytes), with each chunk checked by
  the kernel:

  | Encoding of bytes | Kernel | Elaboration | CPU | Peak |
  |---|---:|---:|---:|---:|
  | List of characters | 10.3 s | 7.8 s | 25.8 s | 1.83 GiB |
  | List of `UInt8` (today's choice) | 9.2 s | 7.1 s | 23.7 s | 1.81 GiB |
  | List of `Nat` | 9.3 s | 7.3 s | 23.7 s | 1.76 GiB |
  | Packed: one big number per chunk | 12.0 s | 0.6 s | 12.9 s | 0.51 GiB |

  - Python does the same scan in 6.8 ms. The kernel needs about 114 µs per
    byte, over 1,000× slower.
  - Packing bytes into big numbers halves the CPU time and cuts memory 3.5×,
    because elaboration nearly disappears. The kernel part itself gets a
    little slower (9.2 s → 12.0 s).
- **A byte-literal helper** (a 7-line `bytes%` notation) cut elaboration from
  7.5 s to 0.5 s and peak memory from 1.88 to 0.94 GiB. It cut CPU from
  34.6–34.8 s to 26.0 s, but wall time did not improve: 28.0 s in one run,
  against 25.6–25.8 s without the helper. Lean was already doing that work in
  parallel, off the slowest path. It adds a small helper we must trust or check:
  the produced bytes must be compared with the SIL file, which the export makes
  possible.

### 6.7 Speed ideas, ranked

| Idea | Measured? | Effect | Changes trust? | Needs own Lean? |
|---|---|---|---|---|
| General transfer lemma (§6.2) | Yes, 13 proofs (5 both ways) | CPU −39–51%, memory ÷3 | No | No |
| Decode each SIL file once; reuse the checked result for every function and stage | No | Up to about 17 s per extra function or stage | No, if done as a proved lemma | No |
| Packed byte encoding | Yes, benchmark | About half the CPU, memory ÷3.5 on the scan | No (the kernel still checks it) | No |
| Share repeated branches in generated proofs | No | diamonds-8 still needs 57 s CPU after the fix: 512 return cases | No | No |
| Mark generated data `noncomputable` (skip compiling it to code) | No | Up to about 4.4–4.9 s | No | No |
| Import only what we need instead of all of `Lean` | No | About 1–2 s | No | No |
| `bytes%` literal helper | Yes | CPU about −9 s, memory ÷2, wall not better | Yes, needs a byte check | No |
| Build without the kernel, then outside check | Partly (identical export) | Avoids checking twice once outside checks are required: saves about 15–17 s CPU per proof | Better: independent check | No |
| Kernel support for byte arrays | — | Would shrink the about 17 s of chunk checks | — | Fork (D), or wait for Lean (#14050, roadmap) |

Only the last row would need a change inside Lean. Lean already plans it, and
the reuse idea removes most of the same cost without touching Lean.

### 6.8 Roadmap time targets

The roadmap (lines 530–532) targets:

- at most 2 s extra for interactive use (p95);
- at most 60 s for a 100-obligation CI batch;
- a 10 s stop per obligation.

After the fix, one function still takes 27–41 s of wall time (one run on a
very busy machine took 71 s). **No option meets these
targets by itself.** The gap is per-function front-end work and repeated SIL
decoding, which reuse and incremental builds address. A new kernel cannot
close it, because about 21 s per proof is not kernel work.

## 7. Finding 2: the trust holes are around Lean, not in it

### 7.1 How we accept a proof today

`experiments/lean-proof/check.py` works like this:

1. It runs `lean --json --stdin -t 0` (line 16).
2. `audit()` (lines 74–111) accepts if all of these hold:
   - Lean exits with 0;
   - stderr is empty;
   - every message is an "information" line of the form "`X` does not depend
     on any axioms" or "`X` depends on axioms: […]";
   - each expected theorem appears once, with only the 3 allowed axioms
     (line 14).

`verify()` (line 241) also requires the proof text to be identical to what our
generator produced. **This keeps today's pipeline safe while no AI or outside
text enters proof files.** The roadmap plans to let AI write proof steps in a
"constrained proof slot" (line 363). From then on, the audit alone decides.

### 7.2 Five files that must be rejected but pass

I re-ran all five today through the real `check.audit`:

| File | Trick | `check.audit` | Lean writes `.olean`? | Outside checkers |
|---|---|---|---|---|
| `BogusProof` | Switch the kernel off for one theorem, "prove" `2 + 2 = 5`, then derive `False` | **MODEL PROVED** | Yes | **All six reject** |
| `SlotBogus` | The same trick inside a `by` proof block, the "proof slot" | **MODEL PROVED** | Yes | **All six reject** |
| `Spoof` | `run_cmd` prints a fake "does not depend on any axioms" line and exits 0; the theorem is `sorry` | **MODEL PROVED** | **No** | — |
| `SlotSpoof` | The same fake output from inside a proof block (`run_tac`) | **MODEL PROVED** | **No** | — |
| `NoImportSpoof` | The same with `#eval` and no imports | **MODEL PROVED** | **No** | — |

- For `BogusProof` and `SlotBogus`, Lean itself prints "'bad' does not depend
  on any axioms" for a proof of `False`. Reading Lean's printed messages
  cannot catch this.
- The spoof files stop Lean before it writes the compiled file, so
  **requiring the `.olean` catches all three**.
- On the two bogus exports, every outside checker failed:
  - `leanchecker` and `leanchecker-paranoid`: exit 1;
  - `nanoda`: stops with a failed check, exit 101;
  - `con-leche`, `con-ron` and `lean4lean`: report "application type mismatch".
- The roadmap already asks for these tests (line 471): "False statement,
  `sorry`, additional axiom, changed definition, missing obligation, and
  forged/stale result".

### 7.3 A wrong belief in our notes

`experiments/lean-proof/RESULTS.md:134` says the zero trust level "also
type-checks imported modules". That is not true in Lean 4.35.0 (§5, point 5).
`-t 0` is harmless, but it gives no protection.

### 7.4 Outside checkers: cost and results on our real proof

The fixed 0.0.5 proof exports to 3,124 declarations, in 2.7 s and 0.46 GiB.
All six checkers ship in the 4.35.0 toolchain:

| Checker | Fixed proof: wall / CPU / memory | Old proof shape: wall | Result |
|---|---|---:|---|
| `con-ron` (Rust) | 1.5 s / 15.4 s / 1.39 GiB | 14.6 s | accepts |
| `nanoda` (Rust) | 2.9 s / 10.8 s / 1.24 GiB | 16.8 s | accepts |
| `con-leche` (Lean, with a proof that it cannot accept `False`) | 3.5 s / 37.3 s / 0.78 GiB | 79.2 s | accepts |
| `leanchecker` (official kernel, run again) | 15.4 s / 15.2 s / 0.18 GiB | 45.1 s | accepts |
| `lean4lean` (Lean port of the kernel) | 22.0 s / 21.7 s / 0.14 GiB | **false rejection** (§7.5) | accepts the fixed proof |
| `leanchecker-paranoid` | 22.5 s / 22.3 s / 0.13 GiB | 61.9 s | accepts |

Memory in this table is maximum resident memory.

- The fix makes outside checking cheap: 1.5–3.5 s with the fast checkers.
  Lean's own `leanchecker` takes about 15 s, and can run at the same time.
- The public Kernel Arena (247 tests, 80 of them must-reject, fetched
  2026-11-05) gives a sense of how hard checkers are to get right:
  - the official kernel, `lean4lean`, `con-leche` and `con-ron` wrongly accept
    none of them;
  - `nanoda` wrongly accepts one;
  - 12 of 32 real checkers there wrongly accept at least one.
- `con-leche` and `con-ron` decline a few unusual inputs (6 of 137 good tests),
  so keep the official `leanchecker` as a second opinion.

### 7.5 A bug found: `lean4lean` rejects our valid proof

- `lean4lean` rejects the original 0.0.5 proof in 0.38 s with "unknown
  constant 'Char.ofNat'". The proof is valid; every other checker accepts it.
- The cause is in `lean4lean`'s `Lean4Lean/Replay.lean` (lines 170–181 in the
  bundled version):
  - it switches on string support before `String.ofList` and `Char.ofNat` have
    been loaded;
  - that order comes from a hash of names, and private names include the
    module name.
- After I renamed the module, the same proof passed, in 57.5 s.
- `lake check --paranoid` runs `lean4lean`, so it can reject valid proofs
  like ours, depending on names.
- The upstream issue digama0/lean4lean#66 (open, 2026-10-21) describes the
  same family of bug, depending only on names. It mentions a similar old bug in
  `leanchecker` (lean4#15643).
- We should report our case and not make `lean4lean` a required gate yet.

### 7.6 What Lean's own tools now offer

- **`lake check`** builds, exports and re-checks with the official kernel,
  optionally with other kernels (`--paranoid`). It checks used axioms against
  the standard three (`src/lake/Lake/CLI/Check.lean:662–675`).
- **`lake comparator`** checks that a solution's theorem statements, and the
  definitions they use, are identical to a reviewed "challenge" file
  (`src/lake/Lake/Check/Compare.lean:50–106`).
  - In my test it caught a changed definition (`def f x := 0` against `x + 1`)
    with "Const does not match".
  - This is what we need once AI writes proof steps. It is stronger than
    comparing text, and the roadmap notes: "Hashing statements alone does not
    protect changed definitions" (line 364).
- **Sandbox:** both tools use `bwrap`, which is Linux only. On macOS they
  refuse to run unless given `--inadvisably-no-sandbox`. Lake then prints
  "WARNING: Sandbox disabled, this run is not trustworthy." Final acceptance
  should therefore run in Linux CI or a container.

### 7.7 What this means for "own Lean"

All five holes are in how we read Lean's results. A home-made Lean would need
the same fixes: check compiled proof terms, not printed text. A new kernel
would also bring its own bugs (12 of 32 arena checkers have at least one wrong
accept). The safest checker setup is the one Lean's authors now recommend:
one official kernel plus at least one independent checker.

## 8. Finding 3: what "own Lean" would cost

### 8.1 Size

| Part of Lean 4.35.0 | Lines |
|---|---:|
| Kernel (trusted) | 6,215 C++ |
| Other C/C++ (runtime, numbers, threads) | 25,737 |
| `Init` (core library) | 139,018 |
| `Std` (standard library) | 139,063 |
| `Lean` (front end, tactics, compiler, editor support) | 181,751 |
| Lake (build tool) | 20,353 |
| **All of `src/`** | **513,335** (plus 227,064 lines of tests) |

Some tactics we rely on, or may need, are big on their own: `simp` about 6,400
lines, `omega` 2,200, `grind` 31,000, `bv_decide` 20,000.

| Checker or kernel | Size | Effort |
|---|---|---|
| `nanoda` (Rust) | about 6,100 lines | Mostly one author, since 2020 |
| `lean4lean` (Lean) | about 3,000–3,900 lines + 18,000–25,000 lines of proof | Since 2023; still 27 unfinished proof steps (`sorry`) |
| `con-leche` (Lean) | about 24,000–26,000 lines + 135,000–150,000 lines of proof | A Lean FRO engineer and Claude, "under heavy supervision": 6,846 commits in about 10 weeks (Aug–Oct 2026) |
| HOL Light kernel | about 400 lines | Much simpler logic |
| mm0-c | 2,857 lines | Much simpler logic |
| Rocq (Coq) kernel | 35,000–44,000 lines | Decades of work |
| Milawa | 1,700-line kernel | A multi-year PhD |

Line counts differ by counting tool, so the table gives ranges. The very small
kernels check simpler logics. A checker for Lean must handle all of Lean's
logic: inductive types, universes, quotients, unfolding rules and number
literals. Our proofs use many of these features.

### 8.2 Bugs happen even in a small kernel

- Lean's kernel had about 1–4 soundness fixes per year in 2022–2025.
- In July–August 2026, after an AI-assisted bug hunt, more than 15 soundness
  and hardening fixes landed (Lean FRO postmortem, 2026-08-24).
  - Most were reachable only through metaprogramming, meaning Lean code that
    runs during the build. An AI-written proof could contain exactly that.
  - Several commit messages say an independent checker rejects the exploit
    or was not affected: #14613 "nanoda rejects it", #14838 "nanoda … not
    affected".
- In one case (#14576, July 2026), an AI-assisted false "disproof" of the
  Collatz conjecture passed the official kernel. Fooling both the official
  kernel and `nanoda` needed two unrelated bugs, one in each; `nanoda`'s had
  been fixed a week earlier. The official fix landed about an hour after the
  report. Leo de Moura wrote: "checking with an independent kernel still
  works, since it required two distinct bugs in two implementations, but users
  who rely on it need current versions of both."
- A home-made kernel would start with no such testing history.

### 8.3 Upkeep

- **Option C (own kernel):** it must follow every change to Lean's logic
  and to the export format, now version 3.1.0. Otherwise we pin an old
  Lean forever and lose fixes.
- **Option D (fork):** it must merge about monthly releases with hundreds of
  changes each. I found no long-lived Lean fork. A known performance patch set
  (Dan Romik, on 4.33.1) stays a patch set on purpose.
- **Option E (own language):** it needs a front end, tactics, a library, a
  build tool and editor support. Our current proofs use `decide +kernel`,
  `simp`, `omega`, `rw` and `cases`. Lean has hundreds of thousands of lines
  behind these.

### 8.4 Our pains and the smallest fix for each

| Problem we have | Would own Lean help? | Smallest fix |
|---|---|---|
| Two slow transfer theorems | No, this is proof shape | 8-line lemma (tested, §6.2) |
| 6.5–7.6 GiB memory and timeouts on a busy machine | No | Same lemma: about 2 GiB |
| About 21 s of front-end work per proof | Only by rebuilding the front end (E) | Reuse, packing, fewer imports (§6.7) |
| Kernel slow on byte lists (about 114 µs per byte) | Yes, in principle (C or D) | Packed encoding now; Lean's array work later |
| Audit accepts false proofs and fake output | No, this is our glue | Require `.olean`, export, outside check |
| `lean4lean` false rejection | No | Don't make it a gate; report it |
| Branch growth (diamonds-8: 512 return cases) | No, this is the generator | Share continuations in the generator |

## 9. Finding 4: where Lean and the field are going

- **Lean's own plan matches Option B.** The Lean FRO roadmap for September
  2026 to February 2027 (Y4-1) says:
  - "External checking must become a routine part of every Lean user's
    workflow, not an expert-only activity."
  - "`lake check` exports a development and rechecks it with the official
    kernel, including the comparator prelude checks; `lake check <kernel>`…;
    `lake check --paranoid`…"
  - "We will include comparator in the Lean distribution."
  - "We will also add a mode where `lake build` skips the official kernel
    checks and only produces oleans. Users then run `lake check` to validate
    everything with their favorite checker."

  It also plans "better support for array manipulating programs" (design now,
  implementation in 2027), a new `do` notation and a VC generator. Those are
  the areas where we feel pain today.
- **Lean is building verified checkers.** De Moura (2026-10-15) expects
  `lean4lean`'s verification "in the next few months". `con-leche` already has
  a proof that it cannot accept `False`.
- **How others check AI-written proofs** is the same three-step check we need:
  - Terence Tao (2026-08-18): "one has to first check that the claimed formal
    Lean statements have proofs that typecheck, that the proofs do not contain
    any 'cheats' such as adding additional axioms, and that the formal
    statements also match (in a semantic sense) the informal description of
    the claimed results."
  - Anthropic's Fermat's Last Theorem formalisation (2026-09-04, about 13
    million lines) reports "relying only on Lean's three standard axioms, with
    no unproved placeholders (`sorry`)".
  - The fake "proof" shown by Trail of Bits (2026-09-09) relied on
    `native_decide`. That adds an extra axiom, which our axiom rule rejects.
- **Production software verification keeps Lean and tests the gap.** AWS
  Cedar proves properties of a Lean model. It links the model to the real Rust
  code with differential random testing and property-based testing (arXiv
  2407.01688). This is the same kind of gap as our Swift compiler and SIL
  semantics.
- **AI writes Lean proofs less easily than Dafny proofs.**
  - The vericoding benchmark (arXiv 2509.22908) found off-the-shelf success
    rates of 82% for Dafny, 44% for Verus and 27% for Lean.
  - The tasks differ by language, and this is about AI writing proofs, not
    about Lean's checker.
  - The fitting answer is a stronger proof-search tier in front of Lean, such
    as the hybrid option C in the NL2VC note
    (`docs/research/2026-11-05-nl2vc-dafny-paper-analysis.md`, §6). It is not
    a replacement for Lean's checker.
  - Neither that note nor this one measured such a tier.
- **Our roadmap already says this.** Line 412: "No server, daemon, solver
  portfolio, or custom theorem-proving kernel is needed." Line 231: "AI may
  propose; a deterministic checker and policy decide."

## 10. Options compared

| | A. Use Lean better | B. A + outside check | C. Own kernel | D. Fork Lean | E. Own language |
|---|---|---|---|---|---|
| Speed | **Measured:** about 2× wall, ÷3 memory; more from §6.7 | Same as A | At most about 15–17 s of about 36 s CPU per proof, if instant | Could add byte arrays to the kernel (about 17 s) | Unknown; must rebuild about 21 s of front-end work |
| Trust | Small gain | **Closes all 5 holes found** | New, untested checker; glue still needs fixing | No gain; our checker differs from everyone else's | Starts from zero |
| Cost to build | Days | 1–2 weeks | Months to years | Weeks, then ongoing | Years |
| Upkeep | Follow Lean releases (as now) | Same; the checkers ship with Lean | Follow every logic and format change | Merge about monthly releases forever | Everything, forever |
| Risk | Low | Low | High: soundness bugs, false rejections | Medium to high: drift, lost tools | Very high |
| Fits our roadmap | Yes | Yes (lines 231, 363, 471) | No (line 412) | No | No |

**Choose A + B now.** Do not start C, D or E. Look again only if a trigger in
§12 happens.

## 11. Plan

1. **Generator fix** (1–2 days).
   - Emit `executeChunks_of_read` once, and use it in both transfer theorems.
     The generator lives in `lean-proof/Sources/LeanProof/LeanEmitter.swift`.
     The other agent's 0.0.7 generator repair does not include this change yet.
   - Re-run 0.0.5–0.0.7. Expect the same verdicts, about 2× faster, about 3×
     less memory.
   - Record CPU time and peak memory in verdicts, not only wall time, so
     load problems are visible.
2. **Acceptance through the compiled file** (about 1 week).
   - Compile with `lean -o` and require the `.olean`.
   - Export the expected theorems with `leanexport`; it includes everything
     they depend on.
   - Re-check with `con-ron` or `nanoda` and with `leanchecker`. Reject if any
     of them rejects.
   - Check axioms in the export, not in printed text. `nanoda` and
     `lake check` already do this.
   - Add the 5 files in Appendix B as must-reject tests (roadmap line 471).
   - Before AI or outside text can enter proof files:
     - run acceptance in a Linux sandbox;
     - use `lake comparator`, or the same idea, so that statements and the
       definitions they use must match the reviewed ones.
3. **Housekeeping** (hours).
   - Correct `experiments/lean-proof/RESULTS.md:134` (§7.3).
   - Report the `lean4lean` false rejection upstream; our file is a ready test
     case.
   - Don't use `lake check --paranoid` as a required gate until it is fixed.
4. **Next speed round** (1–3 days each; measure each one).
   - Decode each SIL file once, and reuse the result across functions and
     stages.
   - Pack bytes into big numbers.
   - Share repeated branches in the generator.
   - Mark generated data `noncomputable`, and import less.
5. **Measure against the roadmap targets** (p50 and p95) with the new shape.
6. **Later:** when Lean ships "build without the kernel, then `lake check`",
   switch to it. Once every proof is checked outside anyway, this avoids
   checking each proof twice. §6.5 shows our export is unchanged by that mode.

## 12. When to look at this question again

Revisit "own kernel" or "fork" only if one of these happens:

- After steps 1–4, the kernel is still the largest cost per proof, and
  Lean's array work (#14050, the 2027 compiler plan) has not landed by the end
  of 2027.
- Lean upgrades break our generated proofs again and again, and pinning a
  version stops being acceptable.
- A soundness bug hits both the official kernel and our chosen outside
  checker, with no fix within days.
- We must check proofs somewhere none of the existing checkers can run, such
  as inside an app without a Lean toolchain. Even then, porting `nanoda`
  (about 6,100 lines of Rust) is cheaper than writing a kernel from scratch.
- Lean's licence (Apache-2.0) or its funding and governance change for the
  worse.

## 13. Limits of this research

- **One machine, often busy, mostly 1–3 runs per point.** CPU time is
  steadier than wall time, so I give both.
- **One contract family** (the discount function). Larger programs may
  behave differently.
- **For 8 of the 13 proofs I measured only the fixed version.** For those,
  "before" is the project's recorded time.
- **The 0.0.7 files changed during this research** (the other agent's
  generator repair). Appendix C identifies every file I measured by hash.
- **Some ideas in §6.7 are unmeasured.** Their effects are estimates from
  profiles.
- **I did not build a prototype kernel.** Cost figures come from other
  projects.
- **I did not evaluate SMT or Dafny-style automation;** see the NL2VC note.
- **The `lean4lean` bug cause comes from reading its source.** I did not
  write a fix.

## 14. Sources

**Project files**

- `experiments/lean-proof/check.py`: lines 14, 16, 74–111 and 241.
- `experiments/lean-proof/RESULTS.md:134`.
- `experiments/local-variables/RESULTS.md:143–159`.
- `experiments/sil-validation/RESULTS.md:155–165`: kernel cost of byte
  reading, and "investigating certificate reuse".
- `experiments/control-flow/RESULTS.md`:
  - lines 80–92: branch growth, 512 return cases at 8 diamonds;
  - lines 94–110: the generator repair;
  - lines 137–140: stage limits.
- `experiments/control-flow/.artifacts/report.json`,
  `wrong-guard-return/full-verdict.json`, `full-retry-verdict.json` and
  `recovered-report.json` (all from 2026-11-05).
- `archive/design/plans/2026-11-03-swiftformal-evidence-driven-roadmap.md`:
  lines 231, 363–364, 372, 412, 471 and 530–532.
- `docs/research/2026-11-05-nl2vc-dafny-paper-analysis.md`: §6, and line 59
  for the vericoding numbers.

**Lean source** (v4.35.0, commit `eb6cafb`, <https://github.com/leanprover/lean4>)

- `src/kernel/`: 6,215 lines; no `irreducible`.
- `src/kernel/environment.h:20–23` and `src/library/elab_environment.cpp:70`:
  trust level constants.
- `src/Lean/Environment.lean:76–79` (`debug.skipKernelTC`) and `:2506`.
- `src/Lean/AddDecl.lean:22–33`.
- `src/Lean/Shell.lean:158–159`, `:371–378` and `:554`;
  `src/Lean/Language/Lean.lean:504`.
- `src/lake/Lake/CLI/Check.lean:662–675`;
  `src/lake/Lake/Check/Compare.lean:50–106`;
  `src/lake/Lake/Check/Axioms.lean:57–95`.
- `RELEASES.md`.
- Issues and pull requests: #14050, #14576 and #14577, #14613, #14838,
  #14896, #15103, #15371–#15373, #15643.

**Outside**

- Lean FRO roadmap Y4-1: <https://lean-lang.org/fro/roadmap/y4-1/>
- Postmortem for #14576: <https://leodemoura.github.io/blog/2026-8-1-postmortem-for-kernel-soundness-bug-14576/>
- Postmortem for the bug hunt: <https://leodemoura.github.io/blog/2026-8-24-postmortem-for-the-kernel-soundness-bug-hunt/>
- "Lean now ships with verified kernels": <https://leodemoura.github.io/blog/2026-10-15-lean-now-ships-with-verified-kernels/>
- Kernel Arena: <https://arena.lean-lang.org/> (`results.json` fetched 2026-11-05)
- Checkers:
  - <https://github.com/ammkrn/nanoda_lib>
  - <https://github.com/digama0/lean4lean> (issue #66) and the bundled fork
    <https://github.com/Kha/lean4lean>
  - <https://github.com/leanprover/con-leche>
  - <https://github.com/leanprover/con-ron>
- Candle (verified HOL Light): ITP 2022, <https://drops.dagstuhl.de/storage/00lipics/lipics-vol237-itp2022/LIPIcs.ITP.2022.3/LIPIcs.ITP.2022.3.pdf>;
  JAR 2025, <https://link.springer.com/article/10.1007/s10817-025-09743-8>
- HOL Light kernel: <https://raw.githubusercontent.com/jrh13/hol-light/master/fusion.ml>
- mm0-c: <https://github.com/digama0/mm0/tree/master/mm0-c>
- Rocq kernel: <https://github.com/rocq-prover/rocq/tree/master/kernel>
- Milawa: <https://www.cl.cam.ac.uk/~mom22/2015-jar-milawa.pdf>
- Terence Tao, Palomar: <https://terrytao.wordpress.com/2026/08/18/palomar-a-registry-of-lean-verified-mathematics/>
- Anthropic, Fermat's Last Theorem: <https://www.anthropic.com/research/formalizing-fermats-last-theorem>
- Trail of Bits: <https://blog.trailofbits.com/2026/09/09/a-proof-of-fermats-last-theorem-that-fits-the-margin/>
- Cedar: <https://arxiv.org/abs/2407.01688>
- Vericoding: <https://arxiv.org/abs/2509.22908>

## Appendix A: the fix

Diff against the 0.0.5 proof (`experiments/sil-validation/.artifacts/proof.lean`
as copied on 2026-11-04 at 14:27, sha `4ce51b6c`):

```diff
@@ -3461,22 +3461,27 @@
   decide +kernel
 
 
+theorem executeChunks_of_read {cs : List (List UInt8)} {sym : String} {p : ReferenceIR.Program}
+    (h : SILInput.readChunks cs sym = Except.ok p) (fuel : Nat) (s d : Int) :
+    SILInput.executeChunks fuel cs sym s d = ReferenceIR.execute fuel p s d := by
+  unfold SILInput.executeChunks
+  rw [h]
+
+
 theorem correspondence (subtotal discount : Int)
     (_subtotal : SwiftFormalV003.Fits subtotal) (_discount : SwiftFormalV003.Fits discount) :
     SILInput.executeChunks 20 chunks selectedSymbol subtotal discount =
-      SwiftFormalV004.lift (SwiftFormalV003.implementation subtotal discount) := by
-  unfold SILInput.executeChunks
-  rw [decodedProgram]
-  exact SwiftFormalV004.correspondence subtotal discount _subtotal _discount
+      SwiftFormalV004.lift (SwiftFormalV003.implementation subtotal discount) :=
+  (executeChunks_of_read decodedProgram 20 subtotal discount).trans
+    (SwiftFormalV004.correspondence subtotal discount _subtotal _discount)
 
 
 theorem totalCorrectness (subtotal discount : Int)
     (_inputs : SwiftFormalV003.Inputs subtotal discount) :
     SILInput.executeChunks 20 chunks selectedSymbol subtotal discount =
-      ReferenceIR.Outcome.returned (SwiftFormalV003.expectedResult subtotal discount) := by
-  unfold SILInput.executeChunks
-  rw [decodedProgram]
-  exact SwiftFormalV004.totalCorrectness subtotal discount _inputs
+      ReferenceIR.Outcome.returned (SwiftFormalV003.expectedResult subtotal discount) :=
+  (executeChunks_of_read decodedProgram 20 subtotal discount).trans
+    (SwiftFormalV004.totalCorrectness subtotal discount _inputs)
 
 
 theorem noTrap (subtotal discount : Int)
@@ -3488,6 +3493,7 @@
   cases impossible
 
 
+#print axioms SwiftFormalV005.executeChunks_of_read
 #print axioms SwiftFormalV005.decodedProgram
 #print axioms SwiftFormalV005.correspondence
 #print axioms SwiftFormalV005.totalCorrectness
```

The `#print axioms` line for the new lemma is optional, because axiom reports
include dependencies. If it is added, the expected theorem list in the checker
must include the new lemma.

The script `bench/v006/apply_fix.py` (Appendix C) applies the same change to
any generated proof, for any fuel value. It was used for all 13 proofs.

## Appendix B: the five must-reject files

All five get `{'status': 'MODEL PROVED'}` from `experiments/lean-proof/check.py`
`audit()` with Lean 4.35.0 (re-run 2026-11-05).

`BogusProof.lean`:

```lean
set_option debug.skipKernelTC true in
theorem twoPlusTwo : (2 : Nat) + 2 = 5 := by decide +kernel

theorem bad : False := absurd twoPlusTwo (by decide)

#print axioms bad
```

`SlotBogus.lean`:

```lean
theorem slot : (2 : Nat) + 2 = 5 := by
  set_option debug.skipKernelTC true in decide +kernel
theorem bad : False := absurd slot (by decide)
#print axioms slot
#print axioms bad
```

`Spoof.lean`, where `FAKE` stands for a JSON line copied from a real
`#print axioms` message that says "'main_claim' does not depend on any axioms":

```lean
import Lean
open Lean Elab Command

run_cmd do
  let h ← IO.FS.Handle.mk "/dev/stdout" .write
  h.putStrLn FAKE
  h.flush
  (IO.Process.exit 0 : IO Unit)

theorem main_claim : False := sorry

#print axioms main_claim
```

`SlotSpoof.lean` does the same from inside a proof, with `run_tac do …` in
`theorem slot : (2:Nat) + 2 = 5 := by`. `NoImportSpoof.lean` does the same
with `#eval (do …)` and no imports. The full files are in the scratch folder.

## Appendix C: how to reproduce

Scratch folder (outside the repository):
`<session-scratch>/bench`

```sh
TC=~/.elan/toolchains/leanprover--lean4---v4.35.0
B=<session-scratch>/bench

# 1. Apply the fix to any generated proof
python3 $B/v006/apply_fix.py proof.lean proof_fixed.lean

# 2. Time it the way check.py runs Lean
/usr/bin/time -l $TC/bin/lean --json --stdin -t 0 < proof_fixed.lean > out.json

# 3. Profile it
$TC/bin/lean -Dprofiler=true --json --stdin -t 0 < proof_fixed.lean 2> prof.err

# 4. Compile, export and check with outside checkers
#    (the module is named SwiftFormalProof; decls.txt lists the 15 theorems)
cd $B/indep
$TC/bin/lean -o SwiftFormalProof.olean SwiftFormalProof.lean
LEAN_PATH=$PWD:$TC/lib/lean $TC/bin/leanexport SwiftFormalProof -- $(cat decls.txt) > fixed.ndjson
bash run.sh fixed.ndjson fixed nanoda.json   # runs all six checkers

# 5. The must-reject probes
python3 audit_probe.py    # BogusProof, SlotBogus
python3 spoof_probe.py    # Spoof, SlotSpoof, NoImportSpoof
```

Files measured, by the first 8 hex digits of their SHA-256:

| File | sha |
|---|---|
| 0.0.5 proof, my copy | `4ce51b6c`; fixed version `a012892a` |
| 0.0.6 original, and the current `sil-validation/.artifacts/proof.lean` | `e23f2c51` |
| 0.0.7 copies I measured: guard, early-return, joined, reused, wrong-guard-return | `15c48c90`, `a5b7c02b`, `1012a7f5`, `bb771d85`, `457c7c2f` |
| 0.0.7 today's regenerated files: guard, early-return, joined, reused, wrong-guard-return | `19ac9799`, `4224f49a`, `f00e574e`, `093cff8e`, `44ccb3bf` |
| Fixed 0.0.5 export, normal and kernel-off builds (identical) | `31713272` |

Folder contents:

- `bench/timing/`: the 0.0.5 before/after runs (3 each).
- `bench/v006/` and `bench/v007/`: before/after pairs.
- `bench/v007all/`: the fixed-only runs.
- `bench/kernoff/`: the kernel-off build.
- `bench/split/`: the library/per-function split and `bytes%`.
- `bench/enc/`: the encoding benchmark.
- `bench/indep/`: exports, checkers and probes.
