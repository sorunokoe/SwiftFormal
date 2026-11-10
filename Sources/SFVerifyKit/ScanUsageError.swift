/// A mistake in what Scan was asked to read (a target that does not exist, no target picked), as opposed to code it
/// could not read. Printed as it is, never as "INVALID SIL" or "COMPILER FAILED" (plan item U10).
public struct ScanUsageError: Error, CustomStringConvertible, Sendable {
    public let description: String

    public init(_ description: String) { self.description = description }

    /// `no target 'Bogus' in <root>; its targets under Sources/ are: A, B`.
    static func unknownTarget(_ target: String, root: String, known: [String]) -> ScanUsageError {
        let list = known.isEmpty ? "" : "; its targets under Sources/ are: " + known.sorted().joined(separator: ", ")
        return ScanUsageError("no target '\(target)' in \(root)\(list)")
    }

    /// A build log without the compile command of `target` (the build compiled nothing), and no command saved for
    /// that build (plan item K5).
    static func upToDate(_ target: String) -> ScanUsageError {
        ScanUsageError(
            "the build log has no compile command for \(target): the build had nothing to compile, and no command was saved "
                + "for this build. Change or touch a file of \(target) (for example `touch Sources/\(target)/*.swift`) and run "
                + "again; the command is then saved for the next builds that compile nothing")
    }
}
