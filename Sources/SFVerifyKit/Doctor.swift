import Foundation
import SFSIL

// `swiftformal doctor` (plan item U9): the facts are gathered once (`Doctor.gather`), the checks are a pure function of
// them (`Doctor.checks`), so tests inject facts instead of a machine.

/// What `swiftformal doctor` found out about this machine and, optionally, a package.
package struct DoctorFacts: Sendable, Equatable {
    /// First line of `swiftc -version`; nil when no compiler was found.
    package var compiler: String?
    /// Why no compiler was found.
    package var compilerProblem: String?
    /// Where the compiler is and how it was picked (`at /…/swiftc (xcrun (DEVELOPER_DIR=…))`), and any note about the
    /// choice, such as a `TOOLCHAINS` that names no installed toolchain (plan item K10).
    package var compilerChoice: [String] = []
    /// Whether the compiler is one the SIL reader was validated against.
    package var pinned = false
    /// The pinned compiler builds.
    package var acceptedVersions: [String] = []
    /// True for a debug build of `swiftformal`, whose proofs are far slower.
    package var swiftformalIsDebug = false
    /// `macOS`, `Linux`, `iOS`, ...
    package var platform = "macOS"
    /// The package in the working directory (or `--package`), when there is one.
    package var package: PackageFacts?

    package init() {}
}

/// How a package uses SwiftFormal: removed products and plugins it still names, and the targets that apply the removed
/// `SwiftFormalGate` plugin.
package struct PackageFacts: Sendable, Equatable {
    /// One target that applies the removed `SwiftFormalGate` plugin.
    package struct GatedTarget: Sendable, Equatable {
        package var name: String
        /// Functions and properties marked `@Verify` in its sources: what the gate proves.
        package var verifyFunctions = 0
        /// `// sf:verify` comments in its sources, which are no longer read.
        package var markers: Int
        /// Functions with a hand-written `f_requires` or `f_ensures`, which are no longer read.
        package var contracts: Int
        /// Other targets of the package that its sources import: the gate compiles the target's files alone.
        package var importedTargets: [String]
    }

    package var root: String
    /// Products and plugins of SwiftFormal that no longer exist, as `Package.swift` names them (`SFProve`, …).
    package var removed: [String] = []
    package var gated: [GatedTarget]
    /// `.sfgate` stamps that a build copied into a resource bundle (an older SwiftFormal's gate).
    package var stampsInBundles: [String]
}

/// The result of one doctor check.
package struct DoctorCheck: Sendable, Equatable {
    /// `ok` passes; `warning` and `failure` make `doctor` exit 1.
    package enum Outcome: Sendable, Equatable {
        case ok, warning, failure
    }

    package var name: String
    package var outcome: Outcome
    package var message: String
    /// What to do about it; nil when nothing needs doing.
    package var fix: String?
}

/// The checks of `swiftformal doctor`.
package enum Doctor {
    // MARK: checks

    /// Every check, in the order they are printed.
    package static func checks(_ facts: DoctorFacts) -> [DoctorCheck] {
        var checks = [compilerCheck(facts), buildCheck(facts), exitTestCheck(facts)]
        if let package = facts.package { checks += packageChecks(package) }
        return checks
    }

    /// 0 when every check passed, 1 otherwise.
    package static func exitCode(_ checks: [DoctorCheck]) -> Int32 { checks.allSatisfy { $0.outcome == .ok } ? 0 : 1 }

    /// One line per check, and an indented `fix:` line under each that needs one.
    package static func render(_ checks: [DoctorCheck]) -> String {
        var lines: [String] = []
        for check in checks {
            let mark =
                switch check.outcome {
                case .ok: "✓"
                case .warning: "!"
                case .failure: "✗"
                }
            lines.append("\(mark) \(check.name): \(check.message)")
            if let fix = check.fix, check.outcome != .ok { lines.append("    fix: \(fix)") }
        }
        let problems = checks.filter { $0.outcome != .ok }.count
        lines.append("")
        lines.append(problems == 0 ? "All checks passed." : "\(problems) of \(checks.count) checks need attention.")
        return lines.joined(separator: "\n")
    }

    private static func compilerCheck(_ facts: DoctorFacts) -> DoctorCheck {
        guard let compiler = facts.compiler else {
            return DoctorCheck(
                name: "compiler", outcome: .failure, message: "no swiftc found (\(facts.compilerProblem ?? "xcrun --find swiftc failed"))",
                fix: "install Xcode or a Swift toolchain, and select it with xcode-select or DEVELOPER_DIR")
        }
        guard facts.pinned else {
            return DoctorCheck(
                name: "compiler", outcome: .failure,
                message: "'\(compiler)' is not one Scan was validated against (\(facts.acceptedVersions.joined(separator: "; "))): "
                    + "the gate fails, and sfverify's verdicts are not covered by docs/TRUST.md"
                    + (facts.compilerChoice.isEmpty ? "" : " (" + facts.compilerChoice.joined(separator: "; ") + ")"),
                fix: "select a pinned Xcode (DEVELOPER_DIR=/Applications/Xcode-….app), or update the pin (docs/guides/pin-upgrade.md)")
        }
        let choice = facts.compilerChoice.isEmpty ? "" : " " + facts.compilerChoice.joined(separator: "; ")
        return DoctorCheck(name: "compiler", outcome: .ok, message: "'\(compiler)' is pinned" + choice)
    }

    private static func buildCheck(_ facts: DoctorFacts) -> DoctorCheck {
        guard !facts.swiftformalIsDebug else {
            return DoctorCheck(
                name: "swiftformal", outcome: .warning,
                message: "this swiftformal is a debug build: proofs are far slower (Examples/Metrics: 2.4 s in release, "
                    + "unfinished after minutes in debug)",
                fix: "swift build -c release --product swiftformal, and run .build/release/swiftformal")
        }
        return DoctorCheck(name: "swiftformal", outcome: .ok, message: "a release build")
    }

    private static func exitTestCheck(_ facts: DoctorFacts) -> DoctorCheck {
        let version = facts.compiler.flatMap(swiftVersion) ?? []
        if facts.platform == "iOS" || facts.platform == "tvOS" || facts.platform == "watchOS" || facts.platform == "visionOS" {
            return DoctorCheck(
                name: "exit tests", outcome: .warning,
                message: "Swift Testing has no exit tests on \(facts.platform): a trap still ends a walk there",
                fix: "run walks that may trap, and `swiftformal check --emit-tests` tests, on macOS or Linux")
        }
        guard version.lexicographicallyPrecedes([6, 3]) == false, !version.isEmpty else {
            return DoctorCheck(
                name: "exit tests", outcome: .warning,
                message: "the trap walk and `swiftformal check --emit-tests` tests need exit tests with capture lists (Swift 6.3 or newer)",
                fix: "use Xcode with Swift 6.3 or newer")
        }
        return DoctorCheck(
            name: "exit tests", outcome: .ok,
            message: "available (Swift \(version.map(String.init).joined(separator: ".")) on \(facts.platform))")
    }

    private static func packageChecks(_ package: PackageFacts) -> [DoctorCheck] {
        var checks = package.removed.map { name in
            DoctorCheck(
                name: "package", outcome: .failure,
                message: "\(package.root)/Package.swift names \(name), which SwiftFormal no longer has (one product for app code, "
                    + "one for tests, and the swiftformal command)",
                fix: removedInstead[name] ?? "use the products SwiftFormal and SwiftFormalTesting")
        }
        for target in package.gated {
            checks += pluginChecks(target, name: "gate \(target.name)")
        }
        if !package.stampsInBundles.isEmpty {
            checks.append(
                DoctorCheck(
                    name: "gate stamp", outcome: .failure,
                    message: "the gate's stamp was copied into a resource bundle (\(package.stampsInBundles[0])): a Bundle.module "
                        + "accessor is added to the target and Scan counts it",
                    fix: "remove the SwiftFormalGate plugin, then rm -rf .build"))
        }
        if checks.isEmpty {
            checks.append(
                DoctorCheck(
                    name: "package", outcome: .ok,
                    message: "\(package.root) uses only SwiftFormal's products (gate a build with `swiftformal check --gate`)"))
        }
        return checks
    }

    /// The products and plugins of SwiftFormal that were removed, with what to use instead.
    package static let removedInstead: [String: String] = [
        "SwiftFormalContracts": "depend on the product SwiftFormal and `import SwiftFormal`: it has @Verify, #requires and #ensures",
        "SFProve": "depend on the product SwiftFormalTesting and `import SwiftFormalTesting`: it re-exports proveSigned and SymbolicInt",
        "SFVerifyKit": "run the swiftformal command (`swiftformal check --scan <dir>:<target>`) instead of linking the engine",
        "SFGenKit": "walk a function in a test with Prove(it:over:) (SwiftFormalTesting)",
        "sfverify": "run `swiftformal check` (`--gate` for the build check, `--format json|xcode|sarif|github`)",
        "sfgen": "walk a function in a test with Prove(it:over:) (SwiftFormalTesting)",
        "SwiftFormalGate": "remove the plugin and run `swiftformal check --gate` in a Run Script phase or on CI",
        "SwiftFormalScan": "run `swiftformal check --scan <dir>:<target>` instead of `swift package scan`",
    ]

    /// `[6, 4]` from `Apple Swift version 6.4 (…)` or `Swift version 6.3-dev (…)`.
    package static func swiftVersion(_ line: String) -> [Int]? {
        guard let range = line.range(of: "Swift version ") else { return nil }
        let numbers = line[range.upperBound...].prefix { $0.isNumber || $0 == "." }.split(separator: ".").compactMap { Int($0) }
        return numbers.count >= 2 ? Array(numbers.prefix(2)) : nil
    }

    // MARK: facts

    /// Gathers the facts: the compiler (`xcrun --find swiftc`), the `sfverify` in `toolDirectory`, the package at
    /// `packageRoot` when it has a manifest.
    package static func gather(toolDirectory: String, packageRoot: String?, swiftformalIsDebug: Bool) -> DoctorFacts {
        var facts = DoctorFacts()
        facts.acceptedVersions = CompilerPin.verified.acceptedVersions
        do {
            let toolchain = try ScanToolchain.resolve()
            facts.compiler = toolchain.versionLine
            facts.pinned = toolchain.isPinned()
            facts.compilerChoice = ["at \(toolchain.swiftc) (\(toolchain.origin))"] + toolchain.notes
        } catch {
            facts.compilerProblem = "\(error)"
        }
        let lowered = (toolDirectory as NSString).resolvingSymlinksInPath.lowercased() + "/"
        // `.build/debug/` or swiftbuild's `.build/out/Products/Debug/`; elsewhere (an installed copy) how it was compiled.
        facts.swiftformalIsDebug = lowered.contains("/debug/") || (!lowered.contains("/release/") && swiftformalIsDebug)
        #if os(Linux)
            facts.platform = "Linux"
        #elseif os(iOS)
            facts.platform = "iOS"
        #else
            facts.platform = "macOS"
        #endif
        if let packageRoot { facts.package = packageFacts(root: packageRoot) }
        return facts
    }

    /// Reads `Package.swift` at `root` (as text: no build, no dependency fetch) and the gated targets' sources; nil
    /// when there is no manifest.
    package static func packageFacts(root: String) -> PackageFacts? {
        guard let manifest = try? String(contentsOfFile: root + "/Package.swift", encoding: .utf8) else { return nil }
        let targets = manifestTargets(manifest)
        let names = Set(targets.map(\.name))
        let gated = targets.filter { $0.body.contains("SwiftFormalGate") }.map { target in
            let directory = root + "/" + (target.path ?? "Sources/\(target.name)")
            let files = swiftFiles(in: directory)
            let imports = files.flatMap(importedModules).filter { names.contains($0) && $0 != target.name }
            return PackageFacts.GatedTarget(
                name: target.name, verifyFunctions: BuildCheck.promises(in: files).promises.count,
                markers: Gate.staleMarkers(in: files) { try? String(contentsOfFile: $0, encoding: .utf8) }.count,
                contracts: Gate.contractNames(in: files).count,
                importedTargets: Array(Set(imports)).sorted())
        }
        return PackageFacts(
            root: root, removed: removedNames(in: manifest), gated: gated,
            stampsInBundles: stampsInBundles(root + "/.build"))
    }

    /// The removed products and plugins a manifest names: `.product(name: "SFProve", …)`, `.plugin(name:
    /// "SwiftFormalGate", …)`. Read as text, so a manifest that SwiftPM can no longer resolve is still read.
    package static func removedNames(in manifest: String) -> [String] {
        removedInstead.keys.sorted().filter { name in
            [".product(name: \"\(name)\"", ".plugin(name: \"\(name)\""].contains { manifest.contains($0) }
        }
    }

    /// A target declaration of a manifest: its name, its `path:` if given, and its text.
    private struct ManifestTarget {
        let name: String
        let path: String?
        let body: String
    }

    /// `.target(name: "X", …)` and the other target kinds of a manifest, each with its text up to its closing parenthesis. Only
    /// the outermost ones count: `.target(name:)` inside a `dependencies:` list is a dependency, one level deeper.
    private static func manifestTargets(_ manifest: String) -> [ManifestTarget] {
        let kinds = [".target(", ".executableTarget(", ".testTarget(", ".macro(", ".systemLibrary("]
        var starts: [(index: String.Index, depth: Int)] = []
        var depth = 0
        var index = manifest.startIndex
        while index < manifest.endIndex {
            let character = manifest[index]
            if "([".contains(character) { depth += 1 }
            if ")]".contains(character) { depth -= 1 }
            if kinds.contains(where: { manifest[index...].hasPrefix($0) }) { starts.append((index, depth)) }
            index = manifest.index(after: index)
        }
        let outermost = starts.map(\.depth).min()
        return starts.filter { $0.depth == outermost }.compactMap { start in
            let body = String(manifest[start.index..<closingParenthesis(in: manifest, from: start.index)])
            guard let name = quoted(after: "name:", in: body) else { return nil }
            return ManifestTarget(name: name, path: quoted(after: "path:", in: body), body: body)
        }
    }

    /// The index after the `)` that closes the first `(` at or after `start` (the end of the text if none does).
    private static func closingParenthesis(in text: String, from start: String.Index) -> String.Index {
        var depth = 0
        var index = start
        while index < text.endIndex {
            if text[index] == "(" { depth += 1 }
            if text[index] == ")" {
                depth -= 1
                if depth == 0 { return text.index(after: index) }
            }
            index = text.index(after: index)
        }
        return text.endIndex
    }

    private static func quoted(after key: String, in text: String) -> String? {
        guard let keyRange = text.range(of: key), let open = text[keyRange.upperBound...].firstIndex(of: "\""),
            let close = text[text.index(after: open)...].firstIndex(of: "\"")
        else { return nil }
        return String(text[text.index(after: open)..<close])
    }

    private static func swiftFiles(in directory: String) -> [String] {
        let found = FileManager.default.enumerator(atPath: directory)?.compactMap { $0 as? String } ?? []
        return found.filter { $0.hasSuffix(".swift") }.sorted().map { directory + "/" + $0 }
    }

    /// `X` for each `import X` (with or without an access level or attribute) at the start of a line.
    private static func importedModules(_ file: String) -> [String] {
        guard let text = try? String(contentsOfFile: file, encoding: .utf8) else { return [] }
        return text.split(separator: "\n").compactMap { line in
            let words = line.split(separator: " ").filter { !$0.hasPrefix("@") }
            guard let at = words.firstIndex(of: "import"), at + 1 < words.count,
                words[..<at].allSatisfy({ ["public", "package", "internal", "private", "fileprivate"].contains($0) })
            else { return nil }
            return String(words[at + 1].prefix { $0 != "." })
        }
    }

    /// `.sfgate` files inside `*.bundle` folders of a build folder, at most 6 levels down: `.build/<triple>/<config>/`
    /// (the native build system) and `.build/out/Products/<Config>/` (swiftbuild). Module and index caches are skipped.
    private static func stampsInBundles(_ build: String) -> [String] {
        let manager = FileManager.default
        guard
            let walk = manager.enumerator(
                at: URL(fileURLWithPath: build), includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsPackageDescendants])
        else { return [] }
        var found: [String] = []
        for case let url as URL in walk {
            let name = url.lastPathComponent
            if walk.level > 6 || name.hasSuffix(".noindex") || name.hasSuffix(".swiftmodule") || name == "checkouts" {
                walk.skipDescendants()
                continue
            }
            guard name.hasSuffix(".bundle") else { continue }
            walk.skipDescendants()
            let contents = (try? manager.subpathsOfDirectory(atPath: url.path)) ?? []
            found += contents.filter { $0.hasSuffix(".sfgate") }.map { url.path + "/" + $0 }
        }
        return found.sorted()
    }
}

extension Doctor {
    /// A target that applies the removed `SwiftFormalGate` plugin: its `// sf:verify` comments and hand-written contracts
    /// are not read either, and its `@Verify` functions are gated by `swiftformal check --gate`.
    static func pluginChecks(_ target: PackageFacts.GatedTarget, name: String) -> [DoctorCheck] {
        var checks: [DoctorCheck] = []
        if target.markers + target.contracts > 0 {
            let found = [
                target.markers > 0 ? "\(target.markers) `// sf:verify` comment\(target.markers == 1 ? "" : "s")" : nil,
                target.contracts > 0 ? "\(target.contracts) hand-written contract\(target.contracts == 1 ? "" : "s") (f_ensures)" : nil,
            ].compactMap { $0 }.joined(separator: " and ")
            checks.append(
                DoctorCheck(
                    name: name, outcome: .failure, message: "\(found): no longer read; `swiftformal check --gate` fails on each",
                    fix: FunctionReport.inPlaceAdvice))
        }
        let functions = target.verifyFunctions == 1 ? "1 `@Verify` function" : "\(target.verifyFunctions) `@Verify` functions"
        checks.append(
            DoctorCheck(
                name: name, outcome: .failure,
                message: "applies the SwiftFormalGate plugin, which SwiftFormal no longer has (\(functions) to gate)",
                fix: removedInstead["SwiftFormalGate"]))
        return checks
    }
}
