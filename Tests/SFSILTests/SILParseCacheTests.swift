import Foundation
import SFSIL
import Testing

/// Plan item S7: a module parses each body once, and a change to the module (linking another) is never answered from
/// the bodies parsed before it.
@Suite struct SILParseCacheTests {
    static let first = """
        public struct Row { public var a: Int8 }
        public func width(_ r: Row) -> Int8 { r.a }
        """
    static let second = "public struct Row { public var b: Int16 }\npublic func other(_ r: Row) -> Int16 { r.b }"

    @Test func aParsedFunctionIsTheSameEveryTime() throws {
        let module = try SILCompiler.module(source: Self.first, name: "One", optimization: .none)
        let symbol = try module.symbol(module: "One", name: "width")
        #expect(try module.function(symbol).parameterWidths == [8])
        #expect(try module.function(symbol).parameterWidths == [8])
    }

    /// After linking a module that also declares `Row`, the name is ambiguous: the function that uses it is refused,
    /// though it was parsed before the link.
    @Test func linkingStartsAFreshCache() throws {
        var module = try SILCompiler.module(source: Self.first, name: "One", optimization: .none)
        let symbol = try module.symbol(module: "One", name: "width")
        let before = module
        _ = try module.function(symbol)
        module.link(try SILCompiler.module(source: Self.second, name: "Two", optimization: .none))
        #expect(throws: SILError.self) { _ = try module.function(symbol) }
        #expect(try before.function(symbol).parameterWidths == [8], "the copy from before the link keeps its own parses")
    }
}
