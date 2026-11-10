import Foundation
import SFBV
import SFProve
import SFSIL

/// The proof cache keys of one compiled module's claims (`ScanKeyContext`), with the cache they are looked up in.
struct ScanClaimKeys {
    let cache: ScanProofCache
    private let context: ScanKeyContext

    /// Hashes what the claims about `targets` (and their paired contracts) can reach in `compiled`.
    init(_ compiled: CompiledModule, targets: [FunctionInfo], specs: SpecIndex, cache: ScanProofCache) {
        let roots = targets.flatMap { info -> [String] in
            let contract = specs.contract(for: info)
            return [info.symbol] + [contract.requires?.symbol, contract.ensures?.symbol].compactMap { $0 }
        }
        self.cache = cache
        context = ScanKeyContext(
            module: compiled.module, compileIdentity: compiled.identity, roots: roots,
            versions: cache.versions ?? ScanToolIdentity.versions)
        cache.recordKeySeconds(context.seconds)
    }

    /// The claim about `info` under `contract` in the cache; nil (counted) when part of its identity is not known.
    func claim(_ info: FunctionInfo, contract: Contract, conflictBudget: Int) -> CachedClaim? {
        key(info, contract: contract, conflictBudget: conflictBudget).map { CachedClaim(key: $0, cache: cache) }
    }

    /// The key of the claim about `info` under `contract`; nil (counted) when part of its identity is not known.
    func key(_ info: FunctionInfo, contract: Contract, conflictBudget: Int) -> String? {
        let started = Date()
        defer { cache.recordKeySeconds(Date().timeIntervalSince(started)) }
        let key = context.key(
            function: info.symbol, requires: contract.requires?.symbol, ensures: contract.ensures?.symbol,
            claim: Self.claimText(info, contract), conflictBudget: conflictBudget)
        if key == nil { cache.recordUnkeyed() }
        return key
    }

    /// What the claim takes from the function's and the contract's declarations: their names and types, which decide
    /// whether `self` moves behind the result and whether the value after the call is passed (`Contract.ensuresArguments`).
    /// A name leaves out the debug scope that names compiler-written code (`Mode.hash(into:), scope 7`): an edit
    /// elsewhere renumbers it, and the claim reads only the name before it.
    private static func claimText(_ info: FunctionInfo, _ contract: Contract) -> String {
        func describe(_ info: FunctionInfo?) -> [String] {
            guard let info else { return ["none"] }
            return [info.symbol, withoutScope(info.displayName), info.resultType] + info.parameterTypes
        }
        let parts =
            describe(info) + ["isMethod=\(info.isMethod)", "mutatesSelf=\(Contract.mutatesSelf(info))"]
            + ["requires"] + describe(contract.requires) + ["ensures"] + describe(contract.ensures)
        guard let data = try? JSONEncoder().encode(parts), let text = String(bytes: data, encoding: .utf8) else {
            return parts.joined(separator: "\u{0}")
        }
        return text
    }

    /// `Mode.hash(into:), scope 7` -> `Mode.hash(into:)`; any other name as it is.
    static func withoutScope(_ name: String) -> String {
        guard let at = name.range(of: ", scope ", options: .backwards), !name[at.upperBound...].isEmpty,
            name[at.upperBound...].allSatisfy(\.isASCII), name[at.upperBound...].allSatisfy(\.isNumber)
        else { return name }
        return String(name[..<at.lowerBound])
    }
}

/// One claim's place in the proof cache.
struct CachedClaim {
    let key: String
    let cache: ScanProofCache

    /// Stores a checked answer: `proved` without `values`, a replayed counterexample with them. Never call it for
    /// an answer the LRAT checker did not accept or `honest` did not keep.
    func store(values: [UInt64]? = nil, approximations: Set<String> = [], stats: ProofStats, symbol: String) {
        var entry = ScanProofEntry(key: key, values: values, approximations: approximations, symbol: symbol)
        entry.assumptions = Assumptions.current.map(\.all).flatMap { $0.isEmpty ? nil : $0 }
        (entry.conflicts, entry.variables, entry.clauses) = (stats.conflicts, stats.variables, stats.clauses)
        cache.store(entry)
    }
}

extension Verifier {
    /// Proves `claim` about `subject` and records the answer; a checked `proved` and a counterexample `honest` kept go
    /// into the proof cache (`cached`). An undecided answer never does, nor does a counterexample that rests on what
    /// Objective-C calls returned (the entry would not hold those results) or one found with the ensures left out.
    static func solve(
        _ report: inout FunctionReport, _ subject: RefutedFunction, options: VerifyOptions, claim: Claim, cached: CachedClaim?
    ) throws {
        let proved = try proveClaim(widths: subject.function.parameterWidths, budget: options.conflictBudget, claim: claim)
        if proved.verdict != .proved, try solveBounded(&report, subject, options: options, claim: claim, cached: cached) { return }
        report.record(proved.stats, ifCollecting: options.collectStats)
        switch proved.verdict {
        case .proved:
            if reportBounded(&report) { break }
            report.status = report.hasContract ? .contractHolds : .safe
            cached?.store(stats: proved.stats, symbol: subject.info.symbol)
        case .unknown:
            if let why = proved.reason, subject.specs.ensures != nil,
                try refuteTrapUnderUndecidedEnsures(&report, subject, why, options)
            {
                break
            }
            explainUndecided(&report, why: proved.reason, budget: options.conflictBudget)
        case .counterexample(let values):
            if let returned = proved.foreignResults {
                refuteWithForeignResults(&report, values, subject, returned: returned)
            } else {
                refute(&report, values, subject, exact: proved.exact, options: options)
                cached?.store(
                    values: values, approximations: proved.approximations, stats: proved.stats, symbol: subject.info.symbol)
            }
        }
    }

    /// Answers `subject`'s claim from the cache when it holds an entry for it (`reuse`); false (the caller then
    /// solves) when there is none or it does not hold. Everything after the answer still runs in the caller.
    static func answerFromCache(
        _ report: inout FunctionReport, _ cached: CachedClaim, subject: RefutedFunction, options: VerifyOptions, claim: Claim
    ) throws -> Bool {
        guard let entry = cached.cache.lookup(cached.key) else { return false }
        if try reuse(entry, &report, subject: subject, options: options, claim: claim) {
            cached.cache.recordHit()
            return true
        }
        cached.cache.recordReplayFailed()
        return false
    }

    /// Uses a stored answer: a `proved` as it is, a counterexample only when the claim is false on its inputs again
    /// and `honest` keeps it. False when the entry does not hold for the claim.
    private static func reuse(
        _ entry: ScanProofEntry, _ report: inout FunctionReport, subject: RefutedFunction, options: VerifyOptions, claim: Claim
    ) throws -> Bool {
        let widths = subject.function.parameterWidths
        if options.collectStats {
            (report.solverConflicts, report.cnfVariables, report.cnfClauses) = (entry.conflicts, entry.variables, entry.clauses)
        }
        for assumption in entry.assumptions ?? [] { Assumptions.current?.record(assumption) }
        guard entry.verdict == .counterexample else {
            report.status = report.hasContract ? .contractHolds : .safe
            report.fromCache = true
            return true
        }
        guard let values = entry.counterexample, values.count == widths.count,
            zip(widths, values).allSatisfy({ $0 >= 64 || $1 >> UInt64($0) == 0 })
        else { return false }
        var approximations = Set(entry.approximations ?? [])
        let replay = try proveReporting(inputWidths: [], conflictBudget: options.conflictBudget) { c, _ in
            let (literal, used) = try claim(c, zip(widths, values).map { c.constant($1, width: $0) })
            approximations.formUnion(used)
            return literal
        }
        guard case .counterexample = replay.verdict else { return false }
        let (verdict, _) = try honest(
            .counterexample(values), approximations: approximations, widths: widths, budget: options.conflictBudget, claim: claim)
        guard case .counterexample = verdict else { return false }
        refute(&report, values, subject, exact: approximations.isEmpty, options: options)
        report.fromCache = true
        return true
    }
}

extension Verifier {
    /// The proof cache key of each function `run` would verify in `compiled` with `options` (by symbol; absent when
    /// part of its identity is not known). `versions` stands for the tool's (`ScanToolIdentity.versions`).
    package static func proofCacheKeys(
        _ compiled: CompiledModule, options: VerifyOptions = VerifyOptions(), versions: String? = ScanToolIdentity.versions
    ) -> [String: String] {
        let compiled = compiled.reading(options)
        let specs = SpecIndex(compiled.functions)
        let targets = targets(compiled, options: options, specs: specs)
        let keys = ScanClaimKeys(
            compiled, targets: targets, specs: specs, cache: ScanProofCache(directory: "/nonexistent", versions: versions))
        var result: [String: String] = [:]
        for info in targets {
            result[info.symbol] = keys.key(info, contract: specs.contract(for: info), conflictBudget: options.conflictBudget)
        }
        return result
    }
}

extension FunctionReport {
    mutating func record(_ stats: ProofStats, ifCollecting collect: Bool) {
        guard collect else { return }
        solverConflicts = stats.conflicts
        cnfVariables = stats.variables
        cnfClauses = stats.clauses
    }
}
