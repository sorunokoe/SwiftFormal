import SFSIL
import SFTestSupport
import Testing

/// `ClosureComparison` gives the answer of comparing `ProofCache.closureText` in both modules, for every function.
@Suite struct ClosureComparisonTests {
    static let source = """
        public protocol Shape { func area() -> Int }
        public struct Square: Shape { public var side: Int; public func area() -> Int { side * side } }
        public func identity<T>(_ value: T) -> T { value }
        public func clamp(_ x: Int, _ hi: Int) -> Int { x > hi ? hi : x }
        public func area(_ side: Int) -> Int { clamp(Square(side: side).area(), 100) }
        public func twice(_ x: Int) -> Int { identity(x) * 2 }
        public func alone(_ x: Int) -> Int { x &+ 1 }
        """

    @Test(arguments: [
        ("same code", source),
        ("a callee changed", source.replacingOccurrences(of: "x > hi", with: "x >= hi")),
        ("a witness changed", source.replacingOccurrences(of: "side * side", with: "side &* side")),
    ])
    func agreesWithComparingTheClosureTexts(_ change: String, _ changed: String) throws {
        let first = try SILCompiler.module(source: Self.source, optimization: .none)
        let second = try SILCompiler.module(source: changed, optimization: .none)
        var comparison = ClosureComparison(first: first, second: second)
        // Prepared on several threads first, for every function: the answers must be the same.
        var prepared = ClosureComparison(first: first, second: second)
        prepared.prepare(first.symbols)
        var unchanged: [String: Bool] = [:]
        for symbol in first.symbols {
            let a = try? ProofCache.closureText(of: symbol, in: first)
            let b = try? ProofCache.closureText(of: symbol, in: second)
            let expected = a != nil && a == b
            #expect(comparison.isUnchanged(symbol) == expected, "\(change): \(symbol)")
            #expect(prepared.isUnchanged(symbol) == expected, "prepared, \(change): \(symbol)")
            unchanged[symbol] = expected
        }
        let area = try first.symbol(module: "Fixture", name: "area")
        let twice = try first.symbol(module: "Fixture", name: "twice")
        #expect(unchanged[area] == (change == "same code"))
        #expect(unchanged[twice] == (change != "a witness changed"))
    }
}
