---
name: swiftformal
description: Use when writing or changing Swift functions in a project that uses SwiftFormal, to prove they cannot crash and keep their contracts (@Verify with #requires/#ensures, the only form Scan reads) and walks (Prove(it:over:), the one way to walk in a test). Runs `swiftformal check` on the changed function, reads the JSON verdict, and fixes the code, the contract or the walk until it is proved. Never reports bounded, unchecked, undecided, unsupported or stale results as proved.
---

# SwiftFormal: prove the Swift you write

SwiftFormal reads what the Swift compiler made of a function and proves, for every input, that it cannot crash
(trap) and that it keeps its contract. Where logic cannot decide, a walk (a test that runs the real function on every
input of a domain) can prove it instead. Your job: after each change, check the function, read the verdict, and act
on it. Every JSON field: [reference.md](reference.md).

## Before you start

1. Find the tool. Use `swiftformal` if it is on `PATH`; otherwise it is usually
   `<SwiftFormal checkout>/.build/release/swiftformal`. To build it, in the SwiftFormal checkout run
   `swift build -c release --product swiftformal`. It is the only command: SwiftFormal has three products,
   `SwiftFormal` (app code), `SwiftFormalTesting` (tests) and `swiftformal`. `swiftformal verify`, `scan` and `gen`,
   `sfverify`, `sfgen` and the `SwiftFormalGate` / `SwiftFormalScan` plugins were removed; `swiftformal doctor` names
   any your package still uses and what replaces it.
2. Run `swiftformal doctor --package <package-dir>`. Exit 0 means the setup is fine. Otherwise do what each `fix:` line
   says. If the compiler is not the pinned one, the verdicts are not covered by SwiftFormal's trust notes: tell the
   user.
3. Find the names you need: `<package-dir>` is the folder with `Package.swift`; `<Target>` is the folder under
   `Sources/` that holds your file; `<TestTarget>` is the test target with the walks (often `Tests/<Target>Tests`).
   Scan runs on macOS only.

## The loop

1. Edit the function.
2. Check only that function:

   ```sh
   swiftformal check --scan <package-dir>:<Target> --at <file>:<line> --json 2>/dev/null
   ```

   `<line>` is any line of the function: its body, declaration, attributes or doc comment. Or name it with
   `--symbol 'Type.member(label:)'` (the `function` value of an earlier report works). Add
   `--tests <package-dir>:<TestTarget>` to also run the walks linked to it.
3. Read `entries[0].outcome` (and `logic`) in the JSON, and act on it with the table below.
4. Repeat until the outcome counts as proved, or you can tell the user why it does not.
5. When done, check the whole target once (without `--at`/`--symbol`): your change can break a caller, and only the
   whole run shows that.

The JSON is on stdout; progress lines are on stderr. The first run builds the target (tens of seconds); later runs
reuse checked answers from the proof cache for code that did not change.

Exit codes: `0` no promise broken, `1` a promise is broken (or a linked walk did not report), `2` usage or build
error, including an `--at` line that no function covers or a `--symbol` that matches no function or several.
**Exit 0 is not "proved".** A function that may crash exits 0 unless you pass `--strict`, and so do `unchecked` and
`bounded`. Always read `outcome`.

## What each outcome means, and what to do

| `outcome` | Meaning | Proved? | Do this |
|---|---|---|---|
| `provedByLogic` | Logic proved the contract for every input. | yes | Done. |
| `provedByLogicAndWalk` | Logic proved it cannot crash, and every linked walk passed on its whole domain. | yes | Done. The walk part covers only the walk's domain (see "Add a walk"). |
| `provedByWalk` | Every linked walk that names it (`"Type.member"`, `"Type.=="`) passed on its whole domain; logic could not decide. A walk over a whole type proves no member. | yes, for the walk's domain only | Done, but say which inputs the domain covers. |
| `cannotTrap` | Logic proved it cannot crash, for every input. No other promise was checked. | cannot crash, nothing more | If the function has a rule (a range, a relation), add a contract or a walk. |
| `counterexample` | A real input breaks a promise or makes it crash. | no | Reproduce it as a test, then fix the code (below). |
| `bounded` | Walks passed, but on a sample, not the whole domain. | **no** | Use a complete domain, or report it as "tested on a sample". |
| `unchecked` | Neither logic nor a walk said anything. | **no** | Read `logic`, `category`, `detail`, `hint` (below); simplify, or add a walk. |
| `knownIssue` | A walk fails, and its test marks that as a known issue. | **no** | Fix it, or leave it and say so. |
| `conflict` | One walk that names it passed on its whole domain; another fails, marked as a known issue. | **no** | Fix the failing walk's case, or say both. |
| `typeWalkFailed` | Only a walk over its whole type failed: which member is at fault is not known. | **no** | Find the failing member from the walk's input; fails the run unless marked as a known issue. |
| `walkMissing` | A linked walk ran but wrote no result (filtered out, or never reached `Prove`). | **no** | Make the test reach its `Prove` call. |

`logic` is what Scan alone said: `safe`, `contractHolds`, `mayTrap`, `contractFails`, `undecided`, `unsupported` or
`internalError`. Only `safe` and `contractHolds` are proofs. `internalError` means the prover itself failed: not
proved, and worth reporting to SwiftFormal.

### A counterexample

`counterexample.inputs` (such as `"whole = 0"`), `failure` (such as `"traps: Division by zero"`) and, when Scan can
write one, `replay`: a call that reproduces it (`"percent(0, 0)"`). A walk's failing input is under
`walks[].records[].properties[]` with `"verdict": "failed"`, `input` and `detail`. `moreTraps` lists other ways the
function can crash.

1. Write a test with the replay input and the result you expect after the fix. It fails now.
2. Fix the code, not the contract. Run the test and the check again.

`swiftformal check --scan <package-dir>:<Target> --emit-tests <dir>` can also write one Swift
Testing test per counterexample of a free function over integers and `Bool`. Those tests pass while the bug is still
there and fail once it is fixed; delete them then.

### `unsupported` or `undecided` (outcome `unchecked`)

- `unsupported`: the function uses Swift that Scan does not read (`category` such as `generics`; `at` and
  `calledFrom` say where). Follow `hint` if it is a small, clear change (for example, call a non-generic version).
  Otherwise add a walk.
- `undecided` with `category` `budget`: no answer in time. Raise `--budget` (default 300000), use narrower integer
  types, or add a `#requires` that states a real rule. `unmodelled results`: the answer depends on what a call such
  as `String.count` returns; add a walk. Other categories (`exclusivity`, `loops`, …): follow `hint`, or add a walk.
- Do not twist clear code only to please Scan. A walk is a fine answer.

## Add a contract

Write it in place, with `@Verify`, `#requires` and `#ensures`, and `import SwiftFormal` (product `SwiftFormal`). This is the one form to write. `#requires` says which inputs callers may pass;
`#ensures` what the result must satisfy (`$0` or `result in` is the result). Scan proves it for every input:

```swift
@Verify(over: .product(.int(0...1_000), .int(-5...105)))
public func discounted(price: Int, percent: Int) -> Int {
    #requires(price >= 0 && price <= 1_000_000 && percent >= 0 && percent <= 100)
    #ensures { $0 >= 0 && $0 <= price }
    return price - price * percent / 100
}
```

`over:` also gives a walk, `verify_discounted()`, for a test. Leave `over:` out when the parameters are `String`, `Int`
and the like: then there is no walk and Scan alone proves it. With only `#requires(percent >= 0 && percent <= 100)`,
the walk passes, but `check` says `counterexample` with `price = -9223372036854775808`: logic checks every input, not
only the walk's. A negative price is not a real price, so stating that rule in `#requires` is the honest fix here.

A computed property takes its contract in the getter, the same way (most app contracts are of this kind):

```swift
struct Rule {
    var title: String

    @Verify
    var body: String {
        #requires(!title.isEmpty)
        #ensures { result in result.hasPrefix(title) }
        title + "."
    }
}
```

A property with a setter takes `@Verify` on its `get`; Scan then sees only the checks in the getter (a warning says
so). Never write separate `f_requires` / `f_ensures` / `body_ensures(_:)` functions, `*Contracts.swift` files or
`// sf:verify` comments: Scan does not read them (the report lists a hand-written contract under `ignoredContracts`,
and `swiftformal check --gate` fails on it and on each `// sf:verify`). When you find one, move its conditions
into the function as `#requires(…)` / `#ensures { … }` under `@Verify`. `@Verify` alone asks for a proof that the
function cannot trap.

An app file that imports SwiftUI next to SwiftFormal is fine: SwiftFormal has no top-level name that SwiftUI also
has (the walk property for a golden table is `Matches(table:)`).

## Add a walk

In the test target (products `SwiftFormal` and `SwiftFormalTesting`), from SwiftFormal's `Examples/Walk`. `Prove` is
the only way to walk: every form is `Prove(it: …, over: …) { properties }`. The older names (`expectProved`,
`expectNoTrap`, `verify`, `verifyContracts`, `partition`, `lockBehavior`, `walkInExitTest`, `prove`, `Table`, `Image`)
do not compile; never write them, and replace them where you find them (the compiler's error says with what). The walk
covers the function its `it:` closure calls, here `label(for:)`:

```swift
@Test func everySpeedHasItsLabel() {
    Prove(it: { label(for: $0) }, over: .allCases) {
        Deterministic()
        Matches(table: [
            .standard: "Standard (3-5 days)",
            .express: "Express (1-2 days)",
            .overnight: "Overnight",
        ])
        Satisfies("never blank") { _, text in !text.isEmpty }
    }
}
```

A walk proves only the inputs its domain lists. `.allCases` of an enum is every value; `.int(0...100)` is 0 to 100,
not every `Int`. Choose a domain that holds every value the function can really get, and say which inputs it covers.
If the closure calls nothing `check` can link, name the function: `Prove("Surface.label", it: …)`. Name the member, never
only the type: a walk whose subject is `"Store"` proves none of `Store`'s members.

Write walks in the app's own test style: one call in a plain `@Test`, no harness types (step enums, session structs,
outcome structs, run functions). For a reducer or a model, walk every session of actions with the real step as `it:`
(`$0` is the state, `$1` the action):

```swift
Prove(it: { TabsReducer().reduce(into: &$0, action: $1) },
      over: .sessions(from: TabsStore.State(), actions: tabActions, upTo: 4)) {
    Always("the selected tab is on screen") { $0.tabs.indices.contains($0.selectedTabIndex) }
    EachStep("retry changes nothing") { before, action, after in action != .retry || before == after }
}
```

`tabActions` is a `Domain` of the app's own action enum: `Domain<Action>.union(Domain.int(0...2).map(Action.tabSelected),
.of([.retry]))`. For a function that may crash (an index, `Int(someDouble)`), use the trap check: declare an
`internal` (not `private`) type at file scope, `enum SelectedTab: ExitTestWalk { static let inputs: Domain<Int> = …;
static func call(_ i: Int) -> Tab { TabsState(selectedTabIndex: i).selectedTab } }`, and write
`await Prove(neverTraps: SelectedTab.self)`; `check` links it from the first call in `call`.
For an audit (every key in every language), pass `reporting: .everyFailure` to list every failing input. A known
defect the user wants kept is `knownIssue: "why"` (or `KnownFailure("why", inputs: [...])`), not `withKnownIssue`.

## The build gate

`swiftformal check --gate --package <package-dir>` proves every `@Verify` promise in the package and prints Xcode-style
`file:line:col: error|warning:` lines. An error is a broken promise or a crash, with the input, or a contract that is
not read (a hand-written `f_requires` / `f_ensures`, a `// sf:verify` comment). A warning is a promise logic could not
read, which only a test can check now. Exit `1` on any error. Teams run it in an Xcode Run Script phase and on CI; run it
before you say you are done. For code in an app target (no `Package.swift`), give it the log of the app's build:
`swiftformal check --gate --build-log <log> --target <AppTarget>`; `swiftformal check --build-log <log> --target
<AppTarget>` checks every function of it.

## Rules

- **Only these mean proved:** `provedByLogic`, `provedByLogicAndWalk`, `provedByWalk` (for the walk's domain), and
  `cannotTrap` for "cannot crash". `bounded`, `unchecked`, `undecided`, `unsupported`, `mayTrap`, `knownIssue`,
  `conflict`, `typeWalkFailed`, `walkMissing` and, in the editor, `⚠ stale` and `? unchecked` never mean proved. Do not call them "verified" or
  "proved".
- **Say what a proof holds under.** `modules[].configurations` (`debug`, `release`), `modules[].pinned` (false: the
  compiler is not the validated one), `proofScope: "partialCorrectness"` (a function with loops: proved for every run
  that ends, not that it ends), and a walk's `domainComplete` and domain.
- **Never weaken a promise to make it pass.** Do not delete or loosen an `#ensures`, add a `#requires` only to shut
  out the counterexample, shrink a walk's domain, add `allowBounded: true`, wrap a failure in `withKnownIssue` or pass `knownIssue:`,
  or delete a walk. A `#requires` must state a real rule that callers keep. If you think the contract itself is wrong,
  ask the user.
- Do not edit or delete the proof cache (`<package-dir>/.build/swiftformal/proofs`). `--no-proof-cache` proves
  everything again if you doubt it.
- When you report back, give each changed function's `outcome` and, if it is not proved, why.
