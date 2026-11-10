import Foundation
import SFBV
import SFProve
import SFSIL

/// `--modular` (plan item H4): assume-guarantee with the contracts proved in the same run.
///
/// The run first verifies every function with its callees inlined, as without the option; nothing it decides changes.
/// Then, in rounds, each function it left `undecided` or refused as a deep call chain is proved again with every
/// callee whose contract a *previous* round proved standing for its code (`SILEncoder.summarize`). Only a proof is
/// kept: a counterexample found that way may rest on what the contract leaves open, so the inlined verdict stays. The
/// contracts of a round are fixed before it starts, so a proof never rests on a contract proved with its own help, and
/// the result does not depend on the order in which the functions of a round finish.
extension Verifier {
    /// The most rounds: each one can only use contracts proved before it, so a chain needs one round per level.
    static let modularRounds = 16

    static func retryWithContracts(
        _ reports: [FunctionReport], targets: [FunctionInfo], module: SILModule, specs: SpecIndex, options: VerifyOptions
    ) -> [FunctionReport] {
        var reports = reports
        let names = Dictionary(targets.map { ($0.symbol, $0.displayName) }, uniquingKeysWith: { a, _ in a })
        let context = ModularContext(module: module, names: names, options: options)
        var used: Set<String> = []
        for _ in 0..<modularRounds {
            let summaries = contractSummaries(reports, targets: targets, module: module, specs: specs)
            // A function is solved again only when it calls a contract it could not use in an earlier round.
            let fresh = Set(summaries.keys).subtracting(used)
            used.formUnion(fresh)
            let open = reports.indices.filter { index in
                retriable(reports[index], targets[index], module: module)
                    && !module.callees(of: symbols(targets[index], specs.contract(for: targets[index]))).isDisjoint(with: fresh)
            }
            guard !open.isEmpty else { break }
            let proved = Results(count: open.count)
            let current = reports
            DispatchQueue.concurrentPerform(iterations: open.count) { k in
                onLargeStack {
                    let index = open[k]
                    let started = Date()
                    let info = targets[index]
                    var retried: FunctionReport?
                    let made = withAssumptions {
                        retried = proveWithContracts(current[index], info, specs: specs.contract(for: info), summaries, context)
                        return retried ?? current[index]
                    }
                    guard retried != nil else { return }
                    var report = made
                    report = heldByCaller(report, module: module)
                    report.seconds += Date().timeIntervalSince(started)
                    proved.set(k, report)
                }
            }
            let found = proved.values
            guard !found.isEmpty else { break }
            let bySymbol = Dictionary(found.map { ($0.symbol, $0) }, uniquingKeysWith: { a, _ in a })
            reports = reports.map { bySymbol[$0.symbol] ?? $0 }
        }
        return reports
    }

    /// `info` and its spec functions.
    private static func symbols(_ info: FunctionInfo, _ specs: Contract) -> [String] {
        [info.symbol] + [specs.requires?.symbol, specs.ensures?.symbol].compactMap { $0 }
    }

    /// Undecided, or refused only because the inlined call chain is too deep; not a function with loops (its proof
    /// is the loop proof).
    private static func retriable(_ report: FunctionReport, _ info: FunctionInfo, module: SILModule) -> Bool {
        guard
            (report.status == .undecided && report.category != "exclusivity")
                || (report.status == .unsupported && report.category == "deep call chain")
        else {
            return false
        }
        return (try? module.function(info.symbol))?.isLoopFree ?? false
    }

    /// The proved contracts that may stand for their function: proved without loops (a loop proof is partial
    /// correctness), and of a function that writes nothing back and cannot throw.
    private static func contractSummaries(
        _ reports: [FunctionReport], targets: [FunctionInfo], module: SILModule, specs: SpecIndex
    ) -> [String: ContractSummary] {
        var summaries: [String: ContractSummary] = [:]
        for (report, info) in zip(reports, targets) where report.status == .contractHolds {
            let contract = specs.contract(for: info)
            guard let function = try? module.function(info.symbol), function.writtenBackWidths.isEmpty, function.errorType == nil,
                function.isLoopFree,
                contract.requires != nil || contract.ensures != nil
            else { continue }
            summaries[info.symbol] = ContractSummary(
                requires: contract.requires?.symbol, ensures: contract.ensures?.symbol, assumptions: report.assumptions ?? [],
                ensuresArguments: { inputs, results in
                    Contract.ensuresArguments(inputs, results, writtenBack: [], of: function, info)
                })
        }
        return summaries
    }

    /// What every retry of a run shares: the module, display names by symbol, the options.
    struct ModularContext {
        let module: SILModule
        let names: [String: String]
        let options: VerifyOptions
    }

    /// `report` as proved with `summaries`, or nil when that proof does not go through or uses no contract.
    private static func proveWithContracts(
        _ report: FunctionReport, _ info: FunctionInfo, specs: Contract, _ summaries: [String: ContractSummary],
        _ context: ModularContext
    ) -> FunctionReport? {
        let (module, names, options) = (context.module, context.names, context.options)
        guard let function = try? module.function(info.symbol) else { return nil }
        var used: Set<String> = []
        let outcome = try? proveReporting(inputWidths: function.parameterWidths, conflictBudget: options.conflictBudget) { c, inputs in
            let made = try claim(c, inputs, info: info, module: module, specs: specs, summaries: summaries)
            used.formUnion(made.contracts)
            return made.literal
        }
        guard let outcome, outcome.verdict == .proved, !used.isEmpty else { return nil }
        var proved = report
        proved.status = proved.hasContract ? .contractHolds : .safe
        (proved.category, proved.detail, proved.hint, proved.at, proved.calledFrom) = (nil, nil, nil, nil, nil)
        proved.usesContracts = used.map { names[$0] ?? $0 }.sorted()
        if options.collectStats {
            (proved.solverConflicts, proved.cnfVariables, proved.cnfClauses) =
                (outcome.stats.conflicts, outcome.stats.variables, outcome.stats.clauses)
        }
        return proved
    }
}

extension Verifier {
    /// Plan item L5, decision 6: a function with a class parameter accesses the object's fields with runtime
    /// exclusivity checks, and a caller may hold an access to the same object, which would make them trap. Logic does
    /// not know what callers hold, so a proof of such a function is `undecided`; a counterexample is still reported.
    static func heldByCaller(_ report: FunctionReport, module: SILModule) -> FunctionReport {
        guard report.status == .safe || report.status == .contractHolds,
            (try? module.function(report.symbol))?.objectParameter != nil
        else { return report }
        var undecided = report
        undecided.status = .undecided
        undecided.category = "exclusivity"
        undecided.detail = "proved, assuming no caller holds an access to the object's fields while it runs"
        undecided.hint = hint(forCategory: "exclusivity")
        undecided.usesContracts = nil
        return undecided
    }
}
