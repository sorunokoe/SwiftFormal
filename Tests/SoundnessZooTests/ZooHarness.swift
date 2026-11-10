import SFBV
import SFProve
import SwiftFormal
import Testing

/// The soundness zoo: claims whose truth is known in advance, put to the tools.
///
/// The rule every case enforces (docs/TRUST.md): a wrong claim may be refuted, or left unresolved when the budget runs
/// out, but must never be called `proved`; a refutation must be a real failure, replayed here on plain Swift.

/// What a claim really is.
enum Truth: Sendable {
    /// Wrong. The tool must refute it, with an input that fails again when replayed on real Swift.
    case falseClaim
    /// Right. The tool must prove it.
    case trueClaim
    /// Wrong, but the budget may stop the tool first: refuting (with a real replay) or giving up are both fine; proving is a soundness bug.
    case falseClaimBeyondBudget
    /// Right, but the budget may stop the tool first: proving or giving up are both fine; refuting is a soundness bug.
    case trueClaimBeyondBudget
}

/// What a tool answered, reduced to what a soundness check needs.
enum ToolAnswer: Sendable, Equatable {
    case proved
    /// `replays` is whether the reported input really fails when the claim is evaluated again outside the tool.
    case refuted(replays: Bool)
    case inconclusive(String)
}

/// One claim, one tool, one known truth.
struct ZooCase: Sendable, CustomTestStringConvertible {
    let name: String
    let truth: Truth
    let run: @Sendable () throws -> ToolAnswer

    var testDescription: String { name }
}

/// Returns why `answer` is unacceptable for a claim of this `truth`, or nil if it is acceptable.
func judge(_ truth: Truth, _ answer: ToolAnswer) -> String? {
    switch (truth, answer) {
    case (.falseClaim, .refuted(replays: true)), (.trueClaim, .proved),
        (.falseClaimBeyondBudget, .refuted(replays: true)), (.falseClaimBeyondBudget, .inconclusive),
        (.trueClaimBeyondBudget, .proved), (.trueClaimBeyondBudget, .inconclusive):
        return nil
    case (.falseClaim, .proved), (.falseClaimBeyondBudget, .proved):
        return "UNSOUND: a wrong claim was called proved"
    case (.trueClaim, .refuted), (.trueClaimBeyondBudget, .refuted):
        return "UNSOUND or incomplete: a true claim was refuted"
    case (_, .refuted(replays: false)):
        return "the counterexample does not fail when replayed on real Swift"
    case (.falseClaim, .inconclusive(let why)):
        return "a wrong claim was not refuted: \(why)"
    case (.trueClaim, .inconclusive(let why)):
        return "a true claim was not proved: \(why)"
    }
}

/// Records the values a property saw fail, so the case can replay them. Touched only by the single-threaded walk.
final class Seen<Value>: @unchecked Sendable {
    var values: [Value] = []
}

/// Walk: `claim` must hold for every value of `domain`.
func walk<Input: Sendable>(
    _ name: String,
    _ truth: Truth,
    over domain: Domain<Input>,
    budget: Budget = .default,
    holds claim: @escaping @Sendable (Input) -> Bool
) -> ZooCase {
    ZooCase(name: "Walk: \(name)", truth: truth) {
        let seen = Seen<Input>()
        let report = runWalk(name, claim, over: domain, budget: budget) {
            Property.satisfies("the claim holds") { input, holds in
                if !holds { seen.values.append(input) }
                return holds
            }
        }
        if report.isProved { return .proved }
        guard let reported = report.counterexamples.first?.counterexample.input else {
            return .inconclusive(report.description)
        }
        guard let failing = seen.values.first else { return .refuted(replays: false) }
        return .refuted(replays: "\(failing)" == reported && !claim(failing))
    }
}

/// Prove (`proveSigned`): for the signed 32-bit inputs that meet `requires`, no trap and `claim` holds.
/// `misbehaves` is the same statement written by hand on `Int32` with checked arithmetic: it says whether real Swift
/// traps or fails the claim on the reported inputs.
func signed(
    _ name: String,
    _ truth: Truth,
    widths: [Int] = [32, 32],
    conflictBudget: Int = 1_000_000,
    requires: (@Sendable ([SymbolicInt]) -> SymbolicBool)? = nil,
    claim: @escaping @Sendable ([SymbolicInt]) -> SymbolicBool,
    misbehaves: @escaping @Sendable ([Int32]) -> Bool
) -> ZooCase {
    ZooCase(name: "Prove (signed): \(name)", truth: truth) {
        let verdict = try proveSigned(widths: widths, conflictBudget: conflictBudget, requires: requires, claim: claim)
        switch verdict {
        case .proved:
            return .proved
        case .mayTrap(let values), .claimFails(let values):
            return .refuted(replays: misbehaves(values.map { Int32(truncatingIfNeeded: $0) }))
        case .unknown:
            return .inconclusive("unknown")
        }
    }
}

/// Prove (bit vectors): `claim` is a one-bit literal that must hold for all inputs of the given widths.
/// `fails` evaluates the same claim natively on the reported inputs and says whether it is false there.
func bits(
    _ name: String,
    _ truth: Truth,
    widths: [Int],
    conflictBudget: Int = 1_000_000,
    claim: @escaping @Sendable (CNFBuilder, [BV]) -> Int32,
    fails: @escaping @Sendable ([UInt64]) -> Bool
) -> ZooCase {
    ZooCase(name: "Prove (bits): \(name)", truth: truth) {
        switch try prove(inputWidths: widths, conflictBudget: conflictBudget, claim: claim) {
        case .proved: return .proved
        case .counterexample(let values): return .refuted(replays: fails(values))
        case .unknown: return .inconclusive("unknown")
        }
    }
}
