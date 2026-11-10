/// What `sfverify --help` prints.
let usage = """
    sfverify — prove that Swift functions cannot trap, and check plain-Swift contracts, from the compiler's own SIL.

    USAGE
      sfverify [options] file.swift [file.swift ...]
      sfverify [options] --package <dir> [--target <name>]
      sfverify [options] --build-log <file> --target <name> [--package <dir>]

    OPTIONS
      --module <name>        Module name when compiling files (default: Sample).
      --package <dir>        Verify the sources of a SwiftPM target (Sources/<target>/**).
      --target <name>        Target inside --package (optional when there is only one).
      --build                With --package: build the target with SwiftPM first and reuse its exact compiler flags
                             (-package-name, -D conditions, experimental features, dependency modules). Recommended.
      --build-log <file>     Take the target's compile command from this log of the build that ran last in the
                             scratch path instead of building: `swift build -v` output (what `swift package scan`
                             passes), `xcodebuild` output, an `.xcactivitylog`, or a DerivedData folder (its newest
                             activity log that compiled the target). Needs --target (the module name). A log of a build that compiled nothing has no command: then
                             the command saved for the same build description is used, or the scan stops and says so.
      --scratch-path <dir>   The build folder: of --build (default <package>/.build) or of the build the
                             --build-log comes from (default <package>/.build).
      --cache-dir <dir>      With --build-log: where the saved command is kept (default: the scratch path).
      --swiftc-arg <arg>     Extra argument for the Swift frontend; repeatable (-I, -F, -D, -target, -sdk, ...).
      -O                     Verify the optimized SIL instead of -Onone (a release build).
      --config <c>           At -Onone, which builds a verdict must hold in: debug (asserts kept), release
                             (asserts removed, -assert-config Release) or both (default). A failed assert traps in
                             debug; removing it also removes the side effects of its condition, so release differs.
      --cross-check <c>      llvm: compare each proved function with the meaning of its LLVM IR, read by a second,
                             separately written encoder, and say whether they agree (crossCheck in --json).
                             llvm-strict: a proof the IR does not confirm becomes undecided. Off by default.
      --unwind <n>           When a loop proof fails, look for an input that traps within <n> iterations
                             (default 8; 0 turns it off). A trap found is real; none found proves nothing.
      --modular              Prove again what is undecided or too deep to inline, with the contracts of callees
                             proved in the same run standing for their code (usesContracts in --json). Only a
                             proof is kept; every other verdict is the one with callees inlined.
      --mutate               For each contract that holds, check it again on small edits of its function (skip a
                             call that changes self, drop a write, return another value, negate a branch, swap two
                             switch cases, change an operator) and report it as weak when an edit that changes the
                             result still satisfies it (weakContract in --json). Verdicts do not change. At most 16
                             edits and 30 s per function.
      --only <text>          Only functions whose name contains <text>; repeatable.
      --at <file>:<line>     Only the function whose body holds that line (the innermost one; a declaration, attribute
                             or doc-comment line counts). Fails unless exactly one function is there.
      --symbol <name>        Only the function with this name as reports print it (`Score.clamp(_:)`), or with this
                             Type.member and argument labels. Fails unless exactly one function has it. The module is
                             still compiled whole; --at and --symbol only skip proving the others.
      --budget <n>           Solver conflict budget per function (default 300000).
      --proof-cache <dir>    Reuse checked answers from <dir> and store new ones (default with --package:
                             <package>/.build/swiftformal/proofs; without a package: off). Only checked proofs and
                             replayed counterexamples are stored; a function whose code, contracts, callees,
                             compiler or flags changed is proved again. Ignored unless <dir> and every directory
                             above it are writable by the current user (or root) only. Not used by --gate.
      --no-proof-cache       Prove everything again; read and write no proof cache.
      --no-opaque-calls      Refuse every call with no body (binary modules such as a Kotlin framework, Objective-C
                             methods, `==` of Objective-C objects): a function that makes one is unsupported. By
                             default each such call may return any value, is assumed not to trap, and is listed in the
                             function's assumptions.
      --module-cache <dir>   Keep the compiler's module cache under <dir> (default: SFVERIFY_MODULE_CACHE, else the
                             user's cache directory, else the temporary directory), one folder per compiler.
      --paranoid             Also let the compiler verify its own SIL after every pass (-sil-verify-all; compiles take
                             40 to 75 % longer). It checks the compiler, not sfverify's reader.
      --json                 Machine-readable report on stdout (for AI agents and CI).
      --stats                With --json: add the solver's deterministic counts to each function
                             (solverConflicts, cnfVariables, cnfClauses). Without it the JSON has no such keys.
      --xcode                Print only file:line:col diagnostics.
      --format <f>           text (default), json (as --json), xcode (as --xcode), sarif (SARIF 2.1.0, for GitHub
                             code scanning and SARIF viewers) or github (GitHub Actions ::error/::warning
                             annotations). sarif and github make paths relative to the working directory.
      --show-unsupported     List every function that is outside the supported subset, where the construct is
                             (with the calls that lead there) and what to change. With --xcode: as note: lines.
      --gate                 Build gate: prove only functions marked `@Verify` and exit 1, with file:line:col
                             errors, unless every one is proved. Unsupported, undecided and unfound gated functions
                             fail too (fail closed), and so do a `// sf:verify` comment and a hand-written
                             f_requires / f_ensures, which are not read. With --build when the files use `@Verify`.
      --stamp <path>         With --gate: write this file only when the gate passes (a build-system output).
      --time-limit <s>       With --gate: fail the build if proving takes longer (default 60). The gate's default
                             --budget is 50000 conflicts.
      --strict               Exit 1 also when a function may trap (default: only for contract failures).
      --emit-tests <dir>     Write <dir>/<Module>ScanPlaybackTests.swift: one Swift Testing test per counterexample
                             of a free function over scalars, or per trap in a method or getter whose `self` and
                             arguments can be written in Swift; it passes while it reproduces (an exit test for a
                             trap, `#expect(!f_ensures(…, f(…)))` for a broken postcondition).
      --confirm              Build the scanned files with those tests in a scratch package and run each (this
                             builds and runs your code). Each counterexample is marked confirmed; one that does not
                             reproduce natively becomes a prover error (the model and the compiler disagree).
      -h, --help             This text.
    An option that takes a value also accepts --option=value. A flag that has no effect in the combination given
    (for example --stats without --json) is reported as a warning on stderr.

    CONTRACTS
      Write them in place (`import SwiftFormal`): `@Verify func f(…) { #requires(…); #ensures { … }; … }`.
      sfverify then proves: requires ⇒ f cannot trap ∧ ensures, for every input, or prints an input that breaks it.
      It reads only what @Verify writes (scan such a file with --package --build); a hand-written f_requires /
      f_ensures is not read (ignoredContracts). Without a contract, sfverify proves f cannot trap for ANY input.

    EXIT CODES  0 ok · 1 contract failed (or --strict and a function may trap) · 2 usage or compiler error
    """
