package import Foundation

/// What `swift package dump-package` says about one package: its local (`path:`) dependencies and its targets.
package struct PackageManifest: Equatable, Sendable {
    package struct Target: Equatable, Sendable {
        package var name: String
        /// The source folder, absolute.
        package var path: String
        /// `regular`, `executable`, `test`, `macro`, `plugin`, …
        package var type: String
    }

    package var root: String
    /// Packages this one depends on by path, absolute and standardized.
    package var localDependencies: [String]
    /// True when it also depends on a package by URL (pinned in `Package.resolved`).
    package var hasRemoteDependencies: Bool
    package var targets: [Target]

    /// Reads `swift package dump-package` output for the package in `root`.
    package static func parse(_ data: Data, root: String) throws -> PackageManifest {
        let json = try JSONDecoder().decode(JSONValue.self, from: data)
        var local: [String] = []
        var remote = false
        for dependency in json["dependencies"].array ?? [] {
            if let fileSystem = dependency["fileSystem"].array {
                local += fileSystem.compactMap { $0["path"].string.map(Paths.standard) }
            } else {
                remote = true
            }
        }
        let targets = (json["targets"].array ?? []).compactMap { target -> Target? in
            guard let name = target["name"].string else { return nil }
            let type = target["type"].string ?? "regular"
            let folder = type == "test" ? "Tests" : (type == "plugin" ? "Plugins" : "Sources")
            let relative = target["path"].string ?? "\(folder)/\(name)"
            return Target(name: name, path: Paths.standard(relative.hasPrefix("/") ? relative : root + "/" + relative), type: type)
        }
        return PackageManifest(root: Paths.standard(root), localDependencies: local, hasRemoteDependencies: remote, targets: targets)
    }

    /// The target whose folder holds `file` (the deepest one), skipping tests unless `tests`.
    package func target(containing file: String, tests: Bool = false) -> Target? {
        targets.filter { (tests || $0.type != "test") && Paths.isInside(file, $0.path) }.max { $0.path.count < $1.path.count }
    }
}

/// Local packages and how they depend on each other: which packages' files a check of one package reads.
package struct PackageGraph: Sendable {
    package private(set) var manifests: [String: PackageManifest] = [:]

    package init(_ manifests: [PackageManifest] = []) {
        for manifest in manifests { self.manifests[manifest.root] = manifest }
    }

    package mutating func add(_ manifest: PackageManifest) { manifests[manifest.root] = manifest }

    package mutating func remove(_ root: String) { manifests[root] = nil }

    /// `root` and every package it reaches by path, or nil when a package on the way is not known.
    package func closure(of root: String) -> Set<String>? {
        var seen: Set<String> = []
        var stack = [root]
        while let next = stack.popLast() {
            guard seen.insert(next).inserted else { continue }
            guard let manifest = manifests[next] else { return nil }
            stack += manifest.localDependencies
        }
        return seen
    }

    /// Packages reached from `root` that are not known yet (to read with `dump-package`).
    package func missing(from roots: [String]) -> [String] {
        var seen: Set<String> = []
        var stack = roots
        var missing: [String] = []
        while let next = stack.popLast() {
            guard seen.insert(next).inserted else { continue }
            if let manifest = manifests[next] { stack += manifest.localDependencies } else { missing.append(next) }
        }
        return missing
    }
}
