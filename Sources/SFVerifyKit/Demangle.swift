import Foundation

#if canImport(Darwin)
    import Darwin
#elseif canImport(Glibc)
    import Glibc
#endif

/// Turns mangled symbols inside report text (`$s4Mod3fooyS2iF`) into readable names: in-process with the scan
/// toolchain's `libswiftDemangle` (plan item K7), else with `swift-demangle --simplified`.
enum Demangler {
    static func improve(_ reports: [FunctionReport]) -> [FunctionReport] {
        var symbols: Set<String> = []
        for r in reports {
            for text in [r.detail, r.counterexample?.failure].compactMap({ $0 }) { symbols.formUnion(tokens(in: text)) }
        }
        guard !symbols.isEmpty, let names = demangle(Array(symbols)) else { return reports }
        func rewrite(_ text: String?) -> String? {
            guard var text else { return nil }
            for token in tokens(in: text).sorted(by: { $0.count > $1.count }) {
                if let readable = names[token] { text = text.replacingOccurrences(of: token, with: readable) }
            }
            return text
        }
        return reports.map { r in
            var r = r
            r.detail = rewrite(r.detail)
            if var example = r.counterexample {
                example.failure = rewrite(example.failure) ?? example.failure
                r.counterexample = example
            }
            return r
        }
    }

    private static func tokens(in text: String) -> [String] {
        text.split { !($0.isLetter || $0.isNumber || $0 == "_" || $0 == "$") }.map(String.init).filter { $0.hasPrefix("$s") }
    }

    /// The readable name of each symbol: with `simplified` (the default) the library when the toolchain has one, else
    /// the spawned tool; the full name (`simplified: false`, which the library cannot give) always spawns. Nil when
    /// that fails.
    static func demangle(_ symbols: [String], simplified: Bool = true) -> [String: String]? {
        if simplified, let usr = try? ScanToolchain.current().toolchainUsr, let library = InProcessDemangler.load(toolchainUsr: usr) {
            return Dictionary(symbols.map { ($0, library.demangle($0)) }, uniquingKeysWith: { first, _ in first })
        }
        return spawned(symbols, simplified: simplified)
    }

    /// `swift-demangle [--simplified]` next to the scan's `swiftc`, else through `xcrun`.
    static func spawned(_ symbols: [String], simplified: Bool = true) -> [String: String]? {
        let payload = Data((symbols.joined(separator: "\n") + "\n").utf8)
        let flags = simplified ? ["--simplified"] : []
        let next = (try? ScanToolchain.current().toolchainUsr).map { $0 + "/bin/swift-demangle" }
        let command =
            next.flatMap { FileManager.default.isExecutableFile(atPath: $0) ? ($0, flags) : nil }
            ?? ("/usr/bin/xcrun", ["swift-demangle"] + flags)
        guard let demangled = try? Spawn.run(command.0, command.1, input: payload), demangled.status == 0,
            let text = String(bytes: demangled.output, encoding: .utf8)
        else { return nil }
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        guard lines.count >= symbols.count else { return nil }
        var result: [String: String] = [:]
        for (symbol, line) in zip(symbols, lines) { result[symbol] = line }
        return result
    }
}

/// `swift_demangle_getSimplifiedDemangledName` from a toolchain's `libswiftDemangle`: the function behind
/// `swift-demangle --simplified`, so the same text, in under a millisecond for 690 symbols instead of a 75 ms spawn
/// (measured). The runtime's own `swift_demangle` cannot simplify.
final class InProcessDemangler: @unchecked Sendable {
    /// `size_t (const char *mangled, char *output, size_t length)`: the length of the whole name (0 when `mangled` is
    /// not a symbol); the output is cut to fit `length`.
    private typealias Function = @convention(c) (OpaquePointer?, OpaquePointer?, Int) -> Int

    private let function: Function

    private init(function: Function) { self.function = function }

    /// The library under `<toolchainUsr>/lib`, loaded once per toolchain; nil when it is missing or lacks the function.
    static func load(toolchainUsr: String) -> InProcessDemangler? {
        loaded.withLock { cache in
            if let known = cache[toolchainUsr] { return known }
            #if canImport(Darwin)
                let path = toolchainUsr + "/lib/libswiftDemangle.dylib"
            #else
                let path = toolchainUsr + "/lib/libswiftDemangle.so"
            #endif
            var found: InProcessDemangler?
            // `dlopen` of a path that does not exist only fails; checking first keeps the error out of `dlerror`.
            if FileManager.default.fileExists(atPath: path), let handle = dlopen(path, RTLD_NOW | RTLD_LOCAL),
                let symbol = dlsym(handle, "swift_demangle_getSimplifiedDemangledName")
            {
                // SAFETY: `symbol` is the address of `swift_demangle_getSimplifiedDemangledName`, whose C type is `Function`.
                let function = unsafeBitCast(symbol, to: Function.self)  // swiftlint:disable:this no_unsafe_without_comment
                found = InProcessDemangler(function: function)
            }
            cache[toolchainUsr] = .some(found)
            return found
        }
    }

    /// The simplified name of `symbol`, or `symbol` itself when it is not one (as `swift-demangle` prints it).
    func demangle(_ symbol: String) -> String {
        var capacity = 512
        while true {
            guard let output = malloc(capacity) else { return symbol }
            defer { free(output) }
            let length = symbol.withCString { function(OpaquePointer($0), OpaquePointer(output), capacity) }
            if length == 0 { return symbol }
            if length >= capacity {
                capacity = length + 1
                continue
            }
            return String(cString: output.assumingMemoryBound(to: CChar.self))
        }
    }

    private static let loaded = Guarded<[String: InProcessDemangler?]>([:])
}
