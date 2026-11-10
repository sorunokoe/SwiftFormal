import Foundation
import SFSIL
import Testing

@testable import SFVerifyKit

/// `sfverify --mutate` edits the function, never the checks `@Verify` writes into it: an edit of a `#requires` or
/// `#ensures` check changes the contract, not what the function does, so it says nothing about the contract's strength
/// (an app's run listed "it returns true instead" and "the cases .some and .none are swapped" inside those checks).
/// The checks are found by their shape: values whose only use is a branch into a `Contract.requiresFailed` /
/// `ensuresFailed` call, and the closures whose result is such a value. The source is what `@Verify` writes.
@Suite struct VerifyCheckMutationTests {
    static let app = """
        import SwiftFormal

        public func pick(_ x: Int8?, _ y: Int8) -> Int8 {
            if !(y >= 0 && y < 100) { SwiftFormal.Contract.requiresFailed("y >= 0 && y < 100") }
            let __sf_result: Int8 = { () -> Int8 in
                if let x { return x < y ? y : x }
                return y
            }()
            if !(({ r in
                if let x { return r >= x && r >= y }
                return r == y
            })(__sf_result)) { SwiftFormal.Contract.ensuresFailed("{ r in … }") }
            return __sf_result
        }
        #sourceLocation(file: "@__swiftmacro_3App4pick6VerifyfMp_.swift", line: 1)
        public func pick_requires(_ x: Int8?, _ y: Int8) -> Bool { (y >= 0 && y < 100) }
        #sourceLocation()

        // A `mutating` method: both closures capture `self` (`@inout_aliasable`); the `#ensures` one is still a check.
        public struct Strokes {
            public var count: UInt8
            public mutating func add(_ extra: UInt8) -> Bool {
                let __sf_old = self
                let __sf_result: Bool = { () -> Bool in
                    guard extra <= UInt8.max - count else { return false }
                    count += extra
                    return extra > 0
                }()
                if !(({ added, old in added == (count > old.count) })(__sf_result, __sf_old)) {
                    SwiftFormal.Contract.ensuresFailed("{ added, old in added == (count > old.count) }")
                }
                return __sf_result
            }
            #sourceLocation(file: "@__swiftmacro_3App3add6VerifyfMp_.swift", line: 1)
            public func add_ensures(_ extra: UInt8, _ __sf_result: Bool, old: Self) -> Bool {
                ({ added, old in added == (count > old.count) })(__sf_result, old)
            }
            #sourceLocation()
        }
        #sourceLocation(file: "@__swiftmacro_3App4pick6VerifyfMp_.swift", line: 1)
        public func pick_ensures(_ x: Int8?, _ y: Int8, _ __sf_result: Int8) -> Bool {
            ({ r in
                if let x { return r >= x && r >= y }
                return r == y
            })(__sf_result)
        }
        #sourceLocation()
        """

    static func compiled(_ optimization: Optimization) throws -> CompiledModule {
        let dir = NSTemporaryDirectory() + "sfv-check-mutation-\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: dir) }
        let stubFile = dir + "/SwiftFormal.swift", appFile = dir + "/App.swift"
        try VerifyContractScanTests.stub.write(toFile: stubFile, atomically: true, encoding: .utf8)
        try app.write(toFile: appFile, atomically: true, encoding: .utf8)
        let module = Process()
        module.executableURL = URL(fileURLWithPath: "/usr/bin/xcrun")
        module.arguments = [
            "swiftc", "-emit-module", "-parse-as-library", "-module-name", "SwiftFormal", stubFile,
            "-emit-module-path", dir + "/SwiftFormal.swiftmodule",
        ]
        try module.run()
        module.waitUntilExit()
        try #require(module.terminationStatus == 0)
        var options = CompileOptions(files: [appFile], moduleName: "App", extraArguments: ["-I", dir])
        options.optimization = optimization
        return try ModuleCompiler.compile(options)
    }

    static func mutants(_ optimization: Optimization, of name: String = "pick(") throws -> (symbol: String, mutants: [SILMutant]) {
        let compiled = try compiled(optimization)
        let function = try #require(compiled.functions.first { $0.displayName.hasPrefix(name) })
        return (function.symbol, compiled.module.mutants(of: function.symbol, limit: 1_000))
    }

    /// The `#ensures` closure of a `mutating` method reads `self` through a capture (`@inout_aliasable`), which writes
    /// nothing: its call is still only a check, and the body closure (which changes `count`) is still edited.
    @Test func theEnsuresClosureOfAMutatingMethodIsNotEdited() throws {
        let (_, mutants) = try Self.mutants(.none, of: "Strokes.add(")
        let descriptions = mutants.map { "\($0.symbol.suffix(5)): \($0.description)" }
        #expect(!mutants.contains { $0.symbol.hasSuffix("fU0_") }, "\(descriptions)")
        #expect(mutants.contains { $0.symbol.hasSuffix("fU_") && $0.kind == .droppedWrite }, "\(descriptions)")
    }

    @Test func theEnsuresClosureAndTheRequiresConditionAreNotEdited() throws {
        let (symbol, mutants) = try Self.mutants(.none)
        let descriptions = mutants.map {
            "\($0.symbol.hasSuffix("fU0_") ? "ensures closure" : $0.symbol == symbol ? "pick" : "body"): \($0.description)"
        }
        // Closure #2 is the `#ensures` check; closure #1 is the body, which is the function's code.
        #expect(!mutants.contains { $0.symbol.hasSuffix("fU0_") }, "\(descriptions)")
        #expect(mutants.contains { $0.symbol.hasSuffix("fU_") && $0.kind == .changedOperator }, "\(descriptions)")
        #expect(mutants.contains { $0.symbol.hasSuffix("fU_") && $0.kind == .negatedBranch }, "\(descriptions)")
        // In `pick` itself everything but `return __sf_result` is a check: `y >= 0 && y < 100` with the blocks of its
        // `&&`, the branch, and the call of the ensures closure. Returning another value is an edit of the function.
        #expect(mutants.filter { $0.symbol == symbol }.allSatisfy { $0.kind == .returnedValue }, "\(descriptions)")
        #expect(!descriptions.contains("pick: the constant 100 becomes 101") && !descriptions.contains("pick: >= becomes >"))
    }

    /// With `-O` the closures are inlined into `pick`: the edits left are of the body's code, none of the checks'.
    @Test func withOptimizationOnlyTheBodyIsEdited() throws {
        let (_, mutants) = try Self.mutants(.speed)
        let descriptions = mutants.map(\.description)
        #expect(!mutants.isEmpty)
        #expect(
            !descriptions.contains("the constant 100 becomes 101") && !descriptions.contains("the constant 100 becomes 99"),
            "\(descriptions)")
    }
}
