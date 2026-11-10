import Foundation
import SFSIL

/// Which functions of the compiler's output belong to the scanned module (see `SILText.prepare`).
extension SILText {
    /// What `prepare` returns: the SIL without annotations, the module's functions, and problems with the run.
    struct Prepared {
        let clean: String
        let functions: [FunctionInfo]
        let warnings: [String]
    }

    /// A function whose body is being read, with how it was attributed to the module.
    struct OpenFunction {
        let symbol: String
        let name: String
        let location: SourceLocation?
        let generated: Bool
        let parameterTypes: [String]
        let resultType: String
        /// True when the symbol starts with `$s<length><module>`, so no demangling is needed.
        let byPrefix: Bool
    }

    static func info(_ open: OpenFunction, _ collected: Collected) -> FunctionInfo {
        FunctionInfo(
            symbol: open.symbol, displayName: open.name, location: open.location, isGenerated: open.generated,
            parameterTypes: open.parameterTypes, resultType: open.resultType,
            condFails: collected.condFails, calls: collected.calls, failureBlocks: collected.failureBlocks,
            parameterNames: collected.parameterNames, valueLocations: collected.values
        )
    }

    /// The functions that belong to `module`: those found by prefix, and those whose demangled names say so.
    /// `definitions` is the number of function bodies in the SIL, for the warning when none is the module's.
    static func owned(
        _ functions: [(info: FunctionInfo, byPrefix: Bool)], module: String, extensionContext: String, definitions: Int,
        demangle: (([String]) -> [String: String]?)?
    ) -> (functions: [FunctionInfo], warnings: [String]) {
        let candidates = functions.filter { !$0.byPrefix }.map(\.info.symbol)
        var warnings: [String] = []
        var owned = Set(candidates.filter { $0.contains(extensionContext) })
        if !candidates.isEmpty, let demangle {
            if let names = demangle(candidates) {
                owned = Set(candidates.filter { names[$0].map { belongs($0, to: module) } ?? false })
            } else {
                warnings.append(
                    "could not run `xcrun swift-demangle`: functions of \(module) whose mangled names are shortened "
                        + "(\(candidates.count - owned.count) candidates) may be missing from this report")
            }
        }
        let kept = functions.filter { $0.byPrefix || owned.contains($0.info.symbol) }.map(\.info)
        if kept.isEmpty, definitions > 0 {
            warnings.append(
                "found no function of module \(module) among the \(definitions) function bodies the compiler printed; "
                    + "check the module or target name (with -O, functions that are not public may have been inlined away)")
        }
        return (kept, warnings)
    }

    /// Whether a demangled name (`swift-demangle` without `--simplified`) is declared in `module`: its context
    /// starts with the module (`M.f()`, `static M.T.f()`) or it is in an extension written there
    /// (`(extension in M):Other.T.f()`). Closures, thunks and the like start with other words and are not.
    static func belongs(_ demangled: String, to module: String) -> Bool {
        var name = Substring(demangled)
        for prefix in ["static ", "class "] where name.hasPrefix(prefix) { name = name.dropFirst(prefix.count) }
        return name.hasPrefix(module + ".") || name.hasPrefix("(extension in \(module)):")
    }

    /// Code a macro wrote that no user wrote by hand: a function in a freestanding (`#Preview`), member, peer or
    /// extension expansion (`@__swiftmacro_…fMf_.swift`, `fMm_`, `fMp_`, `fMe_`), or in a type with a macro-made unique
    /// name (`…PreviewRegistryfMu_`). Accessor expansions (`fMa_`, as `@Observable` writes for `var count`) stay: they
    /// stand for a property the user wrote.
    static func isMacroOutput(_ name: String, _ location: SourceLocation?) -> Bool {
        if name.contains("$s"), name.contains("fMu") { return true }
        guard let file = location?.file, file.hasPrefix("@__swiftmacro_"), file.hasSuffix(".swift") else { return false }
        guard let role = file.dropLast(".swift".count).firstMatch(of: /fM([a-z])[0-9]*_$/)?.output.1 else { return false }
        return role != "a"
    }
}
