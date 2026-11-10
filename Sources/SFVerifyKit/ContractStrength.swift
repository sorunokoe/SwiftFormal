import Foundation
import SFBV
import SFCNF
import SFProve
import SFSIL

/// A contract that holds, but also holds for code that does something else (`sfverify --mutate`).
public struct WeakContract: Codable, Sendable {
    /// The edits of the function after which the contract still holds, while the function behaves differently.
    public var survivors: [SurvivingMutant]
    /// How many edits were checked against the contract.
    public var mutantsTried: Int
}

/// One edit of a function that its contract does not notice.
public struct SurvivingMutant: Codable, Sendable {
    /// What the edit does: `the call to State.show(_:) is skipped`.
    public var mutation: String
    /// `skippedCall`, `droppedWrite`, `returnedValue`, `negatedBranch`, `swappedCases`, `changedOperator` or
    /// `changedConstant`.
    public var kind: String
    /// Where the edited code is.
    public var at: SourceLocation?
    /// An input, meeting `requires`, on which the function and the edited function end differently (only possibly so
    /// when `mayBeEquivalent` is true).
    public var differsOn: [String]?
    /// True when no input was shown to tell the two apart (the difference depends on results logic does not model, or
    /// the solver ran out of budget): the edit may not change what the function does.
    public var mayBeEquivalent: Bool?  // swiftlint:disable:this discouraged_optional_boolean
    /// Why the edit may behave like the function, when `mayBeEquivalent` is true.
    public var reason: String?
}

/// Mutation testing of proved contracts: is the contract strong enough to notice a broken function?
enum ContractStrength {
    /// Edits checked per function, most telling kinds first (`SILModule.mutants(of:limit:)`).
    static let mutantsPerFunction = 16
    /// Seconds per function after which the remaining edits are not checked.
    static let secondsPerFunction = 30.0
    /// Solver conflicts per check of one edit.
    static let conflictBudget = 100_000

    /// `reports` with `weakContract` set on every `contractHolds` function with an `ensures` that some edit of the
    /// function also satisfies. Statuses never change.
    static func check(_ reports: [FunctionReport], compiled: CompiledModule) -> [FunctionReport] {
        let specs = SpecIndex(compiled.functions)
        let infos = Dictionary(compiled.functions.map { ($0.symbol, $0) }, uniquingKeysWith: { a, _ in a })
        let candidates = reports.indices.filter { index in
            let report = reports[index]
            guard report.status == .contractHolds, report.usesContracts == nil, let info = infos[report.symbol] else { return false }
            return specs.contract(for: info).ensures != nil
        }
        let results = Results(count: candidates.count)
        let module = compiled.module
        DispatchQueue.concurrentPerform(iterations: candidates.count) { position in
            onLargeStack {
                var report = reports[candidates[position]]
                if let info = infos[report.symbol] {
                    report.weakContract = weakness(of: info, module: module, specs: specs.contract(for: info))
                }
                results.set(position, report)
            }
        }
        var out = reports
        for (position, report) in zip(candidates.indices, results.values) { out[candidates[position]] = report }
        return out
    }

    /// The surviving edits of `info`, nil when every edit tried breaks the contract or behaves the same.
    static func weakness(of info: FunctionInfo, module: SILModule, specs: Contract) -> WeakContract? {
        guard let function = try? module.function(info.symbol),
            (try? SILVerifier.loops(of: info.symbol, in: module))?.isEmpty ?? false
        else { return nil }
        let subject = Subject(info: info, function: function, original: module, specs: specs)
        let started = Date()
        var tried = 0
        var survivors: [SurvivingMutant] = []
        for mutant in module.mutants(of: info.symbol, limit: mutantsPerFunction) {
            guard Date().timeIntervalSince(started) < secondsPerFunction else { break }
            guard let mutated = mutant.applied(to: module), (try? mutated.function(mutant.symbol)) != nil,
                let verdict = try? contractVerdict(subject, on: mutated)
            else { continue }
            if case .unknown = verdict { continue }
            tried += 1
            guard verdict == .proved, let survivor = judge(mutant, mutated, subject) else { continue }
            survivors.append(survivor)
        }
        return survivors.isEmpty ? nil : WeakContract(survivors: survivors, mutantsTried: tried)
    }

    /// The function a contract is checked for, as it was compiled.
    private struct Subject {
        let info: FunctionInfo
        let function: SILFunction
        let original: SILModule
        let specs: Contract
    }

    /// The contract's verdict on the mutant.
    private static func contractVerdict(_ subject: Subject, on mutated: SILModule) throws -> ProofVerdict {
        let function = try mutated.function(subject.info.symbol)
        return try proveReporting(inputWidths: function.parameterWidths, conflictBudget: conflictBudget) { c, inputs in
            try Verifier.claim(c, inputs, info: subject.info, module: mutated, specs: subject.specs).literal
        }.verdict
    }

    /// The mutant, which the contract holds for, as a survivor unless it is proved to behave like the function.
    private static func judge(_ mutant: SILMutant, _ mutated: SILModule, _ subject: Subject) -> SurvivingMutant? {
        let (info, function, original, specs) = (subject.info, subject.function, subject.original, subject.specs)
        var survivor = SurvivingMutant(
            mutation: mutant.description, kind: mutant.kind.rawValue, at: place(mutant, info))
        var unmodelled: Set<String> = []
        let outcome = try? proveReporting(inputWidths: function.parameterWidths, conflictBudget: conflictBudget) { c, inputs in
            let a = try SILEncoder(module: original, builder: c).encode(symbol: info.symbol, arguments: inputs)
            let b = try SILEncoder(module: mutated, builder: c).encode(symbol: info.symbol, arguments: inputs)
            unmodelled = a.approximations.union(b.approximations)
            return c.or(-(try meetsRequires(c, inputs, function: function, module: original, specs: specs)), same(c, a, b))
        }
        switch outcome?.verdict {
        case .proved:
            return nil  // equivalent: the edit does not change what the function does
        case .counterexample(let values):
            ValueRenderer.StandIns.$current.withValue(ValueRenderer.StandIns()) {
                survivor.differsOn = Verifier.renderInputs(
                    values, info: info, function: function, types: Verifier.leafTypes(info, function))
            }
            if !differs(values, info: info, function: function, original: original, mutated: mutated) {
                survivor.mayBeEquivalent = true
                let names = unmodelled.sorted().joined(separator: ", ")
                survivor.reason =
                    names.isEmpty
                    ? "the two were not told apart on that input"
                    : "the two may differ only in what \(names) returns, which logic does not model"
            }
        case .unknown, nil:
            survivor.mayBeEquivalent = true
            survivor.reason = "no answer within \(conflictBudget) solver conflicts on whether the edit changes the outcome"
        }
        return survivor
    }

    /// Where the edit is in the source: the debug position of its anchor value in the scanned function. Nil inside a
    /// closure (the debug info of those is not kept) and inside a macro expansion, which no one can open.
    private static func place(_ mutant: SILMutant, _ info: FunctionInfo) -> SourceLocation? {
        guard mutant.symbol == info.symbol, let anchor = mutant.anchor, let at = info.valueLocations[anchor],
            !at.file.hasPrefix("@__swiftmacro_")
        else { return nil }
        return at
    }

    /// Valid inputs on which `requires` is true and does not trap.
    private static func meetsRequires(
        _ c: CNFBuilder, _ inputs: [BV], function: SILFunction, module: SILModule, specs: Contract
    ) throws -> Int32 {
        let valid = function.inputAssumption(c, inputs)
        guard let spec = specs.requires else { return valid }
        let e = try SILEncoder(module: module, builder: c).encode(symbol: spec.symbol, arguments: inputs)
        guard e.result.width == 1 else { return c.falseLit }
        return c.and(valid, c.and(c.and(-e.trap, -e.undefined), e.result.bits[0]))
    }

    /// The two encodings end the same way: they trap alike, and where the first does not, they throw alike and give the
    /// same result, error and written-back values.
    private static func same(_ c: CNFBuilder, _ a: EncodedFunction, _ b: EncodedFunction) -> Int32 {
        let alike = c.and(-c.xor(a.trap, b.trap), -c.xor(a.undefined, b.undefined))
        let thrownA = a.throwing ?? c.falseLit, thrownB = b.throwing ?? c.falseLit
        var outputs = -c.xor(thrownA, thrownB)
        outputs = c.and(outputs, equal(c, a.writtenBack, b.writtenBack))
        outputs = c.and(outputs, c.or(thrownA, equal(c, a.results, b.results)))
        outputs = c.and(outputs, c.or(-thrownA, equal(c, a.error, b.error)))
        return c.and(alike, c.or(c.or(a.trap, a.undefined), outputs))
    }

    private static func equal(_ c: CNFBuilder, _ a: [BV], _ b: [BV]) -> Int32 {
        guard a.count == b.count else { return c.falseLit }
        return zip(a, b).reduce(c.trueLit) { c.and($0, $1.0.width == $1.1.width ? c.eq($1.0, $1.1) : c.falseLit) }
    }

    /// Whether, on these constant inputs, the function and the mutant fold to different outcomes. False when an
    /// outcome does not fold to a constant (it depends on results logic does not model).
    private static func differs(
        _ values: [UInt64], info: FunctionInfo, function: SILFunction, original: SILModule, mutated: SILModule
    ) -> Bool {
        let c = CNFBuilder()
        let inputs = zip(function.parameterWidths, values).map { c.constant($1, width: $0) }
        guard let a = try? SILEncoder(module: original, builder: c).encode(symbol: info.symbol, arguments: inputs),
            let b = try? SILEncoder(module: mutated, builder: c).encode(symbol: info.symbol, arguments: inputs)
        else { return false }
        func folded(_ e: EncodedFunction) -> [UInt64]? {
            let bits = [e.trap, e.undefined, e.throwing ?? c.falseLit].map { BV(bits: [$0]) }
            let all = bits + e.results + e.writtenBack + e.error
            let values = all.compactMap { c.constantValue($0) }
            return values.count == all.count ? values : nil
        }
        guard let x = folded(a), let y = folded(b) else { return false }
        return x != y
    }
}
