# `swiftformal check --json`: every field

The report of `swiftformal check … --json` (schema version 1). Keys that do not apply are left out, never `null`.

## Top level

| Key | Meaning |
|---|---|
| `schemaVersion` | `1`. |
| `entries` | One per function that was checked (with `--at`/`--symbol`, only that one). |
| `modules` | One per `--scan` target: what every verdict of it holds under. |
| `ranWalks`, `totalWalks` | Walks that ran, and walks found in the test target. A walk runs only when logic did not already prove or break the function it covers. |
| `unlinkedWalks` | Walks whose subject names no scanned function: they did not run. |
| `scanHints` | For unlinked walks: which `--scan` would link them. Absent when none. |

## Each entry

| Key | Meaning |
|---|---|
| `module`, `function` | The target and the function's name as reports print it (`Score.clamp(_:)`). |
| `package` | The package directory as given to `--scan`; with `module` it tells apart two packages that have a target of the same name. |
| `location` | `file`, `line`, `column` of the function. |
| `outcome` | The final verdict: `provedByLogic`, `provedByLogicAndWalk`, `provedByWalk`, `cannotTrap`, `counterexample`, `bounded`, `knownIssue`, `conflict`, `typeWalkFailed`, `walkMissing`, `unchecked`. |
| `logic` | Scan's own status: `safe`, `contractHolds`, `mayTrap`, `contractFails`, `undecided`, `unsupported`, `internalError`. |
| `counterexample` | For `mayTrap` and `contractFails`: `inputs` (strings such as `x = -128`), `failure`, and when known `result`, `at` (where it fails), `replay` (a call that reproduces it), `ensuresCall` (`f_ensures(…, f(…))`, which returns false). |
| `moreTraps` | Other ways the function can crash, each like `counterexample`. |
| `ignoredContracts` | Hand-written `f_requires` / `f_ensures` next to the function, which Scan does not read: `logic` says nothing about them. Move them into the function as `#requires` / `#ensures` under `@Verify`. |
| `category`, `detail`, `hint` | For `unsupported` and `undecided`: the kind of reason (`generics`, `loops`, `budget`, `unmodelled results`, …), the reason in words, and what to change. |
| `at`, `calledFrom` | For `unsupported`: where the code Scan does not read is (maybe in a callee), and the calls that lead there. |
| `proofScope` | `partialCorrectness`: a function with loops, proved for every run that ends (not that it ends). Absent for a proof over every run. |
| `origin` | `macro` or `build` for code nobody wrote by hand (a macro expansion, or a file under a build folder). |
| `weakContract` | Only with `--mutate`, on a contract that holds: `survivors` (each a `mutation`, its `kind` and `at`), the edits of the function the contract does not notice, and `mutantsTried`. |
| `walks` | The walks linked to this function (below). |

## Each walk (`walks[]`)

| Key | Meaning |
|---|---|
| `walk` | `subject`, `file`, `line`, and when known `suite` and `test`: the `Prove` call. |
| `knownIssue` | True when the call passes `knownIssue:` or the test wraps it in `withKnownIssue`. |
| `wholeType` | True when the walk's subject names only the function's type (a walk over a whole reducer): its failure is not blamed on this member (outcome `typeWalkFailed`) and it proves nothing about it. |
| `records` | One per result the call wrote. Empty: it did not report (outcome `walkMissing`). |
| `records[].verdict` | `proved` (every input of a complete domain), `bounded` (a sample) or `failed`. |
| `records[].evaluated`, `domainSize`, `domainComplete` | Inputs run, inputs in the domain, and whether the domain is complete. |
| `records[].properties[]` | `name`, `verdict`, and `checked`, or for a failure `input` and `detail`. A trap found by `Prove(neverTraps:)` is a failure of `never traps`. |
| `records[].inputType` | The type `$0` stands for in the `it:` closure, as Swift prints it: the input, or the state of a session walk. |

## Each module (`modules[]`)

| Key | Meaning |
|---|---|
| `module`, `optimization` | The target, and `-Onone` or `-O`. |
| `package` | The package directory as given to `--scan`. |
| `configurations` | The builds every verdict holds in: `debug` (asserts kept) and/or `release` (`-assert-config Release`). |
| `compiler`, `pinned` | First line of `swiftc -version`; `pinned: false` means the verdicts are not covered by SwiftFormal's trust notes. |
| `warnings` | Problems with the run as a whole. |
| `selection` | With `--at`/`--symbol`: the `selector` and the `function` it picked. |
| `proofCache` | `directory`, `trusted`, `hits`, `misses`, `stored`, `rejected`, `unkeyed`, `ioErrors`, `keySeconds`. Only checked proofs and replayed counterexamples are stored. |

## Other `check` flags you may need

`--no-walks` (logic only), `--strict` (exit 1 also when a function may crash), `--budget <n>` (solver budget per
function, default 300000), `--no-proof-cache` (prove everything again), `--show-unchecked` and `--show-proved` (text
report), `--xcode` (compiler-style `file:line:col: error|warning|note: [swiftformal] …` lines instead of JSON).
`--jobs <n>` (how many `--scan` packages are scanned at the same time; the report is the same as with `--jobs 1`).
`swiftformal check --help` lists them all.
