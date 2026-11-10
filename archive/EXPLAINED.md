# Formal verification for Swift, explained from zero

A plain-English walkthrough of the research and the prototype. Read it top to bottom; each part builds on the one before.

---

## Part 1. The problem

AI now writes a lot of code, and it writes it fast. That creates a new problem: **who checks it?**

- Reading every line yourself is slow, and you get tired and miss things.
- Tests help, but tests only check the examples someone thought of.
- AI is also getting good at *finding* bugs in other people's code to attack it. So bugs are becoming more dangerous, not less.

So we want a way to check code that:
1. covers **every** possible input, not just examples, and
2. doesn't depend on a human reading thousands of lines.

That is what formal verification gives you.

---

## Part 2. Tests vs. proofs

Take a tiny function:

```swift
func applyDiscount(subtotal: Int, discount: Int) -> Int {
    subtotal - discount
}
```

**A test** says: "for subtotal 100 and discount 20, the answer is 80." That checks one case. You can write 50 tests or run a million random ones. But there are infinitely many inputs, so you never check them all. The bug can sit in the case you never tried (here: discount bigger than subtotal gives a negative price).

**A proof** says: "for **every** subtotal and **every** discount, the result is never more than the subtotal and never below zero." It's a math argument, like in school geometry. Once it's proven, there's no input left that could break it.

Simple picture:
- Testing = checking some houses on a street for a gas leak.
- Proving = showing the gas pipe isn't connected to that street at all.

---

## Part 3. The four pieces of any verification

Every formal verification setup has four parts. Keep these four in your head; everything else is details.

| Piece | What it is | Who writes it |
|---|---|---|
| **1. Spec** (specification) | The rules the code must follow. "Price is never negative." "You can't capture a payment before it's authorized." | A human (AI can draft it, a human must approve it) |
| **2. Code** | The actual program. | Anyone: human or AI |
| **3. Proof** | A step-by-step argument that the code follows the spec. | Today: mostly AI |
| **4. Checker** | A small, strict program that reads the proof and says "valid" or "invalid". | Already exists (Lean, Rocq, etc.) |

**The key idea:** you don't need to trust the code or the proof. You only need to trust:
- the **spec** (is it saying the right thing?), and
- the **checker** (is it a correct checker?).

The checker is small and has been checked by many experts for years. The spec is short, maybe 20 to 100 lines. So a human only has to carefully read a short spec, not 10,000 lines of AI code.

That's why AI and proofs fit together so well:
- AI is fast but sometimes makes things up.
- The checker is slow-witted but never fooled by a made-up proof. If the AI writes a wrong proof, the checker rejects it and the AI tries again.

---

## Part 4. Why this was rare before

Proofs used to be very expensive:
- The seL4 operating system kernel took **2 person-years to write** and **20 person-years to prove**.
- Only a few hundred people in the world could write proofs like that.

So it was only used for things like airplane software, chips and crypto. Normal app teams never touched it.

**What changed:** AI can now write the proofs. The expensive part (proof writing) is becoming cheap. The cheap part (checking) was always cheap.

---

## Part 5. What Anthropic did (the first link)

Anthropic, together with a company called Theorem, ran a big experiment. Step by step:

1. **They took existing fuzz tests.** Many open-source libraries (on Google's OSS-Fuzz) already have "fuzz tests": a function that feeds random data into the library and crashes if something goes wrong.
2. **They turned each fuzz test into a spec.** Instead of "try lots of random inputs", the spec says: "**for every input up to 64 MB**, this program never crashes."
3. **They compiled the library to machine code** (RISC-V, a type of processor instruction set) and used a mathematical description of how that processor and Linux behave.
4. **Claude wrote the proofs** in a proof language called **Rocq** (formerly Coq).
5. **The Rocq checker checked them.**

Results:
- 239 entry points in 123 libraries proven "never crashes" (under the stated conditions).
- About 180 million lines of proof. Nobody needs to read them, because the checker did.
- While trying to prove things, Claude **found real bugs**, some that years of fuzzing missed (for example, one that only happens with a ~20 MB input of a very specific shape). It fixed them and then finished the proofs.
- Newer models need fewer tokens (Opus 5.5 used about 40% fewer than Opus 5). Sharing proofs between agents saved another 17%, because many programs have similar parts.

What they were honest about:
- **"Proven" doesn't mean "no bugs at all."** It means "no bugs *of the kind the spec talks about*, *under the assumptions*." Their assumptions: one thread, RISC-V, a specific setup. Real apps run on other chips and setups.
- If the spec is wrong or too weak, the proof proves the wrong thing.

**Lesson for us:** the approach works at scale. The weak point is always the spec and the assumptions, never the proof itself.

Note: Anthropic used **Rocq**, not Lean. Same idea, different tool.

---

## Part 6. What Lean is (the second link)

**Lean** is two things in one:
1. **A programming language.** You can write normal functions in it and run them. It's fast (it compiles to C).
2. **A proof checker.** You can write statements about those functions ("theorems") and proofs of them. Lean checks the proofs.

Because both live in the same language, the thing you prove things about is the exact same function you can run.

### A tiny Lean example (from our prototype), line by line

```lean
def applyDiscount (subtotal : Nat) (discount : Nat) : Nat :=
  if discount ≤ subtotal then subtotal - discount else 0
```
- `def` = define a function.
- `Nat` = natural number: 0, 1, 2, 3, ... (never negative).
- It says: if the discount fits, subtract it; otherwise return 0.

```lean
theorem discount_never_exceeds_subtotal (s : Nat) (d : Nat) :
    applyDiscount s d ≤ s := by grind [applyDiscount]
```
- `theorem` = a claim we want to prove.
- `(s : Nat) (d : Nat)` = "for **any** numbers s and d".
- `applyDiscount s d ≤ s` = the claim: the discounted price is never more than the original.
- `:= by grind [...]` = the proof. `grind` is an automatic tool in Lean that tries many standard reasoning steps by itself. The `[applyDiscount]` part tells it "you may look inside this function's definition."

If the claim is true, Lean says nothing (silence = accepted). If it's false or the proof is wrong, Lean prints an error.

### A proof done by hand, line by line

Some claims are too hard for the automatic tools. Our tax rule was one:

```lean
def taxCents (amount : Nat) (basisPoints : Nat) : Nat :=
  (amount * basisPoints) / 10000
```
(basisPoints: 10000 = 100%, 2500 = 25%.)

Claim: "if the tax rate is at most 100%, the tax is never more than the amount."

```lean
theorem tax_never_exceeds_amount (a : Nat) (bps : Nat) :
    (bps ≤ 10000) → (taxCents a bps ≤ a) := by
  intro h                          -- 1
  unfold taxCents                  -- 2
  apply Nat.div_le_of_le_mul       -- 3
  rw [Nat.mul_comm 10000 a]        -- 4
  exact Nat.mul_le_mul_left a h    -- 5
```
1. "Assume the rate is at most 100%. Call that fact `h`."
2. "Replace `taxCents` with its formula." Now we must show `(a * bps) / 10000 ≤ a`.
3. "Use a known fact: if `x ≤ 10000 * a`, then `x / 10000 ≤ a`." Now we must show `a * bps ≤ 10000 * a`.
4. "Swap `10000 * a` to `a * 10000`." Now: `a * bps ≤ a * 10000`.
5. "Since `bps ≤ 10000` (fact `h`), multiplying both sides by `a` keeps it true." Done.

This is exactly the kind of thing AI agents write: small steps, each using a known fact. Lean checks each step.

### Other Lean words you'll see

- **Kernel**: the small core of Lean that does the final checking. This is the part you trust.
- **Tactic**: a proof step command (`intro`, `unfold`, `grind`, `omega`, `simp`).
- **`grind`, `omega`**: automatic tactics. `omega` handles plain arithmetic with + and − and comparisons. `grind` does more.
- **`sorry`**: a placeholder meaning "proof not written yet." It's how you mark a hole for the AI to fill. Lean warns about it; a finished project has none.
- **Lake**: Lean's build tool (like Swift Package Manager).
- **elan**: Lean's installer (like rustup). I installed it in `~/.elan`.

---

## Part 7. What Mathlib is (the third link)

**Mathlib** is a huge shared library of already-proven math facts for Lean: about 2 million lines, ~291,000 theorems, ~770 contributors.

Why it matters:
- **Reuse.** If someone already proved "multiplying both sides of an inequality by a positive number keeps it true," you just use it. You don't prove it again. Proofs build on proofs, like code builds on libraries.
- **AI training.** Almost every AI math prover learned from Mathlib. It's the biggest collection of correct, checked proofs anywhere.

**Do you need Mathlib for app code?** Mostly **no**. Prices, counters, state machines and parsers only need basic numbers, lists and true/false, which come with Lean itself. Mathlib is a multi-GB download and slow to build. Use it only if you need real math (probability, real numbers, etc.).

**The lesson to take from Mathlib** is the pattern: a shared library of proven facts makes each new proof cheaper. The same would work for app logic: a shared library of proven "money facts" or "state machine facts".

---

## Part 8. Why AI makes this both possible and necessary

**Possible:** proof writing was the expensive step. AI is now decent at it, and getting better fast. AI is also allowed to be wrong, because the checker catches it.

**Necessary:** when AI writes most code, humans can't read it all. You need a check that doesn't depend on a human reading every line.

**The catch: AI is good at code, OK at specs, weakest at proofs.** Benchmarks show the same order every time:
- writing code that runs: easy for AI,
- writing a correct spec: harder,
- writing a correct proof: hardest.

One benchmark ("vericoding") measured how often AI finishes a fully verified program:
- Dafny: 82%
- Verus (Rust): 44%
- Lean: 27%

Lean is hardest because its proofs are more manual. Dafny and Verus lean more on automatic solvers. That's why our generated Lean should stay simple: plain numbers, no Mathlib, automatic tactics where possible.

**The biggest danger: "spec gaming."** An AI asked to "make it verify" can cheat by writing a spec that says almost nothing. Example: "the price is a number." That's always true, so it's easy to prove, and useless. Benchmarks show AI really does this. That's why **the human must review the spec**, and why we add automatic checks against empty specs (Part 13).

---

## Part 9. Where Swift stands

**Swift has no proof tools today.** I (and the research agents) found nothing like Rust's tools. Apple does use formal methods, but on its C crypto code and on the iMessage protocol, not on Swift itself.

**But Swift already has useful pieces**, even if they're not proofs:
- **Types and enums.** If a state can't be written down, it can't happen. An `enum PaymentState { case created, authorized, captured }` already removes many wrong states.
- **Swift 6 concurrency checks.** The compiler stops data races. That's a guarantee from the compiler, just not a mathematical proof.
- **Ownership (`~Copyable`, `consuming`).** You can make a value that can only be used once, like a payment token that can't be charged twice.
- **Result builders.** The same feature SwiftUI uses for `VStack { ... }`. We use it to write specs in Swift.
- **Macros.** Could give us `@Requires` / `@Ensures` annotations later.
- **SwiftPM plugins.** Can run Lean during `swift build` and show errors in Xcode.
- **C interop.** Swift can call C, and Lean compiles to C, so they can talk.

---

## Part 10. How other languages did it: four styles

Other languages solved this in four different ways. Knowing these helps you see why I chose one.

**Style A: Write the rules inside the code (Verus for Rust, Dafny).**
```
fn applyDiscount(s, d) requires d <= s, ensures result + d == s { ... }
```
The compiler sends the rules to an automatic solver (Z3). Nice to use, but needs a big tool that understands the whole language. For Swift, nobody has built it. Years of work.

**Style B: Translate the real code into the proof language (Aeneas: Rust → Lean).**
A tool reads your real code and writes an equivalent Lean version. Then you prove things about that. Microsoft uses this for its crypto library. Strongest, but needs a translator for the whole language. For Swift, research-level work.

**Style C: Write the logic in the proof language and compile it (Lean → C → your app).**
The code you ship is the exact code you proved. Strong, but you'd ship Lean's runtime inside an iOS app. Nobody has shown this working on iOS yet.

**Style D: Keep a small model, prove it, and test the real code against it (AWS Cedar).**
1. Write a small, simple version of the logic (the "model") in Lean.
2. Prove the important rules about the model.
3. Run the model and the real code side by side on millions of random inputs. If they ever give different answers, one of them is wrong.

AWS does this for Cedar (their permissions language). The Lean model is about 10 times smaller than the real Rust code. No release ships unless the proofs pass and the side-by-side test passes.

**Why I picked Style D for Swift:** it needs no changes to Swift, no translator, no Lean inside the app. Lean only runs on your Mac or in CI. It's the cheapest path, and it's proven at AWS.

---

## Part 11. My design, step by step

### The core idea: one spec, two uses

You write the spec **once**, in Swift. From it, the tool makes two things:

```
                 Spec (written in Swift)
                    /              \
                   v                v
        Lean file                 Same rules, runnable in Swift
        (proofs checked)          (used as the "correct answer")
                   |                |
                   v                v
        "The rules are         "Your real Swift code gives
         sound"                 the same answers as the rules"
```

### Why you need both halves (this is the most important idea)

- **The proof** shows: *the spec model behaves well* (e.g. the discounted price is never above the subtotal, for every input).
- **The side-by-side test** shows: *your real code behaves like the model.*

Put together: real code ≈ model, and model is proven good, so real code is very likely good.

Neither half is enough alone:
- Proof only: you proved the model is good, but your real code might do something else.
- Test only: you know the code matches the model, but the model itself might be wrong in some case you never tried.

Honest note: the side-by-side test is still testing (random inputs), so the link between model and code is "very strong evidence," not a proof. The proof part covers every input; the test part covers many inputs. That's the trade-off for not needing a Swift-to-Lean translator.

---

## Part 12. The prototype, piece by piece

Folder: `SwiftFormal/prototype/`. About 350 lines of Swift.

### Step 1. The spec language (`AST.swift`)

"AST" means "abstract syntax tree": a data structure that describes an expression, instead of running it.

When you write `p[0] - p[1]`, normally Swift would subtract. In our spec, the `-` operator is redefined to **build a description**: `.sub(.variable("subtotal"), .variable("discount"))`. It's like writing down a recipe instead of cooking.

Why? Because a description can be turned into **two** things: Lean text, and a runnable Swift version. A cooked result can't.

The language is deliberately small: whole numbers, true/false, `+ - * /`, `min`, comparisons, and/or/not, "if … then …" (`==>`), if/else, and calling other spec functions. Small means easy to translate correctly and easy for AI to prove.

### Step 2. Writing specs nicely (`SpecModule.swift`)

A result builder (same trick as SwiftUI's `VStack { }`) lets you write:

```swift
let checkout = SpecModule("Checkout") {
    Function("applyDiscount", ("subtotal", .nat), ("discount", .nat)) { p in
        ifThen(p[1] <= p[0], p[0] - p[1], else: 0)
    }
    Theorem("discount_never_exceeds_subtotal", ("s", .nat), ("d", .nat)) { v in
        call("applyDiscount", v[0], v[1]) <= v[0]
    }
}
```
- `Function` = a piece of logic (the model).
- `Theorem` = a rule that must always hold.
- `p[0]`, `p[1]` = the parameters, in order.
- By default each theorem's proof is `by grind`. If automation isn't enough, you (or the AI) pass a hand-written proof, like the tax one.

### Step 3. Turning it into Lean (`LeanEmitter.swift`)

This walks the description and prints Lean text. Two small details worth knowing:

- **Lean has two kinds of true/false.** One is for *claims you prove* (written with `∧`, `→`, `=`). The other is for *values code computes* (written with `&&`, `==`). Inside functions we print the second kind; inside theorems the first. The emitter picks the right one.
- **`grind` doesn't look inside your functions on its own.** So the emitter adds the function names: `by grind [applyDiscount, capQuantity, taxCents]`.

Output: `lean/Checkout.lean`.

### Step 4. Running the spec in Swift (`Interpreter.swift`)

This reads the same description and actually computes answers. The important part: **it copies Lean's math rules exactly**, otherwise the two halves would disagree:
- In Lean, `Nat` can't go below zero: `3 - 5 = 0`.
- In Lean, dividing by zero gives 0.
- Lean numbers have no upper limit. Swift's `UInt64` does. So if a number overflows, the interpreter **stops with an error** rather than quietly wrapping around and giving a wrong "correct answer".

### Step 5. The side-by-side test (`differentialTest`)

"Differential testing" = run two versions on the same input and compare.

1. Pick random inputs (up to 10,000 sets).
2. Every 4th time, use edge values like 0 and 1 instead, because bugs love edges.
3. Ask the interpreter (the spec) for the answer.
4. Ask the real Swift function for the answer.
5. If they differ, stop and report the inputs.

### Step 6. Asking Lean to check (`main.swift`)

The demo runs the `lean` program on the generated file. Exit code 0 means every theorem was accepted.

### What actually happened when I ran it

```
✗ applyDiscount (naive) disagrees with spec: inputs=[0, 1] spec=0 production=18446744073709551615
✓ applyDiscount (fixed) agrees with spec on 10,000 random inputs
✓ Lean kernel accepted all theorems
```

Line 1, explained:
- The "naive" version is `subtotal - discount`, the kind of code an AI might write.
- With subtotal 0 and discount 1, it returns **−1**: a negative price.
- My comparison code turns any negative number into the biggest possible `UInt64` (18446744073709551615) so it can never accidentally match. That giant number just means "this was negative."
- The spec says 0. They differ, so the bug is caught.

Line 2: the fixed version (`discount <= subtotal ? subtotal - discount : 0`) matched on all 10,000 tries.

Line 3: Lean accepted all four theorems:
1. Discount never makes the price higher than the subtotal.
2. If the discount fits, price + discount = subtotal exactly.
3. You never sell more than stock, or more than the per-order limit.
4. Tax at ≤100% is never more than the amount (the hand-written proof).

### How I checked the checker isn't just saying yes to everything

I changed one theorem from "≤" (at most) to "<" (strictly less). That's false: with a discount of 0, the price equals the subtotal, it isn't less. Lean **rejected** it with an error. Good: the checker really checks.

### What this shows

- The bug was a **mismatch between the model and real Swift**: the model's numbers stop at 0, Swift's `Int` goes negative. Anthropic said the same: bugs hide where the model and reality differ. The side-by-side test exists to catch exactly that.
- `grind` proved 3 of 4 theorems alone. The 4th needed 5 hand-written steps. **That gap is the job of the AI agent.**
- No Mathlib needed. Lean checks the file in seconds.

### What the prototype can't do yet

Only whole non-negative numbers and true/false. No negative numbers, no structs, no enums or state machines, no lists, no Xcode plugin, no AI loop, no `@Requires` macros. Those are the next steps (Part 15).

---

## Part 13. Who does what, and how to stop AI cheating

### Roles

1. **Human:** writes or approves the spec. Short, readable, reviewed line by line.
2. **AI:** writes the Swift code.
3. **AI:** writes the Lean proofs, using tools that let it see Lean's errors (for example `lean-lsp-mcp`, which connects Lean to Claude Code or Copilot).
4. **Machines check:** Lean checks proofs; the side-by-side test checks code vs. spec; normal tests run too.
5. **If something fails:** AI tries to fix it. If it can't, a human looks: is the code wrong, or is the spec wrong?

### Anti-cheating checks (to add)

- **No `sorry` and no new axioms.** An "axiom" is a fact you just declare true without proof. An AI could add `axiom everything_is_fine` and "prove" anything. Lean's `#print axioms` lists what each proof relies on; CI should reject anything unexpected.
- **AI may change proofs, not theorem statements.** If the AI could edit the claim, it could weaken it to something trivial. Lock the claims (e.g. store a hash) so changes need human review.
- **Make sure "if" conditions can actually happen.** A claim like "if 1 = 2, then the price is negative" is technically true and means nothing. For every "if A then B", show one example where A is true.
- **Break the spec on purpose.** Change `≤` to `<`, or add +1 somewhere. Some theorem should now fail (like my test above). If nothing fails, the theorems are too weak to notice anything.

---

## Part 14. What's worth verifying in an iOS app

Good candidates have three things in common: **small, pure (no UI, no network), and costly if wrong.**

- **Money:** prices, discounts, tax, rounding, splitting a bill, currency conversion.
- **State machines:** login with 2FA, payments, subscriptions, onboarding, permission and feature-flag rules. ("Can you reach 'captured' without 'authorized'?")
- **Offline sync / merging edits:** the merge logic that decides what wins when two devices edit the same thing.
- **Parsers:** deep links, QR codes, file formats. A classic rule: `decode(encode(x)) == x`.
- **Dates, times and units:** conversions and rounding, written as pure functions.

**Not worth it:** layout, animations, view glue code. There's no precise rule to prove ("looks right" isn't a spec). Snapshot and UI tests are the right tools there.

---

## Part 15. Risks and the plan

### Main risks

- **Wrong spec:** proof is valid but proves the wrong thing. Fix: human review + the anti-cheating checks.
- **Model ≠ Swift:** like the `Nat` vs `Int` difference. Fix: side-by-side tests on every build, and later model Swift's real number types in Lean (Lean has fixed-size numbers too).
- **Lean is hard for AI** (27%). Fix: keep the Lean simple; use automatic solvers (Z3) for simple arithmetic rules.
- **Shipping Lean inside an iOS app** is unproven, and one library it uses by default (GMP) has a license that's a problem for the App Store. Fix: keep Lean on your Mac and CI only, unless a test project proves otherwise.
- **Lean changes fast.** Fix: pin the Lean version per project.

### Next steps (simplified)

1. Add negative numbers, fixed-size numbers, structs, enums, lists, and a `StateMachine` builder.
2. `swift package verify` command: runs Lean and shows errors in Xcode.
3. `@Requires` / `@Ensures` macros that add runtime checks and property tests.
4. AI loop: an agent fills in missing proofs, with the anti-cheating checks.
5. Z3 as a fast automatic first pass for simple rules.
6. A one-week test: can Lean-compiled code run inside an iOS app at all?
7. Long term, research: translate a simple subset of real Swift into Lean automatically.

---

## The whole thing in one picture

```
You (human)          AI                       Machines
───────────          ──                       ────────
Write/approve  ───►  Write Swift code   ───►  Side-by-side test:
the short SPEC                                 does code match spec?
     │
     └──────────►    Write Lean proofs  ───►  Lean checker:
                                               is the spec's logic sound?

You only trust: the spec (you read it) + the Lean checker (small, battle-tested).
You don't need to trust: the AI, its code, or its proofs.
```

## The mental model in five sentences

1. Tests check examples; proofs check every input.
2. A proof is only as good as its spec, so humans review the spec, not the code.
3. AI writes the code and proofs; a small checker (Lean) decides if the proofs are valid, so AI mistakes get caught.
4. For Swift, the cheapest working setup is AWS's: a small spec that is proven in Lean *and* run as the "correct answer" to test the real Swift code.
5. Bugs that remain live where the spec or the model differs from reality, so that's where you keep looking.

---

## Glossary

- **Formal verification:** proving with math that code follows rules, for all inputs.
- **Spec:** the written rules the code must follow.
- **Theorem:** one rule stated precisely, to be proven.
- **Proof:** the step-by-step argument that a theorem is true.
- **Checker / kernel:** the small program that verifies proofs. The thing you trust.
- **Lean:** a programming language + proof checker.
- **Rocq (Coq):** another proof checker (used by Anthropic).
- **Mathlib:** Lean's big library of proven math.
- **Tactic:** one proof step command in Lean (`intro`, `grind`, ...).
- **`grind` / `omega`:** automatic proof tactics.
- **`sorry`:** "proof missing" placeholder.
- **Axiom:** a fact accepted without proof. Dangerous if an AI adds its own.
- **Nat:** whole numbers 0, 1, 2, … (no negatives; `3 - 5 = 0`).
- **Fuzzing:** throwing lots of random inputs at a program to make it crash.
- **Differential testing:** running two versions on the same inputs and comparing answers.
- **Model:** a small, simple version of the logic, used as the "correct answer."
- **AST:** a data structure that describes code instead of running it.
- **Result builder:** the Swift feature behind SwiftUI's `{ }` blocks; we use it to write specs.
- **SMT solver (Z3):** an automatic tool that solves logic and arithmetic questions, no hand-written proof needed, but only for simpler kinds of rules.
- **Spec gaming:** AI writing a weak or empty spec so it's easy to "prove."
