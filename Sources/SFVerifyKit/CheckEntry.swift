import Foundation

public struct CheckEntry: Codable, Sendable {
    public struct WalkResult: Codable, Sendable {
        public var walk: WalkCheck
        public var records: [WalkRecord]
        public var knownIssue: Bool
        /// True when the walk's subject names only the function's type (a walk over a whole reducer): a failure it finds
        /// is not blamed on this member. Absent otherwise.
        public var wholeType: Bool?  // swiftlint:disable:this discouraged_optional_boolean
    }

    public enum Outcome: String, Codable, Sendable {
        /// Logic proved the contract for every input, and every linked walk proved its own promises over its whole domain.
        case provedByLogic
        /// Logic proved it cannot trap, and every linked walk that names it proved its promises over its whole domain.
        case provedByLogicAndWalk
        /// Every linked walk that names it proved its promises over its whole domain: the inputs the walk lists, not every
        /// input. A walk over its whole type never counts.
        case provedByWalk
        /// Walks found no failing input, but did not cover the whole domain.
        case bounded
        /// Logic proved it cannot trap; no walk states other promises.
        case cannotTrap
        /// Logic or a walk found an input that breaks a promise.
        case counterexample
        /// A walk found a failing input, and the test marks it as a known issue.
        case knownIssue
        /// A walk that names it found a failing input marked as a known issue, and another walk that names it proved
        /// its promises: neither wins, the report shows both.
        case conflict
        /// Only a walk over its whole type found a failing input: which member is at fault is not known, so it is
        /// neither broken nor proved by that walk.
        case typeWalkFailed
        /// A linked walk ran but wrote no result (its test was filtered out, or did not reach its `Prove`).
        case walkMissing
        /// Neither engine says anything about this function.
        case unchecked
    }

    public var module: String
    public var package: String?  // the package directory as given to `--scan`, when the caller named it
    public var function: FunctionReport
    public var walks: [WalkResult]
}

extension CheckEntry {
    /// The verdict of the function, logic first. A walk that names the function and fails (not a known issue) always
    /// wins; a known issue there yields to no proof but does not outweigh one either (`conflict`); a failure found by a
    /// walk over the whole type is not blamed on this member (`typeWalkFailed`), and no proof is taken from that walk
    /// (app study round 6, L18). A contract that holds does not stand in for a walk: the walk may state another promise
    /// (a table, injectivity), so it decides as it does for a function that cannot trap.
    public var outcome: Outcome {
        switch function.status {
        case .contractFails, .mayTrap: return .counterexample
        case .contractHolds:
            let walked = walkOutcome(logicProvedNoTrap: true)
            return [.cannotTrap, .provedByLogicAndWalk].contains(walked) ? .provedByLogic : walked
        default: return walkOutcome(logicProvedNoTrap: function.status == .safe)
        }
    }

    private func walkOutcome(logicProvedNoTrap: Bool) -> Outcome {
        guard !walks.isEmpty else { return logicProvedNoTrap ? .cannotTrap : .unchecked }
        func failed(_ walk: WalkResult) -> Bool { walk.records.contains { $0.verdict == "failed" } }
        func proved(_ walk: WalkResult) -> Bool { !walk.records.isEmpty && walk.records.allSatisfy { $0.verdict == "proved" } }
        let named = walks.filter { $0.wholeType != true }
        if named.contains(where: { failed($0) && !$0.knownIssue }) { return .counterexample }
        if named.contains(where: failed) { return named.contains(where: proved) ? .conflict : .knownIssue }
        // A walk over the whole type does not show that it calls this member, so it proves nothing about it (app
        // study round 7); its failure is reported on the walk.
        let typeWalkFailed = walks.contains { $0.wholeType == true && failed($0) }
        guard !named.isEmpty else { return typeWalkFailed ? .typeWalkFailed : logicProvedNoTrap ? .cannotTrap : .unchecked }
        if named.contains(where: \.records.isEmpty) { return .walkMissing }
        if typeWalkFailed, !named.contains(where: proved) { return .typeWalkFailed }
        if named.allSatisfy(proved) { return logicProvedNoTrap ? .provedByLogicAndWalk : .provedByWalk }
        return .bounded
    }

    /// A walk that names the function found a failing input that no test marks as a known issue.
    var namedWalkFailedUnmarked: Bool {
        walks.contains { $0.wholeType != true && !$0.knownIssue && $0.records.contains { $0.verdict == "failed" } }
    }

    /// A walk over the whole type found a failing input that no test marks as a known issue.
    var typeWalkFailedUnmarked: Bool {
        walks.contains { $0.wholeType == true && !$0.knownIssue && $0.records.contains { $0.verdict == "failed" } }
    }
}
