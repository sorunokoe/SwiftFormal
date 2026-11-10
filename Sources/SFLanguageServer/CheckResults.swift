package import Foundation
package import SFVerifyKit

/// The `swiftformal check --json` report, as the server reads it. Every verdict field decodes into the CLI's own
/// enums, so a value this server does not know fails the whole read: an unknown answer is never shown as proved.
package struct CheckResults: Decodable, Sendable {
    /// One function's verdict (the CLI's `JSONEntry`).
    package struct Entry: Decodable, Sendable {
        package var module: String
        /// The package directory as given to `--scan`; absent in reports of older versions.
        package var package: String?
        package var function: String
        package var location: SourceLocation?
        package var logic: ScanStatus
        package var outcome: CheckEntry.Outcome
        package var counterexample: ScanCounterexample?
        package var walks: [CheckEntry.WalkResult]
        package var category: String?
        package var detail: String?
        package var hint: String?
        package var at: SourceLocation?
        package var proofScope: String?
        package var origin: String?
        /// Hand-written `f_requires` / `f_ensures` that logic does not read; absent when there are none.
        package var ignoredContracts: [String]?
    }

    package enum ReadError: Error, CustomStringConvertible {
        case schemaVersion(Int)

        package var description: String {
            switch self {
            case .schemaVersion(let v): "check --json schemaVersion \(v) is not the 1 this server reads"
            }
        }
    }

    package var schemaVersion: Int
    package var entries: [Entry]
    package var modules: [CheckReport.Module]?

    /// Reads a report; fails on a schema version other than 1.
    package static func read(_ data: Data) throws -> CheckResults {
        let results = try JSONDecoder().decode(CheckResults.self, from: data)
        guard results.schemaVersion == 1 else { throw ReadError.schemaVersion(results.schemaVersion) }
        return results
    }
}

extension CheckResults.Entry {
    /// The outcome after checking it against the facts it was derived from: one that claims a proof the logic status
    /// and walk records do not support is `unchecked`. (The CLI derives the outcome the same way; this guards against
    /// a report from another version or a damaged file.)
    package var checkedOutcome: CheckEntry.Outcome {
        switch outcome {
        case .provedByLogic: return logic == .contractHolds ? outcome : .unchecked
        case .cannotTrap: return logic == .safe ? outcome : .unchecked
        case .provedByLogicAndWalk: return logic == .safe && walksProved ? outcome : .unchecked
        case .provedByWalk: return walksProved ? outcome : .unchecked
        case .counterexample, .knownIssue, .conflict, .typeWalkFailed, .walkMissing, .bounded, .unchecked: return outcome
        }
    }

    /// The walks prove the function as the CLI decides it: at least one walk names the function, and every walk that
    /// names it reported and proved its promises. A walk over the whole type proves no member (app study round 7), so it
    /// neither counts nor, when it fails, undoes the proof of a walk that names the function.
    private var walksProved: Bool {
        func proved(_ walk: CheckEntry.WalkResult) -> Bool { !walk.records.isEmpty && walk.records.allSatisfy { $0.verdict == "proved" } }
        let named = walks.filter { $0.wholeType != true }
        return !named.isEmpty && named.allSatisfy(proved)
    }

    /// A walk over the function's whole type failed and no test marks it as a known issue: what fails the CLI's run.
    package var typeWalkFailedUnmarked: Bool {
        walks.contains { $0.wholeType == true && !$0.knownIssue && $0.records.contains { $0.verdict == "failed" } }
    }

    /// True when the walks' outcome decides the verdict, so a change to the tests can change it. Only a contract logic
    /// proved, or a failing input logic found, is final without them: walks are not run for those.
    package var dependsOnWalks: Bool {
        ![.contractHolds, .contractFails, .mayTrap].contains(logic)
    }
}
