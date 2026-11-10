import Foundation
import SFBV
import SFCNF
import SFProve
package import SFSIL

public enum ScanStatus: String, Codable, Sendable {
    /// No input makes the function trap or hit undefined behaviour (proved for all inputs).
    case safe
    /// Some input makes the function trap; a concrete input is given.
    case mayTrap
    /// `requires ⇒ cannot trap ∧ ensures` holds for all inputs.
    case contractHolds
    /// The contract is false for a concrete input (the function, the spec, or both are wrong).
    case contractFails
    case undecided
    case unsupported
    /// The prover itself failed (proof or model rejected by the independent checker).
    case internalError
}

public struct ScanCounterexample: Codable, Sendable {
    /// `x = -128` for each parameter, in order.
    public var inputs: [String]
    /// What the function returned on that input, when it returns.
    public var result: String?
    /// What goes wrong, in words.
    public var failure: String
    /// Where it goes wrong, when the compiler's debug info says.
    public var at: SourceLocation?
    /// A call that reproduces it: for a free function over scalars, or a trap in a method, getter or initializer
    /// whose `self` and arguments can be written in Swift (`State(index: -1).tab`).
    public var replay: String?
    /// For a method without a `replay`: why there is none (a value with no Swift literal, a private type, ...).
    public var noReplay: String?
    /// For a broken postcondition with a `replay`: the `_ensures` call on the inputs and that call, which returns
    /// false (`clamp_ensures(1, 2, 0, clamp(1, 2, 0))`).
    public var ensuresCall: String?
    /// Set by `sfverify --confirm`: true when a native build reproduced the counterexample, false when it did not
    /// (the function is then an `internalError`). Absent when it was not run.
    public var confirmed: Bool?  // swiftlint:disable:this discouraged_optional_boolean
    /// What Objective-C calls returned in this run (`input.count returned 300`), in call order; also listed in `inputs`.
    /// The values come from code Scan does not read: the trap needs a foreign object that returns them. Absent when the
    /// counterexample rests on no foreign call.
    public var foreignResults: [String]?
}

public struct FunctionReport: Codable, Sendable {
    public var name: String
    public var symbol: String
    public var location: SourceLocation?
    public var status: ScanStatus
    /// For `unsupported`: a short category (loops, class, string, ...). For `undecided`: `budget` (no answer within
    /// the conflict budget) or `unmodelled results` (the answer depends on call results logic does not model).
    public var category: String?
    public var detail: String?
    public var counterexample: ScanCounterexample?
    /// Other places the function can trap, each with its own input (plan item H3); absent when there are none or the
    /// search was off. `counterexample` is the first one found.
    public var moreTraps: [ScanCounterexample]?
    public var hasContract: Bool
    /// `macro` or `build` for code nobody wrote by hand (`FunctionInfo.origin`); absent otherwise. Such functions are
    /// reported but not counted in `summary` (they are in `summary.generatedCode`).
    public var origin: String?
    /// With `--cross-check llvm`: for a proved function, whether the LLVM IR encoding agrees (`agrees`, `disagrees`,
    /// `unread`); absent otherwise (plan item V4).
    public var crossCheck: String?
    /// With `crossCheck` = `unread`: why the IR reader (or the equivalence's own checks) refused the function, as the
    /// reader's error text (`UNSUPPORTED: ...`); absent otherwise.
    public var crossCheckReason: String?
    public var seconds: Double
    /// Solver conflicts spent on this function (summed over refinement rounds). Present only when the run asked for statistics.
    public var solverConflicts: Int?
    /// Variables of the formula the solver received. Present only when the run asked for statistics.
    public var cnfVariables: Int?
    /// Original clauses of the formula the solver received. Present only when the run asked for statistics.
    public var cnfClauses: Int?
    /// For `unsupported`: where the construct Scan does not read is, when the debug info says. It may be in a callee
    /// (then `calledFrom` leads there).
    public var at: SourceLocation?
    /// For `unsupported` with `at` in a callee: the calls that lead there from this function, innermost first.
    public var calledFrom: [SourceLocation]?
    /// For `unsupported`, `undecided` and a spec-shape error: what to change so that Scan can decide the function.
    public var hint: String?
    /// With `--modular`: the callees whose proved contracts stood in for their code in this proof (plan item H4).
    public var usesContracts: [String]?
    /// True when the answer came from the proof cache (`ScanProofCache`); absent otherwise. A cached counterexample was
    /// replayed, and everything after the answer (contracts held by a caller, the second build, cross-checks) ran.
    public var fromCache: Bool?  // swiftlint:disable:this discouraged_optional_boolean
    /// What a proof covers when it is less than every run: `partialCorrectness` for a function with loops, proved
    /// for every run that ends (termination is not proved). Absent for a proof over every run and for other statuses.
    public var proofScope: String?
    /// With `--mutate`: the edits of the function its proved contract does not notice; nil when there are none.
    public var weakContract: WeakContract?
    /// For `unsupported` at a type Scan cannot read (`type Color`) with no `at`: where the type sits in what the function
    /// reads, through stored properties and enum payloads (`self.tabs.style: Color`). Absent when unknown.
    public var typePath: String?
    /// What the verdict takes on trust about code Scan has no body of (`--no-opaque-calls` refuses it all): each
    /// call into a binary module, Objective-C method or `==` of Objective-C objects whose result was any value of its
    /// type and that was assumed not to trap (`` `Surface.ordinal` may return any Int32 and is assumed not to trap ``).
    /// A proof holds for every value those calls may return. Absent when there are none, and for a function not decided.
    public var assumptions: [String]?
    /// For `undecided` with category `bounded`: the closure-taking calls over an array of unknown length the proof
    /// holds for only up to `CollectionBounds.iterations` elements (`map over Array<Int> (n ≤ 8)`); absent otherwise.
    public var bounded: [String]?
    /// Hand-written functions next to this one that look like its contract (`f_requires`, `f_ensures`). Scan reads only
    /// the contract `@Verify` writes, so these were not checked and `status` says nothing about them: write the contract
    /// in place with `@Verify`, `#requires` and `#ensures`. Absent when there are none.
    public var ignoredContracts: [String]?

    /// The `proofScope` of a loop proof.
    public static let partialCorrectness = "partialCorrectness"
}

public struct VerifyOptions: Sendable {
    public var conflictBudget: Int
    /// Only functions whose name contains one of these (empty: all).
    public var only: [String]
    /// Record the solver's deterministic counts per function (`solverConflicts`, `cnfVariables`, `cnfClauses`).
    public var collectStats = false
    /// The `assert` configurations a `-Onone` verdict must hold in. `safe` and `contractHolds` need every one; a
    /// failure in any one is reported. The default is both: a debug build traps on a failed `assert`, a release build
    /// removes it (and the side effects of its condition).
    public var configurations: [BuildConfiguration] = [.debug, .release]
    /// The compilers the reader was validated against (tests replace it to simulate an unpinned compiler).
    package var pin: CompilerPin = .verified
    /// After a `mayTrap`, how many other trap sites to look for (each one extra solve, only for exact encodings);
    /// 0 turns the search off.
    public var moreTraps = 4
    /// Whether proved verdicts are compared with the LLVM IR's meaning (plan item V4); off by default.
    public var crossCheck: CrossCheck = .off
    /// Retry what the inlined run left undecided or too deep with the proved contracts of callees (plan item H4).
    public var modular = false
    /// When a loop proof does not go through: how many iterations to unroll in search of an input that traps
    /// (plan item L3; 0: no search). A trap found is real; none found within the bound proves nothing.
    public var unwind = 8
    /// `--mutate`: check each proved contract against small edits of its function (`WeakContract`).
    public var mutate = false
    /// Verify and report only the one function this picks (`SFVerify.run`); the others stay in the inventory.
    public var selector: FunctionSelector?
    /// Where checked answers are kept between runs (plan item D4); nil (the default) solves every claim.
    /// `SFVerify.run` reports what it did in `ScanReport.proofCache`.
    public var proofCache: ScanProofCache?
    /// Whether a call with no body (into a binary module such as a Kotlin framework, an Objective-C method, `==` of
    /// Objective-C objects) may return any value and is assumed not to trap, each one listed in the report's
    /// `assumptions`. False (`--no-opaque-calls`) refuses every such call: a function that makes one is unsupported.
    public var opaqueCalls = true
    /// Walk claims to decide for every input (`swiftformal check`); each result is in `ScanReport.relational`.
    public var relational: [RelationalRequest] = []
    public init(conflictBudget: Int = 300_000, only: [String] = []) {
        self.conflictBudget = conflictBudget
        self.only = only
    }
}

public enum Verifier {
    /// Verifies every function of `compiled` that the proof engine supports, and reports why it skipped the others.
    public static func run(_ compiled: CompiledModule, options: VerifyOptions = VerifyOptions()) -> [FunctionReport] {
        run(compiled, options: options, symbols: nil)
    }

    /// `run`, limited to the functions in `symbols` when it is given.
    static func run(_ compiled: CompiledModule, options: VerifyOptions, symbols: Set<String>?) -> [FunctionReport] {
        let compiled = compiled.reading(options)
        let specs = SpecIndex(compiled.functions)
        let targets = targets(compiled, options: options, specs: specs).filter { symbols?.contains($0.symbol) ?? true }
        let results = Results(count: targets.count)
        let byName = Dictionary(compiled.functions.map { ($0.symbol, $0) }, uniquingKeysWith: { a, _ in a })
        let module = compiled.module
        let keys = options.proofCache.map { ScanClaimKeys(compiled, targets: targets, specs: specs, cache: $0) }
        let scope = VerifyScope(module: module, functions: byName, keys: keys)
        DispatchQueue.concurrentPerform(iterations: targets.count) { index in
            onLargeStack {
                results.set(index, verify(targets[index], specs: specs.contract(for: targets[index]), options: options, in: scope))
            }
        }
        let reports =
            options.modular
            ? retryWithContracts(results.values, targets: targets, module: module, specs: specs, options: options) : results.values
        return Demangler.improve(reports.map { notPaired($0, specs.unpaired(for: $0.symbol)) })
    }

    /// The functions `run` verifies: those the user wrote (not compiler-synthesized, not contract functions) that
    /// `options.only` keeps, and a `_requires` / `_ensures` peer of `@Verify` that pairs with no function, so that a
    /// contract Scan cannot read is reported (as `macro` code), never dropped.
    static func targets(_ compiled: CompiledModule, options: VerifyOptions, specs: SpecIndex) -> [FunctionInfo] {
        compiled.functions.filter { info in
            (!info.isGenerated || SpecIndex.isUnpairedPeer(info, specs)) && !specs.isSpec(info.symbol)
                && (options.only.isEmpty || options.only.contains { info.displayName.contains($0) })
        }
    }

    static func verify(_ info: FunctionInfo, specs: Contract, options: VerifyOptions, in scope: VerifyScope) -> FunctionReport {
        let started = Date()
        var report = withAssumptions { verifyUntimed(info, specs: specs, options: options, in: scope) }
        report.seconds = Date().timeIntervalSince(started)
        return heldByCaller(report, module: scope.module)
    }

    /// `readingContract`: when logic cannot read a contract, try the function without it (`explainUnreadContract`).
    static func verifyUntimed(
        _ info: FunctionInfo, specs: Contract, options: VerifyOptions, in scope: VerifyScope, readingContract: Bool = true
    ) -> FunctionReport {
        let (module, functions) = (scope.module, scope.functions)
        var report = FunctionReport(
            name: info.displayName, symbol: info.symbol, location: info.location, status: .unsupported,
            hasContract: specs.requires != nil || specs.ensures != nil, seconds: 0
        )
        report.origin = info.origin
        if !specs.ignored.isEmpty { report.ignoredContracts = specs.ignored.map(\.displayName) }
        do {
            let function = try module.function(info.symbol)
            try checkSpecShapes(info, function, specs, module: module)
            // A function the loop planner cannot read goes on below, where the refusal gets its location.
            if let loops = try? SILVerifier.loops(of: info.symbol, in: module), !loops.isEmpty {
                let subject = RefutedFunction(info: info, function: function, module: module, specs: specs, functions: [:])
                try verifyLoops(&report, subject, options: options)
                return report
            }
            let claimed: Claim = { c, inputs in
                let made = try claim(c, inputs, info: info, module: module, specs: specs)
                return (made.literal, made.approximations)
            }
            let subject = RefutedFunction(info: info, function: function, module: module, specs: specs, functions: functions)
            let cached = scope.keys?.claim(info, contract: specs, conflictBudget: options.conflictBudget)
            try solveReadingCollections(&report, subject, options: options, claim: claimed, cached: cached)
        } catch let refusal as any Refusal {
            explainUnsupported(&report, refusal.refused, trail: refusal.trail, functions: functions)
            placeOpaqueType(&report, info, module: module)
            if readingContract { explainUnreadContract(&report, info, specs: specs, options: options, in: scope) }
        } catch let error as SpecProblem {
            report.status = .internalError
            report.category = "spec shape"
            report.detail = error.description
            report.hint = hint(forCategory: "spec shape")
        } catch {
            report.status = .internalError
            report.detail = "\(error)"
        }
        return report
    }

    /// Records a refutation: the explained counterexample and, for an exact encoding, the other trap sites (H3).
    static func refute(
        _ report: inout FunctionReport, _ values: [UInt64], _ refuted: RefutedFunction, exact: Bool, options: VerifyOptions
    ) {
        report.status = report.hasContract ? .contractFails : .mayTrap
        report.counterexample = refuted.explain(values)
        guard !report.hasContract, exact, options.moreTraps > 0 else { return }
        let more = moreTraps(first: values, of: refuted, budget: options.conflictBudget, limit: options.moreTraps)
        if !more.isEmpty { report.moreTraps = more }
    }

    /// `f_requires` takes exactly `f`'s parameters, `f_ensures` the parameters, the result (and `self`).
    private static func checkSpecShapes(_ info: FunctionInfo, _ function: SILFunction, _ specs: Contract, module: SILModule) throws {
        if specs.requires != nil || specs.ensures != nil, function.objectParameter != nil || function.returnsObject {
            // `ensures` would see a class parameter after the call, where the contract means it before (plan item L5).
            throw SILError.unsupported("a contract on a function with a class parameter or result")
        }
        if let spec = specs.ensures {
            let expected = Contract.ensuresArguments(
                function.parameterWidths, function.resultWidths, writtenBack: function.writtenBackWidths, of: function, info)
            guard try module.function(spec.symbol).parameterWidths == expected else {
                throw SpecProblem.shape("\(spec.displayName) must take the parameters of \(info.displayName) followed by its result")
            }
        }
        if let spec = specs.requires {
            guard try module.function(spec.symbol).parameterWidths == function.parameterWidths else {
                throw SpecProblem.shape("\(spec.displayName) must take exactly the parameters of \(info.displayName)")
            }
        }
    }

    /// The claim literal and the summarized standard-library calls its encoding relied on.
    typealias Claim = (CNFBuilder, [BV]) throws -> (literal: Int32, approximations: Set<String>)

    /// `requires ⇒ ¬trap ∧ ¬undefined ∧ ensures`, with the spec functions encoded by the same encoder as the code.
    /// With `summaries` (plan item H4) the claim is read under what the summarized calls' results are assumed to
    /// satisfy, and `contracts` names those callees.
    static func claim(
        _ c: CNFBuilder, _ inputs: [BV], info: FunctionInfo, module: SILModule, specs: Contract,
        summaries: [String: ContractSummary] = [:]
    ) throws -> MadeClaim {
        let f = try encodeLocated(module, c, symbol: info.symbol, arguments: inputs, summaries: summaries)
        var assumed = [f.assumption]
        var contracts = f.contractsUsed
        var approximations = f.approximations
        let valid = try module.function(info.symbol).inputAssumption(c, inputs)
        var assumption = valid
        var specSafe = c.trueLit
        if let spec = specs.requires {
            let e = try encodeLocated(module, c, symbol: spec.symbol, arguments: inputs, summaries: summaries)
            approximations.formUnion(e.approximations)
            (assumed, contracts) = (assumed + [e.assumption], contracts.union(e.contractsUsed))
            guard e.result.width == 1 else { throw SpecProblem.shape("\(spec.displayName) must return Bool") }
            assumption = c.and(valid, e.result.bits[0])
            specSafe = c.or(-valid, c.and(-e.trap, -e.undefined))
        }
        var good = c.and(-f.trap, -f.undefined)
        if let spec = specs.ensures {
            let arguments = Contract.ensuresArguments(
                inputs, f.results, writtenBack: f.writtenBack, of: try module.function(info.symbol), info)
            let e = try encodeLocated(module, c, symbol: spec.symbol, arguments: arguments, summaries: summaries)
            approximations.formUnion(e.approximations)
            (assumed, contracts) = (assumed + [e.assumption], contracts.union(e.contractsUsed))
            guard e.result.width == 1 else { throw SpecProblem.shape("\(spec.displayName) must return Bool") }
            // `ensures` is about a normal return; a function that throws has no result (plan item L6).
            good = c.and(good, c.or(f.throwing ?? c.falseLit, c.and(c.and(-e.trap, -e.undefined), e.result.bits[0])))
        }
        let literal = c.and(specSafe, c.or(-assumption, good))
        let summarized = assumed.compactMap { $0 }
        guard !summarized.isEmpty else { return MadeClaim(literal: literal, approximations: approximations, contracts: contracts) }
        let all = summarized.reduce(c.trueLit) { c.and($0, $1) }
        return MadeClaim(literal: c.or(-all, literal), approximations: approximations, contracts: contracts)
    }

    /// A claim literal, the summarized standard-library calls it relied on and the callee contracts it used (H4).
    struct MadeClaim {
        let literal: Int32
        let approximations: Set<String>
        let contracts: Set<String>
    }

    // MARK: classification

    /// `[K : V]`: a dictionary written with brackets (a colon at the top level of the brackets).
    package static func isDictionaryLiteralType(_ type: String) -> Bool {
        guard type.hasPrefix("["), type.hasSuffix("]") else { return false }
        var depth = 0
        for character in type.dropFirst().dropLast() {
            if "[(<".contains(character) { depth += 1 }
            if "])>".contains(character) { depth -= 1 }
            if character == ":", depth == 0 { return true }
        }
        return false
    }

    /// Categories of unsupported types, tried in order; the first match wins.
    private static let typeCategories: [(matches: @Sendable (String) -> Bool, label: String)] = [
        (
            { $0.contains("fM") && ($0.hasPrefix("$s") || ($0.hasPrefix("s") && $0.dropFirst().first?.isNumber == true)) },
            "macro-generated types"
        ),
        ({ $0.hasPrefix("Optional<") || $0.hasSuffix("?") }, "optionals"),
        ({ $0 == "String" || $0 == "Substring" || $0 == "Character" }, "strings"),
        ({ $0.hasPrefix("Dictionary<") || $0.hasPrefix("Set<") || Verifier.isDictionaryLiteralType($0) }, "dictionaries and sets"),
        ({ $0.hasPrefix("Array<") || $0.hasPrefix("[") || $0.hasPrefix("ContiguousArray<") }, "arrays"),
        ({ $0.contains("Iterator") }, "for-in loops"),
        (
            { $0.contains("Range<") || $0.contains("RangeFrom<") || $0.contains("RangeThrough<") || $0.contains("RangeUpTo<") },
            "ranges of non-integer bounds"
        ),
        ({ $0 == "Double" || $0 == "Float" || $0 == "CGFloat" || $0.contains("Builtin.FPIEEE") }, "floating point"),
        ({ $0.hasPrefix("any ") || $0.hasPrefix("some ") }, "existentials / protocols"),
        ({ $0.contains("@_opaqueReturnTypeOf") }, "opaque result types (some …)"),
        ({ $0.hasPrefix("@") || $0.contains("->") }, "closures"),
    ]

    /// A short, stable category for an unsupported construct, so the coverage table is readable.
    package static func category(of error: SILError) -> String {
        let text = error.description
        if text.contains(SILError.ambiguousTypeKind) { return "ambiguous type names" }
        if let r = text.range(of: "type "), let end = text.range(of: SILError.supportedTypesNote) {
            var type = String(text[r.upperBound..<end.lowerBound])
            for prefix in ["@guaranteed ", "@owned ", "@in_guaranteed ", "@inout ", "@thick ", "@thin ", "@out "] {
                type = type.replacingOccurrences(of: prefix, with: "")
            }
            return typeCategories.first { $0.matches(type) }?.label ?? "type \(type)"
        }
        let reason = text.replacingOccurrences(of: SILError.supportedTypesNote, with: "")
        let table: [(String, String)] = [
            ("array of ", "arrays"), ("destroying a closure", "closures"), ("UNSUPPORTED: class ", "classes and objects"),
            ("UNSUPPORTED: protocol ", "existentials / protocols"), ("class parameter", "classes and objects"),
            ("class field", "classes and objects"), ("returned object", "classes and objects"),
            ("parameter's object", "classes and objects"), ("passes an object", "classes and objects"),
            ("indirect enum", "enums"), ("loops in", "loops (need an invariant)"), ("recursion", "recursion"),
            ("call depth", "deep call chain"), ("Objective-C", "Objective-C objects"),
            ("no body for", "calls a function without a body"), ("alloc_ref", "classes and objects"),
            ("generic", "generics"), ("existential", "existentials / protocols"), ("witness_method", "protocol dispatch"),
            ("class_method", "classes and objects"), ("indirect call", "closures and indirect calls"),
            ("array", "arrays"), ("Array", "arrays"), ("switch_enum", "enums"), ("mutable global", "mutable globals"),
            ("global", "globals"), ("async", "concurrency"), ("actor", "concurrency"),
        ]
        for (needle, label) in table where reason.contains(needle) { return label }
        if case .invalid = error { return "unrecognised SIL" }
        return "other"
    }
}

private enum SpecProblem: Error, CustomStringConvertible {
    case shape(String)
    var description: String {
        switch self {
        case .shape(let s): s
        }
    }
}
