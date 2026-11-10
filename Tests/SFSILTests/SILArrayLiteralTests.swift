import Foundation
import Testing
import SFProve
import SFSIL

/// The elements of an array literal the code builds are known (`SILArrayLiterals.swift`), in real `swiftc` output, as
/// long as nothing can have changed them: a write through the subscript forgets them, so does any count change.
enum ArrayLiteralFixture {
    static let source = """
        public struct Row: Equatable { public var kind: Int8; public var on: Bool }
        public func rows() -> [Row] { [Row(kind: 1, on: false), Row(kind: 0, on: true)] }

        public func pick(_ i: Int) -> Int8 { let a: [Int8] = [10, 20, 30]; return i >= 0 && i < 3 ? a[i] + 97 : 0 }
        public func pickOver(_ i: Int) -> Int8 { let a: [Int8] = [10, 31, 20]; return i >= 0 && i < 3 ? a[i] + 97 : 0 }
        public func outOfRange(_ i: Int) -> Int8 { let a: [Int8] = [10, 20, 30]; return a[i] }
        public func rowKind(_ x: Int8) -> Int8 { let r = rows(); return r[1].on ? x / r[0].kind : 0 }
        public func rowKindZero(_ x: Int8) -> Int8 { let r = rows(); return r[1].on ? x / r[1].kind : 0 }
        public func ends(_ x: Int8) -> Int8 { let a: [Int8] = [2, 0, 4]; return x / (a.first! - a.last! + 3) }
        public func written(_ x: Int8) -> Int8 { var a: [Int8] = [1, 2]; a[0] = 0; return x / a[0] }
        public func writtenCopy(_ x: Int8) -> Int8 { var a: [Int8] = [0, 2]; let b = a; a[0] = 1; return x / a[0] + b[1] }
        public func zero(_ a: inout [Int8]) { a[0] = 0 }
        public func writtenByCallee(_ x: Int8) -> Int8 { var a: [Int8] = [1, 2]; zero(&a); return x / a[0] }
        public func appended(_ x: Int8) -> Int8 { var a: [Int8] = [1]; a.append(0); return x / a[0] }
        public func repeated(_ x: Int8) -> Int8 { let a: [Int8] = [1, 2]; let b = [Int8](repeating: 0, count: a.count); return x / b[0] }
        public func repeatedEnd(_ x: Int8) -> Int8 { let a: [Int8] = [1, 2]; let b = [Int8](repeating: 0, count: a.endIndex); return x / b[1] }
        public func repeatedIndices(_ x: Int8) -> Int8 {
            let a: [Int8] = [1, 2]
            let b = [Int8](repeating: 0, count: a.indices.upperBound)
            return x / b[0]
        }
        """
    static let module = try! SILCompiler.module(source: source, name: "Al", optimization: .none)

    static func verdict(_ name: String) throws -> ProofVerdict {
        try SILVerifier.proveAggregate(try module.symbol(module: "Al", name: name), in: module)
    }
}

@Suite(.tags(.slow)) struct SILArrayLiteralTests {
    @Test func aLiteralsElementsAreKnown() throws {
        #expect(try ArrayLiteralFixture.verdict("pick") == .proved)
        #expect(try ArrayLiteralFixture.verdict("rowKind") == .proved)
        #expect(try ArrayLiteralFixture.verdict("ends") == .proved)
        guard case .counterexample(let inputs) = try ArrayLiteralFixture.verdict("pickOver") else {
            Issue.record("pickOver overflows for 1")
            return
        }
        #expect(inputs == [1])
        guard case .counterexample = try ArrayLiteralFixture.verdict("rowKindZero") else {
            Issue.record("rowKindZero divides by rows()[1].kind, which is 0")
            return
        }
        guard case .counterexample = try ArrayLiteralFixture.verdict("outOfRange") else {
            Issue.record("outOfRange traps for 3")
            return
        }
    }

    @Test func aWriteOrACountChangeForgetsTheElements() throws {
        // Each of these divides by an element that is 0 after the write, or may be: never proved.
        for name in ["written", "writtenByCallee", "appended"] {
            #expect(try ArrayLiteralFixture.verdict(name) != .proved, "\(name)")
        }
        // A count read as an `Int` and turned into another array's count: that array is not the literal (it is zeros).
        for name in ["repeated", "repeatedEnd", "repeatedIndices"] {
            #expect(try ArrayLiteralFixture.verdict(name) != .proved, "\(name)")
        }
        // The copy `b` shares the literal's elements, but a write through `a` forgets them for both: not proved either
        // (`b[1]` is 2 and `a[0]` 1, so it is safe; logic only loses precision).
        #expect(try ArrayLiteralFixture.verdict("writtenCopy") != .proved)
    }
}
