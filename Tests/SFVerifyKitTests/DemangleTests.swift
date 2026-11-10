import Foundation
import Testing

@testable import SFVerifyKit

/// Plan item K7: the toolchain's `libswiftDemangle`, loaded in-process, gives the same text as
/// `swift-demangle --simplified`, which stays the fallback.
@Suite struct DemangleTests {
    /// Symbols of every shape a report can hold, and two that are not symbols at all.
    private static let fixed = [
        "$s4Main3fooyS2iF", "$s4Main10SplitMix64V4nexts6UInt64VyF", "$sSa9subscriptyxSicig",
        "$ss17_assertionFailure__4file4line5flagss5NeverOs12StaticStringV_A2HSus6UInt32VtF",
        "$s4Main5ShapeO4areaSdvg", "$s4Main3BoxV5valuexvM", "$s4Main1PPAAE7defaultSiyF", "$sSD7defaultq_xc_q_yXKtcig",
        "$snotasymbol", "$s",
    ]

    @Test func theLibraryIsLoadedFromTheScanToolchain() throws {
        let toolchain = try ScanToolchain.current()
        let loaded = InProcessDemangler.load(toolchainUsr: toolchain.toolchainUsr)
        #expect(loaded != nil, "no libswiftDemangle under \(toolchain.toolchainUsr)/lib")
        #expect(InProcessDemangler.load(toolchainUsr: "/nonexistent/usr") == nil)
    }

    @Test func inProcessAndSpawnedGiveTheSameText() throws {
        let symbols = try Self.fixed + symbolsOfACompiledModule()
        #expect(symbols.count > 60, "too few symbols to compare: \(symbols.count)")
        let library = try #require(InProcessDemangler.load(toolchainUsr: try ScanToolchain.current().toolchainUsr))
        let spawned = try #require(Demangler.spawned(symbols))
        var mismatches: [String] = []
        for symbol in symbols where library.demangle(symbol) != spawned[symbol] {
            mismatches.append("\(symbol): \(library.demangle(symbol)) vs \(spawned[symbol] ?? "nil")")
        }
        #expect(mismatches.isEmpty, "\(mismatches.count) of \(symbols.count) differ: \(mismatches.prefix(5))")
        #expect(library.demangle("$snotasymbol") == "$snotasymbol", "not a symbol: left as it is, as swift-demangle does")
        // A name longer than the first buffer.
        let name = String(repeating: "Long", count: 150)
        let long = "$s4Main\(name.count)\(name)V"
        #expect(library.demangle(long) == name, "simplified: no module")
        #expect(library.demangle(long) == Demangler.spawned([long])?[long])
        #expect(Demangler.demangle(symbols) == spawned, "the default path is the library and gives the same map")
    }

    /// Every `$s…` symbol in the SIL of a module with generics, protocols, closures, nested types and accessors.
    private func symbolsOfACompiledModule() throws -> [String] {
        let directory = NSTemporaryDirectory() + "sfv-demangle-\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: directory) }
        let file = directory + "/m.swift"
        try """
        public protocol Shape { var area: Double { get } }
        public struct Square: Shape, Hashable { public var side: Double; public var area: Double { side * side } }
        public enum Token: Equatable { case word(String), number(Int) }
        public struct Stack<Element> {
            var items: [Element] = []
            public mutating func push(_ e: Element) { items.append(e) }
            public subscript(i: Int) -> Element { items[i] }
            struct Inner { let x: Int8 }
        }
        public extension Int8 { func halved() -> Int8 { self / 2 } }
        public func apply<T>(_ f: (T) throws -> T, _ x: T) rethrows -> T { try f(x) }
        public func total(_ xs: [Int]) -> Int { xs.reduce(0) { $0 &+ $1 } }
        public final class Counter { public private(set) var count = 0; public func next() -> Int { count += 1; return count } }
        """.write(toFile: file, atomically: true, encoding: .utf8)
        let sil = try ModuleCompiler.emitSIL(CompileOptions(files: [file], moduleName: "Mangled"))
        let symbols = sil.matches(of: /@(\$s[A-Za-z0-9_]+)/).map { String($0.1) }
        return Array(Set(symbols)).sorted()
    }
}
