import Foundation

/// The builds this process ran itself (`plan(root:target:)`, `buildPackage`), per scratch folder: which build
/// description each used. Only a run that built may read Swift Build's plan of a description
/// (`SwiftPMDescribedCommand.swift`), and only while that description is still the folder's last one.
///
/// Swift Build appends a description's id to `prior-build-descriptions.txt` whenever a build in the folder uses another
/// description than the build before it, so the file stays the same exactly as long as every build since used the same
/// description. Its status is taken as soon as the build process has exited and every command is read before it is
/// compared again: another `swift build` would have had to take SwiftPM's lock, load the package and plan it in the
/// moment between our build's exit and that first look, which takes far longer. A dependency's command is in addition
/// read only from a plan that holds the scanned target's command exactly as the scan uses it.
extension SwiftPMBuild {
    package struct OwnBuild: Sendable {
        package let description: String
        let status: FileStatus
        /// The target planned from this build last, with the command its plan used.
        var target: PlannedTarget?

        /// Whether no build with another description ran in the folder since.
        func isCurrent(in scratch: String) -> Bool { FileStatus(descriptionsFile(in: scratch)) == status }
    }

    struct PlannedTarget: Sendable {
        var name: String
        var tool: String
        var arguments: [String]
    }

    private final class OwnBuilds: @unchecked Sendable {
        let lock = NSLock()
        var builds: [String: OwnBuild] = [:]
    }

    private static let ownBuilds = OwnBuilds()

    static func descriptionsFile(in scratch: String) -> String {
        scratch + "/out/Intermediates.noindex/XCBuildData/prior-build-descriptions.txt"
    }

    /// Records the description of the build this process has just run in `scratch`; nil (and nothing recorded, so
    /// that no earlier build's stays) when it cannot be read while the file stays the same.
    @discardableResult
    package static func recordOwnBuild(in scratch: String) -> OwnBuild? {
        let path = descriptionsFile(in: scratch)
        var build: OwnBuild?
        if let status = FileStatus(path), let description = buildDescription(in: scratch), FileStatus(path) == status {
            build = OwnBuild(description: description, status: status)
        }
        ownBuilds.lock.lock()
        ownBuilds.builds[scratch] = build
        ownBuilds.lock.unlock()
        return build
    }

    /// The description of this process's last build in `scratch`, while no other build has run there since.
    static func ownDescription(in scratch: String) -> String? {
        ownBuild(in: scratch).flatMap { $0.isCurrent(in: scratch) ? $0.description : nil }
    }

    /// The last build this process ran in `scratch`, when one was recorded.
    static func ownBuild(in scratch: String) -> OwnBuild? {
        ownBuilds.lock.lock()
        defer { ownBuilds.lock.unlock() }
        return ownBuilds.builds[scratch]
    }

    /// Records the command a target's plan used, from the last build in `scratch`: its dependencies are then read only
    /// from a plan that holds this command.
    package static func recordTarget(_ target: String, tool: String, arguments: [String], in scratch: String) {
        ownBuilds.lock.lock()
        ownBuilds.builds[scratch]?.target = PlannedTarget(name: target, tool: tool, arguments: arguments)
        ownBuilds.lock.unlock()
    }
}
