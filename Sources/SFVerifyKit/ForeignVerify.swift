import Foundation
import SFBV
import SFCNF
import SFProve
import SFSIL

/// Counterexamples that rest on what Objective-C calls returned (plan item R6-1, `SILForeign.swift`).
///
/// The main proof reads each foreign result as a fresh value (`ForeignResults` records them), which is sound for `safe`.
/// A counterexample `P` (the parameters) then only says that *some* foreign values make the function trap. A second
/// solve with `P` fixed and the foreign results as its only inputs finds such values `F`; the counterexample is kept
/// when, on `P` and `F`, the claim fails for every result the other summarized calls could give (as `honest` does), and
/// the report lists `F` ("input.index returned 7").
extension Verifier {
    /// The main proof of a function and what decides its verdict.
    struct ProvedClaim {
        var stats: ProofStats
        var verdict: ProofVerdict
        /// Why the verdict is `unknown`, when it is not the budget.
        var reason: String?
        /// For a counterexample that needs foreign results: the values they returned, by key (constant leaves).
        var foreignResults: [String: [BV]]?
        /// The summarized calls whose results the encoding left unknown (`honest`).
        var approximations: Set<String>
        /// No summarized call's result was left unknown: other trap sites may be searched (`moreTraps`).
        var exact: Bool { approximations.isEmpty }
    }

    /// Proves `claim` over parameters of `widths` with the foreign results recorded, then decides a counterexample:
    /// with foreign results by reading back what they returned, otherwise with `honest`.
    static func proveClaim(widths: [Int], budget: Int, claim: Claim) throws -> ProvedClaim {
        var approximations: Set<String> = []
        let foreign = ForeignResults()
        let outcome = try ForeignResults.$current.withValue(foreign) {
            try proveReporting(inputWidths: widths, conflictBudget: budget) { c, inputs in
                let (literal, used) = try claim(c, inputs)
                approximations.formUnion(used)
                return literal
            }
        }
        var proved = ProvedClaim(stats: outcome.stats, verdict: outcome.verdict, approximations: approximations)
        guard !foreign.distinct.isEmpty, case .counterexample(let values) = outcome.verdict else {
            (proved.verdict, proved.reason) = try honest(
                outcome.verdict, approximations: approximations, widths: widths, budget: budget, claim: claim)
            return proved
        }
        (proved.foreignResults, proved.reason) = try readBack(
            foreign.distinct, parameters: values, widths: widths, budget: budget, claim: claim)
        if proved.foreignResults == nil { proved.verdict = .unknown }
        return proved
    }

    /// The values the foreign results take in a run on the parameters `values` that makes the claim fail, by key, when
    /// the claim then fails whatever the other summarized calls return; otherwise nil and the reason.
    private static func readBack(
        _ foreign: [ForeignResults.Result], parameters values: [UInt64], widths: [Int], budget: Int, claim: Claim
    ) throws -> ([String: [BV]]?, String?) {
        let foreignWidths = foreign.map(\.type.leafWidths)
        func supply(_ leaves: [BV]) -> [String: [BV]] {
            var offset = 0
            var supplied: [String: [BV]] = [:]
            for (result, widths) in zip(foreign, foreignWidths) {
                supplied[result.key] = Array(leaves[offset..<(offset + widths.count)])
                offset += widths.count
            }
            return supplied
        }
        var remaining: Set<String> = []
        let readBack = try proveReporting(inputWidths: foreignWidths.flatMap { $0 }, conflictBudget: budget) { c, inputs in
            try ForeignResults.$current.withValue(ForeignResults(supplying: supply(inputs))) {
                let made = try claim(c, zip(widths, values).map { c.constant($1, width: $0) })
                remaining.formUnion(made.approximations)
                return made.literal
            }
        }
        guard case .counterexample(let returned) = readBack.verdict else {
            return (nil, "can fail only for some values Objective-C calls return, and no such values were found")
        }
        let constants = CNFBuilder()
        let fixed = supply(zip(foreignWidths.flatMap { $0 }, returned).map { constants.constant($1, width: $0) })
        if !remaining.isEmpty {
            let check = try proveReporting(inputWidths: [], conflictBudget: budget) { c, _ in
                try ForeignResults.$current.withValue(ForeignResults(supplying: fixed)) {
                    -(try claim(c, zip(widths, values).map { c.constant($1, width: $0) }).literal)
                }
            }
            guard check.verdict == .proved else {
                let names = remaining.sorted().joined(separator: ", ")
                return (nil, "can fail only for some results of \(names); logic does not model what these return")
            }
        }
        // Constant leaves mean the same in every builder: the replay reads them as they are.
        return (fixed, nil)
    }

    /// A refutation whose trap needs the foreign results `returned` (by key): the counterexample lists them, has no
    /// replay (a native call cannot make foreign code return them), and no other trap sites are searched.
    static func refuteWithForeignResults(
        _ report: inout FunctionReport, _ values: [UInt64], _ refuted: RefutedFunction, returned: [String: [BV]]
    ) {
        report.status = report.hasContract ? .contractFails : .mayTrap
        let replay = ForeignResults(supplying: returned, labels: true)
        report.counterexample = ForeignResults.$current.withValue(replay) { refuted.explain(values) }
    }
}

extension ScanCounterexample {
    /// Adds what the foreign calls of a replay returned (`ForeignResults.current`, reached calls only) to `inputs` and
    /// `foreignResults`, and drops the replay. Rendered inside the counterexample's stand-in scope.
    mutating func addForeignResults() {
        guard let results = ForeignResults.current, results.wantsLabels else { return }
        // A replay runs on constants: every leaf and reach condition folded to one, readable in any builder.
        let c = CNFBuilder()
        var lines: [String] = []
        for result in results.made where c.constantValue(BV(bits: [result.reached])) == 1 {
            let leaves = result.leaves.compactMap { c.constantValue($0) }
            guard leaves.count == result.leaves.count, let text = Self.render(result.type, result.typeText, leaves) else { continue }
            lines.append("\(result.label) returned \(text)")
        }
        guard !lines.isEmpty else { return }
        foreignResults = lines
        inputs += lines
        replay = nil
    }

    /// A foreign result as Swift would print it; nil for a non-nil object (its identity says nothing to a reader).
    private static func render(_ type: ValueType, _ declared: String, _ leaves: [UInt64]) -> String? {
        var typeText = declared
        if typeText.hasSuffix("?") { typeText.removeLast() }
        if typeText.hasPrefix("Optional<"), typeText.hasSuffix(">") { typeText = String(typeText.dropFirst(9).dropLast()) }
        switch type {
        case .opaque(let name) where name == "object": return nil
        case .aggregate(_, let fields) where fields.isEmpty: return nil
        case .scalar(let width):
            return Verifier.render(leaves[0], type: width == 1 ? "Bool" : (typeText.isEmpty ? nil : typeText), width: width)
        case .enumeration(let name, let cases) where name.hasPrefix("Optional<") && cases.count == 2:
            guard leaves[0] == 1, let payload = cases[1].payload else { return "nil" }
            return render(payload, typeText, Array(leaves.dropFirst()))
        default: return ValueRenderer.render(type, leaves[...])
        }
    }
}
