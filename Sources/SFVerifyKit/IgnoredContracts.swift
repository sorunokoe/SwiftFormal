import Foundation

/// Only `@Verify`: what Scan says about a contract it does not read.
extension FunctionReport {
    /// What to do about a contract Scan does not read (a hand-written one, a `// sf:verify` marker).
    package static let inPlaceAdvice = "write the contract in place with @Verify, #requires and #ensures"

    /// `clamp_ensures(_:_:) is written by hand, …`: why `ignoredContracts` were not checked; nil without any.
    package var ignoredContractMessage: String? { Self.ignoredContractMessage(ignoredContracts ?? []) }

    /// Why the hand-written contract functions `ignored` were not checked; nil when there are none.
    package static func ignoredContractMessage(_ ignored: [String]) -> String? {
        guard !ignored.isEmpty else { return nil }
        return "\(ignored.joined(separator: " and ")) \(ignored.count == 1 ? "is" : "are") written by hand, and Scan reads "
            + "only the contract @Verify writes: \(inPlaceAdvice)"
    }
}
