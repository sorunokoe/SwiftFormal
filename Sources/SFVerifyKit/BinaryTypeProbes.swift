import Foundation
import SFSIL

// The readers of `BinaryTypeCheck`'s probes: the compiler's notes, demangled names and SIL texts.

extension BinaryTypeCheck {
    /// `SFBinaryEnums.sfbt_0(__C.KitSurface) -> ()` -> `KitSurface`: the parameter is a class clang imported.
    static func clangClass(_ demangled: String) -> String? {
        guard let open = demangled.firstIndex(of: "("), let close = demangled.range(of: ") -> ()", options: .backwards) else { return nil }
        let parameter = demangled[demangled.index(after: open)..<close.lowerBound]
        guard parameter.hasPrefix("__C."), parameter.dropFirst(4).allSatisfy(isIdentifierCharacter), parameter.count > 4 else { return nil }
        return String(parameter.dropFirst(4))
    }

    /// `putt`, `putt(_)`, `pair(_, _)`, `labelled(x: let x)`.
    static func listedCase(_ pattern: String) -> ListedCase? {
        guard let open = pattern.firstIndex(of: "(") else {
            return pattern.allSatisfy(isIdentifierCharacter) && !pattern.isEmpty
                ? ListedCase(name: pattern, hasPayload: false, labels: []) : nil
        }
        let name = String(pattern[..<open])
        guard pattern.hasSuffix(")"), !name.isEmpty, name.allSatisfy(isIdentifierCharacter) else { return nil }
        let inner = pattern[pattern.index(after: open)..<pattern.index(before: pattern.endIndex)]
        guard !inner.contains("("), !inner.contains("<"), !inner.contains("[") else { return nil }
        var labels: [String?] = []
        for element in inner.split(separator: ",").map({ $0.trimmingCharacters(in: .whitespaces) }) {
            if element == "_" {
                labels.append(nil)
            } else if let colon = element.firstIndex(of: ":") {
                let label = String(element[..<colon])
                guard label.allSatisfy(isIdentifierCharacter), !label.isEmpty else { return nil }
                labels.append(label)
            } else {
                return nil
            }
        }
        return ListedCase(name: name, hasPayload: true, labels: labels)
    }

    private static func isIdentifierCharacter(_ c: Character) -> Bool { c.isLetter || c.isNumber || c == "_" }

    /// Where a module loaded from `path` comes from (`ModuleOrigin`), for the wording of reports only. A framework
    /// outside a build directory (or a SwiftPM binary artifact) is prebuilt; a bare `.swiftmodule` in Xcode's or
    /// SwiftPM's build products was compiled from source by that build; anything else (a framework target Xcode built,
    /// a module in another folder) may be either.
    static func origin(of path: String) -> ModuleOrigin {
        let components = path.split(separator: "/")
        if path.contains("/.build/artifacts/") { return .binary }
        let xcodeBuild = path.contains("/Build/Products/") || path.contains("/Build/Intermediates.noindex/")
        let swiftPMBuild =
            components.firstIndex(of: ".build").map { components[($0 + 1)...].contains { $0 == "debug" || $0 == "release" } } ?? false
        let inFramework = components.contains { $0.hasSuffix(".framework") || $0.hasSuffix(".xcframework") }
        if inFramework { return xcodeBuild || swiftPMBuild ? .unknown : .binary }
        return xcodeBuild || swiftPMBuild ? .notScanned : .unknown
    }

    /// The modules loaded from a file outside the SDK and the toolchain (`remark: loaded module 'Kit'; source: '…'`),
    /// with where each comes from (`origin(of:)`).
    static func binaryModules(_ errors: String, system: SystemLocations) -> [String: ModuleOrigin] {
        var modules: [String: ModuleOrigin] = [:]
        for match in errors.matches(of: /remark: loaded module '([^']+)'; source: '([^']+)'/) where !system.contains(String(match.output.2))
        {
            modules[String(match.output.1)] = origin(of: String(match.output.2))
        }
        return modules
    }

    /// A function that switches over every case of `name`, binding each payload so that its type appears in SIL (the
    /// destination block's argument) and in a closure's mangled name (so that a payload class of `__C` is read).
    static func switchSource(_ index: Int, _ name: String, _ listing: Listing) -> String {
        var lines = ["func sfbe_\(index)(_ e: \(name)) {", "switch e {"]
        for k in listing.cases {
            guard k.hasPayload else {
                lines.append("case .`\(k.name)`: break")
                continue
            }
            let bindings = k.labels.enumerated().map { ($0.element.map { "\($0): " } ?? "") + "let p\($0.offset)" }
            let value = k.labels.count == 1 ? "p0" : "(" + k.labels.indices.map { "p\($0)" }.joined(separator: ", ") + ")"
            lines.append("case .`\(k.name)`(\(bindings.joined(separator: ", "))): sfbpTake(\(value)) { _ in }")
        }
        if listing.isOpen { lines.append("@unknown default: break") }
        return (lines + ["}", "}"]).joined(separator: "\n")
    }

    /// `SFBinaryEnums.sfbe_0(Kit.Skie.Shot.__Sealed) -> ()` -> `Kit`, when the rest is `name`.
    static func enumModule(_ demangled: String, name: String) -> String? {
        guard let open = demangled.firstIndex(of: "("), let close = demangled.range(of: ") -> ()", options: .backwards) else { return nil }
        let parameter = demangled[demangled.index(after: open)..<close.lowerBound]
        guard let dot = parameter.firstIndex(of: "."), parameter[parameter.index(after: dot)...] == name else { return nil }
        return String(parameter[..<dot])
    }

    /// `Kit.Surface.ordinal.getter : Swift.Int32` -> `Kit`; `(extension in Foundation):Swift.Double.init(…)` -> `Foundation`.
    static func functionModule(_ demangled: String) -> String? {
        var text = Substring(demangled)
        for prefix in ["static ", "merged "] where text.hasPrefix(prefix) { text = text.dropFirst(prefix.count) }
        if text.hasPrefix("(extension in "), let end = text.firstIndex(of: ")") {
            return String(text[text.index(text.startIndex, offsetBy: "(extension in ".count)..<end])
        }
        guard let dot = text.firstIndex(of: "."), !text[..<dot].contains(" "), !text[..<dot].contains("(") else { return nil }
        return String(text[..<dot])
    }

    /// `Surface.ordinal.getter` -> `Surface.ordinal`; `onEnum<A>(of:)` -> `onEnum(of:)`; `static Surface.f(_:)` -> `Surface.f(_:)`.
    static func label(_ simplified: String) -> String {
        var text = simplified
        if text.hasPrefix("static ") { text.removeFirst("static ".count) }
        if let type = text.range(of: " : ") { text = String(text[..<type.lowerBound]) }
        for accessor in [".getter", ".setter", ".modify", ".read"] where text.hasSuffix(accessor) { text.removeLast(accessor.count) }
        var result = "", depth = 0
        for c in text {
            if c == "<" { depth += 1 } else if c == ">" && depth > 0 { depth -= 1 } else if depth == 0 { result.append(c) }
        }
        return result
    }
}

/// Where the SDK and the toolchain keep their modules: a module loaded from there is not a binary module of the app.
struct SystemLocations: Sendable {
    var roots: [String]
    var swiftModuleDirectories: [String]
    var frameworkDirectories: [String]

    init(sdk: String?, toolchain: ScanToolchain) {
        var roots: [String] = [], modules: [String] = [], frameworks: [String] = []
        let usr = toolchain.toolchainUsr
        roots.append((usr as NSString).deletingLastPathComponent + "/")
        if let resources = toolchain.resourceDirectory {
            roots.append(resources + "/")
            modules.append(resources + "/" + (toolchain.platform.isEmpty ? "macosx" : toolchain.platform))
        }
        if let sdk {
            roots.append(sdk + "/")
            // `<Developer>/Platforms/<P>.platform/Developer/SDKs/<P>.sdk`: the platform's own frameworks (XCTest) too.
            if let platforms = sdk.range(of: "/Platforms/") { roots.append(String(sdk[..<platforms.lowerBound]) + "/") }
            modules.append(sdk + "/usr/lib/swift")
            frameworks += [sdk + "/System/Library/Frameworks", sdk + "/System/Library/SubFrameworks"]
        }
        self.roots = roots
        self.swiftModuleDirectories = modules
        self.frameworkDirectories = frameworks
    }

    func contains(_ path: String) -> Bool { roots.contains { path.hasPrefix($0) } }

    /// The module is one of the SDK's or the toolchain's (a cheap test, to skip the probes for code that imports
    /// nothing else).
    func providesModule(_ name: String) -> Bool {
        if Self.clangSystemModules.contains(name) { return true }
        let manager = FileManager.default
        return swiftModuleDirectories.contains { manager.fileExists(atPath: "\($0)/\(name).swiftmodule") }
            || frameworkDirectories.contains { manager.fileExists(atPath: "\($0)/\(name).framework") }
    }

    private static let clangSystemModules: Set<String> = [
        "Darwin", "ObjectiveC", "Dispatch", "SwiftShims", "_SwiftConcurrencyShims", "os", "CoreFoundation", "Foundation", "Swift",
        "_Concurrency", "_StringProcessing", "Observation", "Synchronization", "XCTest", "Testing", "Glibc", "MachO", "libkern",
    ]
}

/// The functions of a SIL text, by symbol.
struct SILFunctionTexts {
    private var bodies: [String: [Substring]] = [:]

    init(_ text: String) {
        var current: String?
        for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
            if line.hasPrefix("sil "), line.hasSuffix("{"), let at = line.range(of: " @"), let end = line[at.upperBound...].range(of: " : ")
            {
                let symbol = String(line[at.upperBound..<end.lowerBound])
                current = symbol
                bodies[symbol] = []
            } else if line.hasPrefix("}") {
                current = nil
            } else if let current {
                bodies[current]?.append(line)
            }
        }
    }

    var symbols: [String] { bodies.keys.sorted() }

    /// The symbol of the Swift function `name` of module `SFBinaryEnums` (`$s13SFBinaryEnums6sfbe_0y…`).
    func symbol(named name: String) -> String? {
        let prefix = "$s13SFBinaryEnums\(name.utf8.count)\(name)y"
        // The function's own symbol: those of its closures extend it.
        return bodies.keys.filter { $0.hasPrefix(prefix) }.min { ($0.count, $0) < ($1.count, $1) }
    }

    /// The payload type of each case of the `switch_enum` over `name` in `symbol`; nil when the function has no such
    /// switch. A case of an address-only enum (`switch_enum_addr`) has no block argument, so it is left out.
    func payloads(of symbol: String, enum name: String) -> [String: String]? {
        guard let body = bodies[symbol] else { return nil }
        guard let switchLine = body.first(where: { $0.contains("switch_enum") && $0.contains("#\(name).") }) else { return nil }
        var arguments: [String: String] = [:]
        for line in body {
            guard line.hasPrefix("bb"), let open = line.firstIndex(of: "("), let colon = line.range(of: " : $"),
                let close = line.range(of: "):", options: .backwards)
            else { continue }
            let block = String(line[..<open])
            arguments[block] = String(line[colon.upperBound..<close.lowerBound])
        }
        var result: [String: String] = [:]
        for match in switchLine.matches(of: /case #([^ ]+)!enumelt: (bb[0-9]+)/) {
            let reference = String(match.output.1)
            guard reference.hasPrefix(name + "."), let type = arguments[String(match.output.2)] else { continue }
            result[String(reference.dropFirst(name.count + 1))] = type
        }
        return result
    }
}
