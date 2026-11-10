import Foundation

// What logic concluded about a walk's relational claim (`RelationalProofs.swift`), as `check` lays it over the walk
// (`RelationalWalks.swift`).

/// What logic concluded about a `RelationalRequest`, for every value of the input type.
public struct RelationalResult: Codable, Sendable, Equatable {
    public enum Verdict: String, Codable, Sendable {
        case proved
        /// A counterexample: `inputs` and `detail` say what goes wrong.
        case refuted
        /// Not read, or not decided: `detail` says why. The walk's verdict stands.
        case unknown
    }

    public var request: RelationalRequest
    public var verdict: Verdict
    /// The counterexample's inputs (`a = Seat(row: 0, number: 128), b = Seat(row: 1, number: 0)`).
    public var inputs: String?
    /// What goes wrong at `inputs`, or why the claim is unknown.
    public var detail: String?
    /// What the proof took on trust (`FunctionReport.assumptions`).
    public var assumptions: [String]?
    /// The type the rule takes, as `String(reflecting:)` prints it (`MainApp.Seat`, `Swift.Optional<MainApp.Seat>`); nil
    /// when it is not known (`RelationalInputType.swift`). A closure `{ $0.code }` names no type, so logic may have read
    /// another type's `code`; a closure `{ f($0) }` over `Seat` may call an `f` that takes `Seat?`. The result is laid
    /// over a walk only when this is the walk's input type.
    public var inputType: String?
    /// Set on an unknown result of a scan in which no function matches the chain: it says nothing about the claim.
    public var unresolved: Unresolved?

    /// Why a scan says nothing about a claim.
    public enum Unresolved: String, Codable, Sendable {
        /// No scanned function matches a step of the chain.
        case noMatchingFunction
    }

    public init(
        request: RelationalRequest, verdict: Verdict, inputs: String? = nil, detail: String? = nil, assumptions: [String]? = nil
    ) {
        self.request = request
        self.verdict = verdict
        self.inputs = inputs
        self.detail = detail
        self.assumptions = assumptions
    }

    /// Of the results of one request in two configurations (debug and release): a counterexample in either, else the
    /// first that is not a proof, else the proof with the assumptions of both.
    static func worse(_ a: RelationalResult, _ b: RelationalResult) -> RelationalResult {
        if a.verdict == .refuted { return a }
        if b.verdict == .refuted { return b }
        // An unknown that read the rule in either configuration is not one that found nothing.
        if a.verdict == .unknown || b.verdict == .unknown {
            var unknown = a.verdict == .unknown && a.unresolved == nil ? a : b.verdict == .unknown ? b : a
            if a.unresolved == nil || b.unresolved == nil { unknown.unresolved = nil }
            return unknown
        }
        var proved = a
        let all = Set(a.assumptions ?? []).union(b.assumptions ?? []).sorted()
        proved.assumptions = all.isEmpty ? nil : all
        return proved
    }
}

/// A claim that logic does not read, with the reason.
struct RelationalRefusal: Error {
    let reason: String
    /// No scanned function matches a step of the chain: this scan says nothing about the claim.
    var unresolved = false
}
