package import Foundation
package import SFSIL

/// The compiler a scan runs, found once per process and used for every `swiftc` it spawns (plan items K2, K10).
///
/// With `--build`, the `swiftc` that SwiftPM ran wins, so the SIL comes from the compiler that built the code.
/// Otherwise `SWIFT_EXEC`, then `xcrun --find swiftc` (which honours `DEVELOPER_DIR` and `TOOLCHAINS`), then the first
/// `swiftc` on `PATH` where there is no `xcrun` (Linux). One `swiftc -print-target-info` gives the version, compared
/// with the pin (`SILFrontendVersion.verifiedCompilers`: the reader was validated against those compilers only), the
/// target triple and the resource directory.
package struct ScanToolchain: Sendable, Equatable {
    /// Absolute path of `swiftc`.
    package let swiftc: String
    package let toolchain: CompilerToolchain
    /// The compiler's default target, `arm64-apple-macosx27.0.0`: the host's unless the compiler was built otherwise.
    package var triple = ""
    /// `arm64-apple-macosx`: the triple without the OS version, to which a deployment target is appended.
    package var unversionedTriple = ""
    /// `macosx`, `linux`, ...
    package var platform = ""
    /// `<toolchain>/usr/lib/swift`, the compiler's resource directory.
    package var resourceDirectory: String?
    /// The SDK (`xcrun --show-sdk-path`); nil where there is no `xcrun`, and the frontend then uses none.
    package var sdk: String?
    /// How `swiftc` was picked: `SwiftPM build log`, `xcrun (DEVELOPER_DIR=…)`, `SWIFT_EXEC`, `PATH`, ...
    package var origin = "given"
    /// Something the user should know about the choice, for example a `TOOLCHAINS` that names no installed toolchain.
    package var notes: [String] = []

    package init(swiftc: String, toolchain: CompilerToolchain) {
        self.swiftc = swiftc
        self.toolchain = toolchain
    }

    /// First line of `swiftc -version`, as the pin compares it.
    package var versionLine: String { toolchain.versionLine }

    package func isPinned(_ pin: CompilerPin = .verified) -> Bool { pin.accepts(toolchain) }

    /// `<toolchain>/usr`: the directory that holds `bin/swiftc` and `lib/`.
    package var toolchainUsr: String { ((swiftc as NSString).deletingLastPathComponent as NSString).deletingLastPathComponent }

    /// The implicit module cache every compile of this compiler uses (plan item K9); nil when no candidate directory
    /// is writable, and the compile then keeps the arguments it had.
    package var moduleCache: String? { ModuleCacheLocation.directory(versionLine: versionLine) }

    /// One line for a user: which compiler, where, and how it was picked.
    package var description: String { "'\(versionLine)' at \(swiftc) (\(origin))" }

    /// The toolchain of `swiftc` (a path), or of the located compiler when nil. Cached per path.
    package static func resolve(swiftc: String? = nil) throws -> ScanToolchain {
        let located = try swiftc.map { Located(path: $0, origin: "SwiftPM build log") } ?? Locator.current.swiftc()
        if let known = state.withLock({ $0.cache[located.path] }) { return known }
        let answers = try probe(located.path)
        let info = try TargetInfo(json: answers.targetInfo)
        let compiler = CompilerToolchain(swiftcVersion: info.versionOutput, sdkVersion: answers.sdkVersion)
        var found = ScanToolchain(swiftc: located.path, toolchain: compiler)
        found.triple = info.triple
        found.unversionedTriple = info.unversionedTriple
        found.platform = info.platform
        found.resourceDirectory = info.resourceDirectory
        found.sdk = answers.sdkPath
        found.origin = located.origin
        if swiftc == nil, let identity = ToolchainIdentity(swiftc: located.path),
            let note = toolchainsNote(requested: Locator.current.environment["TOOLCHAINS"], picked: identity)
        {
            found.notes.append(note)
        }
        state.withLock { $0.cache[located.path] = found }
        return found
    }

    /// `-print-target-info` of `swiftc` and the SDK `xcrun` selects: from `ToolchainInfoCache` when it has them for this
    /// exact compiler file and environment, else asked and kept there.
    private static func probe(_ swiftc: String) throws -> ToolchainInfoCache.Answers {
        let environment = Locator.current.environment
        let roots = ModuleCacheLocation.roots(option: nil, environment: environment)
        let key = ToolchainInfoCache.key(swiftc: swiftc, environment: environment)
        if let key, let known = ToolchainInfoCache.read(key: key, roots: roots) { return known }
        let probe = try Spawn.run(swiftc, ["-print-target-info"])
        guard probe.status == 0 else {
            let reason = "\(swiftc) -print-target-info exited with \(probe.status): \(probe.errorText.prefix(500))"
            throw ProofCacheError.toolFailed(reason)
        }
        _ = try TargetInfo(json: probe.output)
        let xcrun = Locator.current.hasXcrun
        let answers = ToolchainInfoCache.Answers(
            targetInfo: probe.output,
            sdkVersion: xcrun ? (try? Spawn.xcrunLine(["--show-sdk-version"])) ?? "" : "",
            sdkPath: xcrun ? (try? Spawn.xcrunLine(["--show-sdk-path"])).flatMap { $0.hasPrefix("/") ? $0 : nil } : nil)
        if let key { ToolchainInfoCache.write(answers, key: key, roots: roots) }
        return answers
    }

    /// `swiftc` next to a `swift-frontend` or `swiftc` path found in a build log.
    package static func swiftc(fromBuildTool tool: String) -> String? {
        guard tool.hasPrefix("/") else { return nil }
        let directory = (tool as NSString).deletingLastPathComponent
        let candidate = directory + "/swiftc"
        return FileManager.default.isExecutableFile(atPath: candidate) ? candidate : nil
    }

    /// Why a gate must not pass with this compiler, or nil when it is pinned.
    package func gateRefusal(_ pin: CompilerPin = .verified) -> String? {
        guard !isPinned(pin) else { return nil }
        return "sfverify: error: [sfverify] the compiler '\(versionLine)' (\(swiftc)) is not one this sfverify was validated against "
            + "(\(pin.acceptedVersions.joined(separator: "; "))). The gate fails closed with an unpinned compiler: use a pinned "
            + "Xcode, or update the pin (docs/guides/pin-upgrade.md)."
    }

    /// The warning `sfverify` and `swiftformal check` print for an unpinned compiler, or nil when it is pinned.
    package func warning(_ pin: CompilerPin = .verified) -> String? {
        guard !isPinned(pin) else { return nil }
        return "the compiler '\(versionLine)' is not one this sfverify was validated against "
            + "(\(pin.acceptedVersions.joined(separator: "; "))); verdicts are not covered by docs/TRUST.md"
    }

    /// The compiler every spawn of this process uses: set by `select`, else the located one.
    package static func current() throws -> ScanToolchain {
        try state.withLock { $0.selected } ?? resolve()
    }

    /// Makes `swiftc` (a path; nil: the located compiler) the compiler of every later spawn, and returns it.
    @discardableResult
    package static func select(swiftc: String?) throws -> ScanToolchain {
        let found = try resolve(swiftc: swiftc)
        state.withLock { $0.selected = found }
        return found
    }

    /// `swift <arguments>` of the scan's toolchain: through `xcrun` where there is one (as before), else the `swift`
    /// next to the located `swiftc`.
    package static func swiftCommand(_ arguments: [String]) throws -> (executable: String, arguments: [String]) {
        if Locator.current.hasXcrun { return (Locator.xcrun, ["swift"] + arguments) }
        let next = try current().toolchainUsr + "/bin/swift"
        return (FileManager.default.isExecutableFile(atPath: next) ? next : "/usr/bin/swift", arguments)
    }

    /// Lines for stderr about the compiler of this run: which one was picked, when the environment chose it
    /// (`DEVELOPER_DIR`, `TOOLCHAINS`, `SWIFT_EXEC`, `PATH`), and any note (a `TOOLCHAINS` that names nothing).
    package var explanation: [String] {
        let explicit = origin != "xcrun" && origin != "SwiftPM build log" && origin != "given"
        return (explicit ? ["compiler \(description)"] : []) + notes
    }

    // MARK: state

    private struct State {
        var cache: [String: ScanToolchain] = [:]
        var selected: ScanToolchain?
    }

    private static let state = Guarded(State())
}

extension ScanToolchain {
    /// What `swiftc -print-target-info` says about the compiler.
    package struct TargetInfo: Sendable, Equatable {
        /// `Apple Swift version 6.4 (swiftlang-6.4.0.34.1 clang-2100.3.34.1)`, the first line of `swiftc -version`.
        package var compilerVersion: String
        package var triple: String
        package var unversionedTriple: String
        package var platform: String
        package var resourceDirectory: String?

        package init(json: Data) throws {
            let raw = try JSONDecoder().decode(TargetInfoJSON.self, from: json)
            compilerVersion = raw.compilerVersion
            triple = raw.target.triple
            unversionedTriple = raw.target.unversionedTriple ?? raw.target.triple
            platform = raw.target.platform ?? ""
            resourceDirectory = raw.paths?.runtimeResourcePath
        }

        /// The shape of `swiftc -version`'s stdout (`Apple Swift version …` then `Target: …`), which the pin and the
        /// proof cache's fingerprint read.
        package var versionOutput: String { compilerVersion + "\nTarget: " + triple }
    }

    /// A `swiftc` and how it was found.
    package struct Located: Sendable, Equatable {
        package var path: String
        package var origin: String

        package init(path: String, origin: String) {
            self.path = path
            self.origin = origin
        }
    }

    /// Finds `swiftc` without a SwiftPM build log; the environment and the file system are injected for tests.
    package struct Locator: Sendable {
        static let xcrun = "/usr/bin/xcrun"

        package var environment: [String: String]
        package var hasXcrun: Bool
        package var isExecutable: @Sendable (String) -> Bool
        package var xcrunFind: @Sendable () throws -> String

        package init(
            environment: [String: String], hasXcrun: Bool, isExecutable: @escaping @Sendable (String) -> Bool,
            xcrunFind: @escaping @Sendable () throws -> String
        ) {
            self.environment = environment
            self.hasXcrun = hasXcrun
            self.isExecutable = isExecutable
            self.xcrunFind = xcrunFind
        }

        /// This process: its environment, the real file system and `xcrun`.
        static let current = Locator(
            environment: ProcessInfo.processInfo.environment, hasXcrun: FileManager.default.isExecutableFile(atPath: xcrun),
            isExecutable: { FileManager.default.isExecutableFile(atPath: $0) }, xcrunFind: { try Spawn.xcrunLine(["--find", "swiftc"]) })

        /// `SWIFT_EXEC` (an absolute path), else `xcrun --find swiftc`, else the first `swiftc` on `PATH`.
        package func swiftc() throws -> Located {
            if let exec = environment["SWIFT_EXEC"], exec.hasPrefix("/"), isExecutable(exec) {
                return Located(path: exec, origin: "SWIFT_EXEC")
            }
            if hasXcrun {
                let path = try xcrunFind()
                guard path.hasPrefix("/") else { throw ProofCacheError.toolFailed("xcrun --find swiftc printed '\(path)'") }
                let chosen = ["DEVELOPER_DIR", "TOOLCHAINS"].compactMap { name in environment[name].map { "\(name)=\($0)" } }
                return Located(path: path, origin: chosen.isEmpty ? "xcrun" : "xcrun (\(chosen.joined(separator: ", ")))")
            }
            for directory in (environment["PATH"] ?? "").split(separator: ":") {
                let candidate = String(directory) + "/swiftc"
                if isExecutable(candidate) { return Located(path: candidate, origin: "PATH") }
            }
            throw ProofCacheError.toolFailed("no swiftc found: no xcrun, no SWIFT_EXEC, and none on PATH")
        }
    }

    /// The `.xctoolchain` a `swiftc` belongs to and the names `TOOLCHAINS` may use for it.
    package struct ToolchainIdentity: Sendable, Equatable {
        package var directory: String
        /// Bundle identifier and aliases (`Info.plist`), or the identifier in Xcode's `ToolchainInfo.plist`.
        package var names: [String]

        package init(directory: String, names: [String]) {
            self.directory = directory
            self.names = names
        }

        /// The toolchain that holds `swiftc`, nil when it is not inside an `.xctoolchain`.
        init?(swiftc: String) {
            var directory = (swiftc as NSString).deletingLastPathComponent
            while !directory.hasSuffix(".xctoolchain") {
                guard directory.count > 1 else { return nil }
                directory = (directory as NSString).deletingLastPathComponent
            }
            var names: [String] = []
            for file in ["Info.plist", "ToolchainInfo.plist"] {
                guard let data = FileManager.default.contents(atPath: directory + "/" + file),
                    let plist = try? PropertyListDecoder().decode(ToolchainPlist.self, from: data)
                else { continue }
                names += [plist.CFBundleIdentifier, plist.Identifier].compactMap { $0 } + (plist.Aliases ?? [])
            }
            self.init(directory: directory, names: names)
        }
    }

    /// `xcrun` falls back to the default toolchain, silently, when `TOOLCHAINS` names none installed: say so.
    package static func toolchainsNote(requested: String?, picked: ToolchainIdentity) -> String? {
        guard let requested, !requested.isEmpty else { return nil }
        let wanted = requested.split(whereSeparator: { $0 == " " || $0 == "," || $0 == ":" }).map { $0.lowercased() }
        let names = Set(picked.names.map { $0.lowercased() })
        guard !wanted.contains(where: names.contains) else { return nil }
        return "TOOLCHAINS=\(requested) names no installed toolchain; xcrun used \(picked.directory)"
    }
}

/// The part of `swiftc -print-target-info`'s JSON that `ScanToolchain.TargetInfo` reads.
private struct TargetInfoJSON: Decodable {
    struct Target: Decodable {
        var triple: String
        var unversionedTriple: String?
        var platform: String?
    }

    struct Paths: Decodable { var runtimeResourcePath: String? }

    var compilerVersion: String
    var target: Target
    var paths: Paths?
}

/// The names a toolchain's `Info.plist` (swift.org) or `ToolchainInfo.plist` (Xcode) gives it.
private struct ToolchainPlist: Decodable {
    // The plist's own key names.
    // swiftlint:disable identifier_name
    var CFBundleIdentifier: String?
    var Identifier: String?
    var Aliases: [String]?
    // swiftlint:enable identifier_name
}
