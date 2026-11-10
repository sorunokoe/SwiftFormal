/// How much work a walk may do before it stops enumerating and samples instead.
public struct Budget: Sendable {
    /// The most inputs a walk evaluates before it samples instead. Must stay positive, also when changed after creation.
    public var maxEvaluations: Int {
        didSet { precondition(maxEvaluations > 0, "Budget.maxEvaluations must be positive") }
    }
    /// The seed for sampling, so a sampled run reproduces exactly.
    public var seed: UInt64

    /// Creates a budget. `maxEvaluations` must be positive.
    public init(maxEvaluations: Int = 1_000_000, seed: UInt64 = 0x5F0F_A117) {
        precondition(maxEvaluations > 0, "Budget.maxEvaluations must be positive")
        self.maxEvaluations = maxEvaluations
        self.seed = seed
    }

    /// One million evaluations and a fixed seed.
    public static let `default` = Budget()
}

/// The result for one property. A `proved` verdict means every input of a complete domain was checked.
public enum Verdict: Equatable, Sendable {
    /// Held for every input of the complete domain.
    case proved(checked: Int)
    /// Held for every input that was checked, but the checked inputs are not the whole space.
    case bounded(checked: Int, reason: String)
    /// Failed. The input is the real input, so it can be replayed on the real function.
    case counterexample(Counterexample)

    /// Whether the property held for every input of a complete domain.
    public var isProved: Bool {
        if case .proved = self { return true }
        return false
    }

    /// Whether the property failed for some input.
    public var isCounterexample: Bool {
        if case .counterexample = self { return true }
        return false
    }
}

/// An input that makes a property fail, as text.
public struct Counterexample: Equatable, Sendable {
    /// `nil` for failures that are not tied to one input, such as an output that is never produced.
    public let input: String?
    /// Why the property failed.
    public let detail: String

    /// A failure on `input`, or on no single input when it is `nil`.
    package init(input: String?, detail: String) {
        self.input = input
        self.detail = detail
    }
}

/// A property name with its verdict.
public struct PropertyResult: Sendable {
    /// The name shown in reports.
    public let name: String
    /// The verdict for this property.
    public let verdict: Verdict

    /// The verdict of the property named `name`.
    package init(name: String, verdict: Verdict) {
        self.name = name
        self.verdict = verdict
    }
}

/// Outcome of one walk: a `Prove` or a `verify_<name>()`.
public struct Report: Sendable, CustomStringConvertible {
    /// The name of what was walked: the subject of the `Prove`, or the function `@Verify` marks.
    public let subject: String
    /// The number of values in the domain, saturating at `Int.max`.
    public let domainSize: Int
    /// Whether the domain lists every possible value.
    public let domainComplete: Bool
    /// The number of inputs the function was called with.
    public let evaluated: Int
    /// Inputs left out by `assuming` / `#requires`. They are outside the verified contract.
    public let excluded: Int
    /// One result per property, in the order they were written.
    public let results: [PropertyResult]

    /// A report of a walk. `results` must not be empty for a walk that ran: with no result, `isProved` is true.
    package init(
        subject: String, domainSize: Int, domainComplete: Bool, evaluated: Int, excluded: Int, results: [PropertyResult]
    ) {
        self.subject = subject
        self.domainSize = domainSize
        self.domainComplete = domainComplete
        self.evaluated = evaluated
        self.excluded = excluded
        self.results = results
    }

    /// Every property is proved over a complete domain.
    public var isProved: Bool { results.allSatisfy { $0.verdict.isProved } }

    /// No property has a counterexample. Bounded results still count as passing here.
    public var hasNoCounterexample: Bool { !results.contains { $0.verdict.isCounterexample } }

    /// Every failed property with its counterexample.
    public var counterexamples: [(property: String, counterexample: Counterexample)] {
        results.compactMap {
            if case let .counterexample(example) = $0.verdict { ($0.name, example) } else { nil }
        }
    }

    /// A multi-line summary of the verdicts.
    public var description: String {
        let domain = domainSize == Int.max ? "more than 2^63" : "\(domainSize)"
        var lines = ["verify \(subject): \(evaluated) of \(domain) inputs\(domainComplete ? "" : " (not the whole domain)")"]
        if excluded > 0 { lines[0] += ", \(excluded) outside #requires" }
        for result in results {
            switch result.verdict {
            case let .proved(checked):
                lines.append("  proved       \(result.name) (\(checked) inputs)")
            case let .bounded(checked, reason):
                lines.append("  bounded      \(result.name) (\(checked) inputs; \(reason))")
            case let .counterexample(example):
                let input = example.input.map { " for input \($0)" } ?? ""
                lines.append("  FAILED       \(result.name)\(input): \(example.detail)")
            }
        }
        return lines.joined(separator: "\n")
    }
}
