import Foundation
public import SFSIL

/// What the compiler tells us about one function besides its body: a readable name, where it is written,
/// its signature, and the source position of each of its traps and calls.
public struct FunctionInfo: Sendable {
    public let symbol: String
    /// `clamp(_:_:)` or `Counter.next()`, as printed by the compiler.
    public let displayName: String
    public let location: SourceLocation?
    /// Synthesized by the compiler (Hashable, Codable, memberwise inits, ...); nobody wrote it.
    public let isGenerated: Bool
    public let parameterTypes: [String]
    public let resultType: String
    let condFails: [String: (location: SourceLocation, message: String)]
    let calls: [String: SourceLocation]
    /// Blocks ending in `unreachable` after a call to a failure function (`Division by zero`, `Index out of range`, ...).
    let failureBlocks: [String: (location: SourceLocation?, message: String)]
    /// Parameter names from the debug info, by position (`argno`), when the compiler printed them.
    let parameterNames: [Int: String]
    var valueLocations: [String: SourceLocation] = [:]  // where each value (`%7`) is defined: places a refusal (U7)

    /// `clamp` for `clamp(_:_:)`; `Counter.next` for a method.
    public var baseName: String { displayName.firstIndex(of: "(").map { String(displayName[..<$0]) } ?? displayName }

    /// The argument labels of `clamp(_:_:)`: `["_", "_"]`.
    public var argumentLabels: [String] {
        guard let open = displayName.firstIndex(of: "("), let close = displayName.lastIndex(of: ")"), open < close else { return [] }
        return displayName[displayName.index(after: open)..<close].split(separator: ":").map(String.init)
    }

    public var isMethod: Bool { baseName.contains(".") }

}

public struct CompileOptions: Sendable {
    public var files: [String]
    public var moduleName: String
    public var optimization: Optimization
    /// The configuration of `assert`s (`BuildConfiguration`). Ignored with `-O`, which always builds `release`.
    public var configuration: BuildConfiguration = .debug
    /// The `swiftc` to run (an absolute path), for example the one a SwiftPM build used; nil: `xcrun --find swiftc`.
    public var compiler: String?
    /// Passed to the frontend as they are: `-I`, `-F`, `-D`, `-swift-version`, `-target`, `-sdk`, ...
    public var extraArguments: [String]
    /// `sfverify --paranoid`: the compiler checks its own SIL after every pass (`-sil-verify-all`; compiles take 40 to
    /// 75 % longer). It checks the compiler, not this reader: a malformed module stops the scan with a compiler error.
    public var verifiesCompilerSIL = false
    /// Where each compile of these options (to SIL or LLVM IR) adds the files it read; nil: not recorded.
    package var dependencies: CompilerDependencies?

    public init(files: [String], moduleName: String, optimization: Optimization = .none, extraArguments: [String] = []) {
        self.files = files
        self.moduleName = moduleName
        self.optimization = optimization
        self.extraArguments = extraArguments
    }
}

public struct CompiledModule: Sendable {
    package internal(set) var module: SILModule
    /// Functions defined by the compiled module itself, with compiler-generated thunks and closures removed.
    public let functions: [FunctionInfo]
    public let silBytes: Int
    public let compileSeconds: Double
    public let parseSeconds: Double
    /// Imported modules of the same build whose SIL was linked in.
    public var linkedModules: [String] = []
    /// Imported modules that should have been linked but could not be, with the reason.
    public var unlinkedModules: [String: String] = [:]
    /// The source files of the modules in `unlinkedModules` whose compile options were known (whose types are theirs).
    public var unlinkedModuleFiles: [String: [String]] = [:]
    /// Problems with the run as a whole, such as functions that may be missing (see `SILText.prepare`).
    public var warnings: [String] = []
    /// How the module was compiled, for the Scan proof cache (`ModuleCompiler.identity`); nil when unknown, which
    /// turns the cache off for the module.
    package var identity: String?
}

public enum ModuleCompiler {
    /// Compiles `options` to SIL and parses it.
    ///
    /// - Parameter dependency: the compile options of an imported module of the same build, or nil to leave it
    ///   out. Each module it returns is compiled too and linked in, so that its types, conformances and function
    ///   bodies are known; its imports are followed in turn.
    public static func compile(
        _ options: CompileOptions, linking dependency: (String) throws -> CompileOptions? = { _ in nil }
    ) throws -> CompiledModule {
        let started = Date()
        let arguments = try silArguments(options)
        let text = try emitSIL(arguments: arguments, dependencies: options.dependencies)
        var compileSeconds = Date().timeIntervalSince(started)
        let parseStart = Date()
        let prepared = SILText.prepare(text, module: options.moduleName)
        var module = try SILModule(text: prepared.clean)
        var parseSeconds = Date().timeIntervalSince(parseStart)

        let imports = linkImports(into: &module, options: options, dependency: dependency)
        compileSeconds += imports.compileSeconds
        parseSeconds += imports.parseSeconds
        let linked = imports.linked
        let checkStart = Date()
        let own = Set([options.moduleName] + linked), others = module.imports.filter { !own.contains($0) }
        try TypeNameCheck.check(&module, imports: others, arguments: options.extraArguments, sources: own.union(imports.notLinked.keys))
        compileSeconds += Date().timeIntervalSince(checkStart)
        return CompiledModule(
            module: module, functions: prepared.functions, silBytes: text.utf8.count,
            compileSeconds: compileSeconds, parseSeconds: parseSeconds, linkedModules: linked, unlinkedModules: imports.notLinked,
            unlinkedModuleFiles: imports.notLinkedFiles, warnings: prepared.warnings,
            identity: identity(options, arguments: arguments, linked: linked, unlinked: imports.notLinked)
        )
    }

    /// The `swiftc -frontend -emit-sil` command line for `options`, without the output (`-o`).
    static func silArguments(_ options: CompileOptions) throws -> [String] {
        var arguments = frontendArguments(options)
        let sdk = try sdkArguments(options.extraArguments)
        arguments += sdk.arguments
        arguments += try macroPluginArguments(sdk: sdk.path)
        // One module cache per compiler, not SwiftPM's per scratch path (plan item K9).
        return arguments + (try withModuleCache(options.extraArguments)) + options.files
    }

    static func emitSIL(_ options: CompileOptions) throws -> String {
        try emitSIL(arguments: try silArguments(options), dependencies: options.dependencies)
    }

    /// Runs `arguments` (from `silArguments`) and returns the SIL; adds the files the compiler read to `dependencies`.
    static func emitSIL(arguments: [String], dependencies: CompilerDependencies? = nil) throws -> String {
        try output(of: arguments, dependencies: dependencies, kind: "SIL")
    }

    /// `-sdk <path>` unless `extra` already has one, and the SDK path either way. Without `xcrun` (Linux) the toolchain
    /// has no SDK: no `-sdk`, and the path is nil.
    static func sdkArguments(_ extra: [String]) throws -> (arguments: [String], path: String?) {
        if let index = extra.firstIndex(of: "-sdk"), extra.indices.contains(index + 1) { return ([], extra[index + 1]) }
        guard let found = try ScanToolchain.current().sdk else { return ([], nil) }
        return (["-sdk", found], found)
    }

    /// Runs the scan's compiler (`ScanToolchain.current`, plan item K2) with `arguments`, whose first one is `swiftc`;
    /// stdout is discarded, stderr returned.
    static func run(_ arguments: [String]) throws -> (status: Int32, errors: String) {
        precondition(arguments.first == "swiftc", "ModuleCompiler.run runs the scan's swiftc only")
        let result = try Spawn.run(try ScanToolchain.current().swiftc, Array(arguments.dropFirst()), output: false)
        return (result.status, result.errorText)
    }

    /// `swiftc -frontend` does not add the macro plugin search paths that the `swiftc` driver adds, so code that
    /// uses a system macro (`@Observable`, `#Preview`, `#expect`) would not compile. Adds the toolchain's and the
    /// SDK platform's plugin directories, as the driver does. Flags captured from a SwiftPM build only add to these.
    static func macroPluginArguments(sdk: String?) throws -> [String] {
        var arguments: [String] = []
        let toolchain = try ScanToolchain.current()
        // The resource directory (`-print-target-info`, plan item K10) is `<usr>/lib/swift`; `host/plugins/testing` holds
        // Swift Testing's macros (`@Test`, `#expect`), which the driver also finds.
        let resources = toolchain.resourceDirectory ?? toolchain.toolchainUsr + "/lib/swift"
        let usr = toolchain.toolchainUsr
        let directories = [resources + "/host/plugins", usr + "/local/lib/swift/host/plugins", resources + "/host/plugins/testing"]
        for path in directories where FileManager.default.fileExists(atPath: path) { arguments += ["-plugin-path", path] }
        if let sdk {
            // <platform>/Developer/SDKs/<name>.sdk -> <platform>/Developer
            let developer = ((sdk as NSString).deletingLastPathComponent as NSString).deletingLastPathComponent
            // A simulator platform has no plugins of its own: the device platform's, as the driver does (app study round 6).
            let pluginDeveloper = pluginPlatformDeveloper(developer)
            let plugins = pluginDeveloper + "/usr/lib/swift/host/plugins"
            let server = pluginDeveloper + "/usr/bin/swift-plugin-server"
            if FileManager.default.fileExists(atPath: plugins), FileManager.default.fileExists(atPath: server) {
                arguments += ["-external-plugin-path", plugins + "#" + server]
            }
            // The platform's developer modules (`import Testing`, `import XCTest`), as SwiftPM passes them.
            let frameworks = developer + "/Library/Frameworks", libraries = developer + "/usr/lib"
            if FileManager.default.fileExists(atPath: frameworks) { arguments += ["-F", frameworks] }
            if FileManager.default.fileExists(atPath: libraries) { arguments += ["-I", libraries] }
        }
        return arguments
    }

}

/// Reads the debug-annotated SIL that `-g -Xllvm -sil-print-debuginfo` prints: collects names and positions,
/// and returns the same text without the annotations, which is what `SILModule` parses.
enum SILText {
    /// Compiler-generated functions that no user wrote or can call by name.
    private static let skippedPrefixes = [
        "protocol witness", "reabstraction thunk", "closure #", "implicit closure", "thunk", "one-time initialization",
        "main", "default argument", "variable initialization expression", "vtable thunk", "outlined", "specialized", "merged", "key path",
    ]
    private static let skippedSuffixes = [
        ".unsafeMutableAddressor", ".unsafeAddressor", ".deinit", ".__deallocating_deinit", ".modify", ".init()", ".read",
    ]

    /// Collects the functions of `module` and strips the debug annotations.
    ///
    /// A symbol that starts with `$s<length><module>` is the module's. Any other named function may still be: the
    /// mangler shortens a name whose words already appeared in the symbol (`AppStepByStep` is `09AppStepByB0`,
    /// an extension in `AppSettings` of an `AppCore` type is `…0A8SettingsE…`), and a constrained extension
    /// puts its generic signature between the module and `E`. Those are decided by their demangled names, from one
    /// `demangle` call. With `demangle: nil` only the prefix decides (enough when the functions are not used). When
    /// `demangle` fails, the result says that some functions may be missing instead of dropping them silently.
    static func prepare(
        _ text: String, module: String, demangle: (([String]) -> [String: String]?)? = { Demangler.demangle($0, simplified: false) }
    ) -> Prepared {
        let modulePrefix = "$s\(module.utf8.count)\(module)"
        // `extension Double { func f() }` in this module mangles as `$sSd<module>E1f…`: the outside type comes first.
        let extensionContext = "\(module.utf8.count)\(module)E"
        var cleanLines: [String] = []
        var functions: [(info: FunctionInfo, byPrefix: Bool)] = []
        var pendingName: (name: String, location: SourceLocation?, generated: Bool)?
        var current: OpenFunction?
        var collected = Collected()
        var definitions = 0

        func close() {
            if let open = current { functions.append((info(open, collected), open.byPrefix)) }
            (current, collected) = (nil, Collected())
        }
        for raw in lines(text) {
            if current != nil {
                if raw.hasPrefix("}") { close() } else { collected.record(raw) }
                cleanLines.append(strip(raw))
                continue
            }
            if raw.hasPrefix("// "), !raw.hasPrefix("// Isolation:") {
                let comment = String(raw.dropFirst(3))
                let (name, location) = splitName(comment)
                pendingName = (name, location, isGenerated(comment, name, location))
            } else if raw.hasPrefix("sil "), raw.hasSuffix("{"), let symbolRange = raw.byteRange(of: " @$"),
                let colon = raw.byteRange(of: " : $")
            {
                definitions += 1
                let symbol = String(raw[raw.index(symbolRange.lowerBound, offsetBy: 2)..<colon.lowerBound])
                let byPrefix = symbol.hasPrefix(modulePrefix)
                if byPrefix || demangle != nil || symbol.contains(extensionContext), let named = pendingName,
                    isUserFunction(symbol, named.name)
                {
                    let (params, result) = splitSignature(String(raw[colon.upperBound...].dropLast(2)))
                    current = OpenFunction(
                        symbol: symbol, name: named.name, location: named.location, generated: named.generated,
                        parameterTypes: params, resultType: result, byPrefix: byPrefix)
                }
                pendingName = nil
                cleanLines.append(raw)
                continue
            } else if !raw.isEmpty, !raw.hasPrefix("//") {
                pendingName = nil
            }
            cleanLines.append(strip(raw))
        }
        close()

        let result = owned(
            functions, module: module, extensionContext: extensionContext, definitions: definitions, demangle: demangle)
        return Prepared(clean: cleanLines.joined(separator: "\n"), functions: result.functions, warnings: result.warnings)
    }

    /// The lines of `text`, split by byte: Foundation's `components(separatedBy:)` compares characters and is slower.
    private static func lines(_ text: String) -> [String] {
        text.utf8.split(separator: UInt8(ascii: "\n"), omittingEmptySubsequences: false).map { String(Substring($0)) }
    }

    private static func isUserFunction(_ symbol: String, _ name: String) -> Bool {
        if skippedPrefixes.contains(where: { name.hasPrefix($0) }) { return false }
        if skippedSuffixes.contains(where: { name.hasSuffix($0) }) { return false }
        if symbol.hasSuffix("fu_") || symbol.contains("fu0_") || symbol.contains("fU_") { return false }
        return true
    }

    /// Written by the compiler (`loc *`) or by a macro, not by a user.
    private static func isGenerated(_ comment: String, _ name: String, _ location: SourceLocation?) -> Bool {
        comment.bytesContain(", loc * ") || isWalkPeer(name, location) || isMacroOutput(name, location)
    }

    /// The `verify_<name>()` walk that `@Verify` adds next to a function: written by the macro, not a user.
    private static func isWalkPeer(_ name: String, _ location: SourceLocation?) -> Bool {
        guard let file = location?.file else { return false }
        return file.hasPrefix("@__swiftmacro_") && file.contains("6VerifyfMp_") && name.contains("verify_")
    }

    /// `absA(_:), loc "a.swift":1:13, scope 1` gives ("absA(_:)", a.swift:1:13).
    private static func splitName(_ comment: String) -> (String, SourceLocation?) {
        guard let r = comment.byteRange(of: ", loc ") else { return (comment, nil) }
        return (String(comment[..<r.lowerBound]), location(in: String(comment[r.lowerBound...])))
    }

    /// `loc "a.swift":2:25` (or `loc * "a.swift":2:25` for generated code) anywhere in `text`.
    static func location(in text: String) -> SourceLocation? {
        guard let r = text.byteRange(of: "loc ") else { return nil }
        // Runs on every line. When the rest is ASCII, bytes and characters are the same, so it is read by bytes.
        let bytes = text.utf8[r.upperBound...]
        if bytes.allSatisfy({ $0 < 0x80 }) { return asciiLocation(bytes) }
        var rest = text[r.upperBound...]
        if rest.hasPrefix("* ") { rest = rest.dropFirst(2) }
        guard rest.hasPrefix("\""), let quote = rest.dropFirst().firstIndex(of: "\"") else { return nil }
        let file = String(rest[rest.index(after: rest.startIndex)..<quote])
        let numbers = rest[rest.index(after: quote)...].dropFirst().prefix { $0.isNumber || $0 == ":" }.split(separator: ":")
        guard numbers.count >= 2, let line = Int(numbers[0]), let column = Int(numbers[1]) else { return nil }
        return SourceLocation(file: file, line: line, column: column)
    }

    /// `location(in:)` after `loc `, for ASCII text: the same steps on bytes.
    private static func asciiLocation(_ rest: Substring.UTF8View) -> SourceLocation? {
        let quote = UInt8(ascii: "\""), colon = UInt8(ascii: ":")
        var start = rest.startIndex
        if rest.starts(with: "* ".utf8) { start = rest.index(start, offsetBy: 2) }
        guard start != rest.endIndex, rest[start] == quote else { return nil }
        let fileStart = rest.index(after: start)
        guard let close = rest[fileStart...].firstIndex(of: quote) else { return nil }
        let file = String(Substring(rest[fileStart..<close]))
        let numbers = rest[rest.index(after: close)...].dropFirst().prefix { (48...57).contains($0) || $0 == colon }
            .split(separator: colon)
        guard numbers.count >= 2, let line = Int(String(Substring(numbers[0]))), let column = Int(String(Substring(numbers[1])))
        else { return nil }
        return SourceLocation(file: file, line: line, column: column)
    }

    /// Cuts `, loc "...":l:c, scope n` and keeps a trailing `// ...` comment.
    private static func strip(_ line: String) -> String {
        guard let cut = line.byteRange(of: ", loc ") ?? line.byteRange(of: ", scope ") else { return line }
        if let comment = line[cut.lowerBound...].byteRange(of: " //") {
            return String(line[..<cut.lowerBound]) + String(line[comment.lowerBound...])
        }
        return String(line[..<cut.lowerBound])
    }

    /// `@convention(thin) (Int, Int) -> Int` gives (["Int", "Int"], "Int").
    private static func splitSignature(_ signature: String) -> ([String], String) {
        var signature = signature
        if signature.hasPrefix("@"), let close = signature.firstIndex(of: ")") {
            signature = String(signature[signature.index(after: close)...]).trimmingCharacters(in: .whitespaces)
        }
        guard let open = signature.firstIndex(of: "(") else { return ([], "") }
        var depth = 0
        var close = open
        var i = open
        while i < signature.endIndex {
            let ch = signature[i]
            if ch == "(" || ch == "<" || ch == "[" { depth += 1 }
            if ch == ")" || ch == ">" || ch == "]" { depth -= 1 }
            if depth == 0 { close = i; break }
            i = signature.index(after: i)
        }
        let inner = signature[signature.index(after: open)..<close]
        var params: [String] = []
        var current = ""
        depth = 0
        for ch in inner {
            if ch == "(" || ch == "<" || ch == "[" { depth += 1 }
            if ch == ")" || ch == ">" || ch == "]" { depth -= 1 }
            if ch == ",", depth == 0 {
                params.append(current.trimmingCharacters(in: .whitespaces)); current = ""
            } else {
                current.append(ch)
            }
        }
        if !current.trimmingCharacters(in: .whitespaces).isEmpty { params.append(current.trimmingCharacters(in: .whitespaces)) }
        var result = ""
        if let arrow = signature[signature.index(after: close)...].range(of: "-> ") {
            result = String(signature[arrow.upperBound...]).trimmingCharacters(in: .whitespaces)
        }
        return (params, withoutError(result))
    }

    /// A throwing function's result without its error: `(Int8, @error any Error)` -> `Int8`, `@error E` -> `()`.
    private static func withoutError(_ result: String) -> String {
        if result.hasPrefix("@error") { return "()" }
        guard result.hasPrefix("("), result.hasSuffix(")"), let comma = result.range(of: ", @error", options: .backwards) else {
            return result
        }
        let rest = String(result[result.index(after: result.startIndex)..<comma.lowerBound])
        return rest.contains(",") ? "(" + rest + ")" : rest
    }
}

extension StringProtocol {
    /// `range(of:)` for an ASCII `needle`, comparing UTF-8 bytes: the same match in SIL text, several times faster than
    /// Foundation's search, which compares characters. SIL is read line by line, so this runs on every line.
    func byteRange(of needle: String) -> Range<Index>? {
        let bytes = utf8
        let pattern = needle.utf8
        guard let first = pattern.first else { return nil }
        var start = bytes.startIndex
        while let candidate = bytes[start...].firstIndex(of: first) {
            var position = candidate
            var matched = true
            for byte in pattern {
                guard position != bytes.endIndex, bytes[position] == byte else {
                    matched = false
                    break
                }
                bytes.formIndex(after: &position)
            }
            if matched { return candidate..<position }
            start = bytes.index(after: candidate)
        }
        return nil
    }

    func bytesContain(_ needle: String) -> Bool { byteRange(of: needle) != nil }
}
