# Generate: a check for every Rule, with no hand-written test

**Maintainer-only.** `sfgen` is an internal tool, not a product: `swiftformal` has no command for it. It is built
from a checkout with `swift build --product sfgen`. In your own tests, write `Prove(it:over:)` walks instead
([Walk guide](walk.md)).

`sfgen` writes a walk for every `Rule` (the mapper protocol of the app it was built for). It reads the symbol
graph of the Kotlin framework and the app's Swift sources, so nobody lists inputs by hand. It is a build-time tool for
macOS. It never runs your Rules; it writes a Swift Testing file that does.

## The three commands

```
# 1. Ask the compiler what the framework's types look like (about 4 s for a 1,972-type framework).
sfgen symbols --module SharedKt --framework-dir <dir that holds SharedKt.framework> --out /tmp/sg

# 2. Write the test file (about 5 s for 468 Rules in 1,366 files).
sfgen generate --sources <dirs...> --symbols /tmp/sg --app-module MyApp \
  --import SharedKt AppMapping AppCore ... --testable-import MyApp \
  --out Tests/MyAppTests/Rules/SwiftFormalGenerated.swift --manifest manifest.tsv \
  [--exclude exclude.tsv] [--only A,B] [--max-inputs 500]

# 3. If the compiler rejects some generated Rules, drop exactly those and generate again.
sfgen prune --generated <file> --log <xcodebuild.log> --exclude exclude.tsv
```

`--max-inputs` (default 500) is the most inputs one Rule is run on: the walk's budget.

## What each generated check asserts

For one Rule, over a domain built from its input type, one `Prove(name, it: …, over: domain) { Deterministic() }`:

1. **Total.** The Rule returns for every input. A crash ends the test process.
2. **Deterministic.** Two runs on the same input give the same output (UUIDs and addresses are masked).

It does not know the right answer. A complete domain gives `proved` (every input checked). Any other domain gives
`bounded`: a sample, never a proof. The file uses only the public API, so it compiles in the app's test target
(`GeneratedTestsSlowTests` builds one in a package that depends on SwiftFormal as an app does).

Pre-release builds also wrote a behaviour lock (`__SFLocks__`); `sfgen` no longer writes or reads one, so delete old
`__SFLocks__` folders. The measurements below were taken with the lock.

## Pitfalls

- **A Kotlin exception ends the process.** `LocalDate(year:month:day:)` throws on `month = -1`, and Kotlin/Native
  turns that into an abort, not a Swift error. The domain builder gives dates only valid values. Any Kotlin type with
  a validating initializer needs the same care.
- **A crash looks like a hang.** When a Rule or a domain crashes the test host, Swift Testing restarts it and the run
  looks hung.
- **Large domains.** `Domain.combinations` stops at 4,096 rows. When the pair table would be too large (eight fields
  of a few hundred values each took minutes), it uses a deterministic spread in which every value of every field still
  appears.
- **Too many inputs.** Each Kotlin call crosses a bridge: at 20,000 inputs, one Rule took 30 s. The default is 500.
- **UUIDs in the output** failed the determinism check. The generated file masks them (and object addresses).

## Domains for a binary framework

`sfgen domains` writes [walk domains](walk.md#types-from-binary-frameworks) for the types of a framework you only
have as a binary, so `Prove(it: f, over: .reward)` needs no hand-listed values:

```
sfgen symbols --module <Module> --framework-dir <dir> --access-level internal --out <dir>/sg
sfgen domains --symbols <dir>/sg --import <Module> --out Tests/AppTests/GeneratedDomains.swift \
  [--manifest domains.tsv] [--exclude exclude.tsv]
```

- **Source of truth: the symbol graph.** `swift symbolgraph-extract` reads the binary `.swiftmodule` and the
  Objective-C headers and API notes through the clang importer, so it sees Objective-C classes, their initializers
  and the Swift names, with no knowledge of Kotlin. SKIE's sealed enums (`__Sealed`) are internal, hence
  `--access-level internal`; the generator uses only public declarations. The same works for any closed-source
  framework.
- **What it writes**, one `extension Domain where Value == T { static var t: Self }` per type, sorted by name:
  - a `CaseIterable` enum (SKIE's Kotlin enums are): its `allCases`, complete only if, when the walk runs, it
    lists as many distinct values as the graph declares cases, and a `switch` over the cases that stops compiling
    when one is added or removed. A hand-written `allCases` that leaves a case out gives a sample; an enum with a
    case that carries values or is unavailable, or one imported from C, is bounded;
  - a sealed hierarchy (an `onEnum(of:)` switch over a class): the union of one domain per subclass, plus a
    `switch` over the sealed enum that stops compiling when a case is added or removed;
  - a Kotlin `object`: its `shared` singleton;
  - a class with a public initializer: the initializer over the product of its fields' domains. Finite fields
    (`Bool`, enums, other generated types) are complete; `Int`, `Double`, `String` and arrays use boundary
    samples, and the domain is then `bounded`. So is a class whose state can change after it is built: a
    settable property or a method, its own or one it inherits from any superclass (the sealed base included), or
    a superclass the graph does not describe.
- **Honest verdicts.** A sampled field makes the domain incomplete, so a walk over it says `bounded`. Each domain's
  doc comment says `exhaustive` or `bounded (why)`, and the manifest lists every type with its status and, for a
  skipped one, the reason (no public initializer, generic, open class, recursive, a protocol without `onEnum`).
  [Known issue 18](../KNOWN-ISSUES.md#18-generated-domains-for-binary-frameworks-by-design) lists what an
  exhaustive domain assumes.
- Output is deterministic and type-checks. On a real Kotlin Multiplatform framework it covered 1,242 of 2,116
  candidate types in 0.6 s (487 exhaustive, 755 bounded) and skipped 874, each with a reason; the file type-checks
  with no diagnostic, and walks over it run on the iOS simulator.

## Limits

- `bounded` is not a proof. Most Rules in a large app have inputs too big to enumerate.
- The check finds crashes and non-determinism, not a wrong answer: write a `Prove` with `Matches(table:)` or
  `Satisfies` for that.
- Debug builds of the Kotlin bridge are slow: about 10 minutes for 392 Rules. Run the file as its own suite, not in
  every test run.
- Types that need a hand-built value (generics, closures, tuples, dictionaries, private types) are skipped with a
  reason, not guessed.

## Measured: a real iOS app (one app, one machine, debug build)

| Step | Result |
|---|---|
| Rules found | 468 |
| Rules generated / skipped | 392 / 74 |
| Test build | 0 compile errors after pruning 5 Rules; first build 5 min 11 s, rebuild after a regeneration about 40 s |
| Test run (iOS simulator, debug, 500 inputs at most per Rule) | 392 passed in 575 s |
| Verdicts | 67 `proved` (complete domain), 325 `bounded`, 0 counterexamples |

Why the 74 were skipped (from the manifest, which names each reason):

| Reason | Rules |
|---|---|
| private Rule | 15 |
| Kotlin protocol with no constructible conformer (mostly `ExpandedRecord`) | 19 |
| closure input | 9 |
| nesting deeper than 8 | 7 |
| unknown type (`Color`, `Tag.Style`, `Icon`) | 7 |
| excluded after the compiler rejected them | 5 |
| tuple input | 4 |
| generic input | 4 |
| dictionary input | 2 |
| internal type of another module | 2 |
