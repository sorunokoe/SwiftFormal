import Foundation
import SFProve
import SFSIL

extension Verifier {
    /// An `ensures` that reads what logic does not model (an array element, string contents) leaves the whole contract
    /// undecided, although the function may trap whatever those calls return (app study round 6, L5: an index out of range
    /// hidden behind an ensures on the element). The claim is proved again without the ensures, the `requires` kept: a
    /// counterexample that passes `honest` traps for every result of the unmodelled calls, so it breaks the contract
    /// too, and is reported as its failure. Returns false when no such trap is found (the verdict stays undecided).
    static func refuteTrapUnderUndecidedEnsures(
        _ report: inout FunctionReport, _ subject: RefutedFunction, _ undecided: String, _ options: VerifyOptions
    ) throws -> Bool {
        var trapOnly = subject.specs
        trapOnly.ensures = nil
        let (info, module) = (subject.info, subject.module)
        let proved = try proveClaim(widths: subject.function.parameterWidths, budget: options.conflictBudget) { c, inputs in
            let made = try claim(c, inputs, info: info, module: module, specs: trapOnly)
            return (made.literal, made.approximations)
        }
        guard case .counterexample(let values) = proved.verdict else { return false }
        let refuted = RefutedFunction(
            info: info, function: subject.function, module: module, specs: trapOnly, functions: subject.functions)
        if let returned = proved.foreignResults {
            refuteWithForeignResults(&report, values, refuted, returned: returned)
        } else {
            refute(&report, values, refuted, exact: proved.exact, options: options)
        }
        report.detail = "the function traps before its ensures matters; the ensures alone is undecided: \(undecided)"
        return true
    }
}
