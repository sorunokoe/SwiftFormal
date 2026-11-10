import Foundation
import SFSIL

extension Verifier {
    /// A contract logic cannot read is not dropped in silence (round 6, L9), and does not hide a trap (L5).
    /// After a refusal, the function is proved again without its `ensures` (the `requires` kept), then without any
    /// contract. A trap for an input the `requires` allows breaks the contract whatever the `ensures` says, so it is
    /// reported as the contract's failure. Otherwise, when the function alone is readable, the contract is what logic
    /// cannot read: `unsupported` with `contractNotReadCategory` and the reason. When the function alone is refused
    /// too, its own reason stands.
    static func explainUnreadContract(
        _ report: inout FunctionReport, _ info: FunctionInfo, specs: Contract, options: VerifyOptions, in scope: VerifyScope
    ) {
        guard let blocker = specs.ensures ?? specs.requires else { return }
        func readable(_ r: FunctionReport) -> Bool { ![.unsupported, .internalError].contains(r.status) }
        var trapOnly = specs
        trapOnly.ensures = nil
        if specs.ensures != nil {
            let withoutEnsures = verifyUntimed(info, specs: trapOnly, options: options, in: scope, readingContract: false)
            if [.mayTrap, .contractFails].contains(withoutEnsures.status) {
                let reason = Self.reason(report)
                report = withoutEnsures
                report.status = .contractFails
                report.hasContract = true
                report.detail =
                    "the function traps for an input its requires allows, so the contract fails whatever \(blocker.displayName) "
                    + "says; logic cannot read that ensures (\(reason))"
                return
            }
            if readable(withoutEnsures) {
                markNotRead(&report, [blocker], alone: withoutEnsures)
                return
            }
        }
        guard let requires = specs.requires else { return }
        let alone = verifyUntimed(info, specs: Contract(), options: options, in: scope, readingContract: false)
        if readable(alone) { markNotRead(&report, [requires] + [specs.ensures].compactMap { $0 }, alone: alone) }
    }

    /// A function with a `_requires` / `_ensures` named after it that pairs with no function (a wrong shape): its
    /// verdict was reached without that contract, so a proof is not one of the contract (round 6, L9).
    static func notPaired(_ report: FunctionReport, _ specs: [FunctionInfo]) -> FunctionReport {
        guard !specs.isEmpty else { return report }
        var report = report
        let names = specs.map(\.displayName).joined(separator: ", ")
        let why =
            "\(names) is not paired with it: it does not take \(report.name)'s parameters "
            + "(then its result if it returns one, then `old: Self` if it is mutating)"
        report.hasContract = true
        switch report.status {
        case .safe, .contractHolds:
            let alone = report.status == .safe ? "the function itself cannot trap" : "the rest of its contract holds"
            report.status = .unsupported
            report.category = contractNotReadCategory
            report.detail = "\(why); \(alone)"
            report.hint = "give \(names) the parameters of the function it is named after, then its result"
        default:
            report.detail = [report.detail, why].compactMap { $0 }.joined(separator: "; ")
        }
        return report
    }

    private static func markNotRead(_ report: inout FunctionReport, _ specs: [FunctionInfo], alone: FunctionReport) {
        let names = specs.map(\.displayName).joined(separator: ", ")
        let without =
            switch alone.status {
            case .safe: "; the function itself cannot trap"
            case .contractHolds: "; the function cannot trap for an input its requires allows"
            default: ""
            }
        report.detail = "logic cannot read \(names) (\(reason(report)))\(without)"
        report.category = contractNotReadCategory
        report.status = .unsupported
        report.hasContract = true
        report.hint = "write the contract with what logic reads (see the detail), or check the promise with a walk (`Prove`)"
    }

    private static func reason(_ report: FunctionReport) -> String {
        let detail = report.detail?.replacingOccurrences(of: "UNSUPPORTED: ", with: "")
        let reason = [report.category, detail].compactMap { $0 }.joined(separator: ": ")
        return reason.isEmpty ? "unsupported" : reason
    }
}
