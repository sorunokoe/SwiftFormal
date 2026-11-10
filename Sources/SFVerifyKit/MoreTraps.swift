import SFBV
import SFCNF
import SFProve
import SFSIL

/// What explaining a counterexample of one function needs.
struct RefutedFunction {
    let info: FunctionInfo
    let function: SILFunction
    let module: SILModule
    let specs: Contract
    let functions: [String: FunctionInfo]

    /// `replaysMethods`: also write a replay for a method or getter (`Verifier.methodReplay`), which may run a proof.
    func explain(_ values: [UInt64], skipping: Set<String> = [], replaysMethods: Bool = true) -> ScanCounterexample {
        Verifier.explain(
            values, info: info, function: function, module: module, specs: specs, functions: functions, skipping: skipping,
            replaysMethods: replaysMethods)
    }

    func firedSite(_ values: [UInt64], skipping: Set<String>) -> String? {
        Verifier.firedSite(values, symbol: info.symbol, function: function, module: module, skipping: skipping)
    }
}

extension Verifier {
    /// Plan item H3: after a function is refuted at one trap site, the other sites that can trap, each with its own
    /// input. Each extra solve asks for an input on which a site not yet reported traps; the answer is a model of the
    /// formula, replayed on constants by `explain` like the first counterexample. Nothing is proved here, so the
    /// trusted checker is not involved. Only for exact encodings (no summarized call): a counterexample that rests on an
    /// unknown summary result could otherwise be reported. At most `limit` extra sites; a budget-out stops the search.
    static func moreTraps(first values: [UInt64], of refuted: RefutedFunction, budget: Int, limit: Int = 4) -> [ScanCounterexample] {
        let (info, function, module) = (refuted.info, refuted.function, refuted.module)
        guard let firstSite = refuted.firedSite(values, skipping: []) else { return [] }
        var seen: Set<String> = [firstSite]
        var found: [ScanCounterexample] = []
        while found.count < limit {
            var exact = true
            let outcome = try? proveReporting(inputWidths: function.parameterWidths, conflictBudget: budget) { c, inputs in
                let f = try SILEncoder(module: module, builder: c).encode(symbol: info.symbol, arguments: inputs)
                exact = exact && f.approximations.isEmpty
                var fires = c.falseLit
                for site in f.trapSites where !seen.contains(site.kind.key) { fires = c.or(fires, site.condition) }
                return c.or(-function.inputAssumption(c, inputs), -fires)
            }
            guard exact, case .counterexample(let next)? = outcome?.verdict,
                let site = refuted.firedSite(next, skipping: seen)
            else { break }
            found.append(refuted.explain(next, skipping: seen, replaysMethods: false))
            seen.insert(site)
        }
        return found
    }
}
