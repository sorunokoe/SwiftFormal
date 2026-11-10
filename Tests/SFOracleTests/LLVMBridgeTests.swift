import Foundation
import SFLLVM
import SFProve
import SFSIL
import SFTestSupport
import Testing

/// The SIL ≡ IR cross-check on app-shaped code (plan item 6 of round 6): structs passed in pieces and by reference,
/// `sret` results, enums, `Optional`, strings and closures as handles, and the stack memory `-Onone` code goes through.
/// Every function here must agree; every planted change to the IR must be caught.
private enum AppFixture {
    static let source = """
        public struct Club: Equatable {
            public var loft: Int
            public var isActive: Bool
            public var name: String
            public init(loft: Int, isActive: Bool, name: String) { self.loft = loft; self.isActive = isActive; self.name = name }
            public var doubled: Int { loft &* 2 }
        }
        public enum Kind: Equatable { case driver, iron, putter }
        public func describe(_ k: Kind) -> Int {
            switch k { case .driver: return 1; case .iron: return 2; case .putter: return 3 }
        }
        public struct Point: Equatable { public var x: Int32; public var y: Int32 }
        public func mk(_ a: Int32, _ b: Int32) -> Point { Point(x: a, y: b) }
        public func opt(_ x: Int?) -> Int { x ?? 0 }
        public struct Wide {
            public var a: Int
            public var b: Int
            public var c: Int
            public var label: String?
            public var handler: (() -> Void)?
            public var e: Bool
            public var isWide: Bool { e }
        }
        public func makeWide(_ x: Int, _ f: Bool) -> Wide { Wide(a: x, b: x &+ 1, c: 0, label: nil, handler: nil, e: f) }
        public enum Shot { case none, carry(Int), spin(Int32, Bool) }
        public func carried(_ s: Shot) -> Int { if case .carry(let c) = s { return c }; return 0 }
        public func maybeKind(_ b: Bool) -> Kind? { b ? .putter : nil }
        public func orFalse(_ b: Bool?) -> Bool { b ?? false }
        """

    static let sil = Result { try SILCompiler.module(source: source, optimization: .none) }
    static let irText = Result { try LLVMCompiler.emit(source: source, optimization: .none) }

    /// The one defined function whose mangled name contains `fragment`.
    static func symbol(_ fragment: String) throws -> String {
        let found = try LLVMModule(text: try irText.get()).symbols.filter { $0.contains(fragment) }
        guard found.count == 1 else { throw LLVMError.invalid("expected one symbol with \(fragment), found \(found)") }
        return found[0]
    }

    /// `text` with `from` replaced by `to` inside the body of `symbol` only.
    static func mutate(_ text: String, symbol: String, _ from: String, _ to: String) throws -> String {
        let start = try #require(text.range(of: "@\"\(symbol)\"(") ?? text.range(of: "@\(symbol)("))
        let end = try #require(text.range(of: "\n}\n", range: start.upperBound..<text.endIndex))
        let body = String(text[start.lowerBound..<end.lowerBound])
        try #require(body.contains(from), "no `\(from)` in \(symbol)")
        return text.replacingCharacters(in: start.lowerBound..<end.lowerBound, with: body.replacingOccurrences(of: from, with: to))
    }
}

@Suite(.tags(.oracle), .requiresPinnedCompiler) struct LLVMBridgeTests {
    /// Fragments of the mangled names of the functions the bridge must tie.
    static let agreeing = [
        "4ClubV4loftSivg",  // Int field of a struct passed in four pieces
        "4ClubV8isActiveSbvg",  // Bool field (i1)
        "4ClubV4nameSSvg",  // String result: two words
        "4ClubV4loft8isActive4nameACSi_SbSStcfC",  // memberwise init: aggregate result, stack slots
        "4ClubV7doubledSivg",
        "4KindO21__derived_enum_equals",  // plain enum tags as i8
        "8describe",  // switch over an enum
        "5PointV23__derived_struct_equals",  // two Int32 fields in one i64
        "2mk",  // a call, and a coerced i64 result written as two i32
        "3opt",  // Optional<Int>: payload and a tag byte where 1 means nil
        "4WideV02isB0Sbvg",  // self passed by reference (`isWide`)
        "4WideV5labelSSSgvg",  // Optional<String>, nil as zero words
        "4WideV7handleryycSgvg",  // Optional closure
        "8makeWide",  // sret result
        "7carried",  // multi-payload enum: a tag byte after the payload area
        "9maybeKind",  // Optional of an enum: nil is the first spare value of its byte
        "7orFalse",  // Optional<Bool>: nil is 2
    ]

    @Test(arguments: agreeing)
    func appShapedFunctionsAgree(_ fragment: String) throws {
        let symbol = try AppFixture.symbol(fragment)
        let verdict = try LLVMVerifier.proveEquivalentToSIL(
            symbol: symbol, silModule: try AppFixture.sil.get(), llvmModule: try LLVMModule(text: try AppFixture.irText.get()))
        #expect(verdict == .proved, "\(fragment): \(verdict)")
    }

    /// A deliberately wrong IR must not agree: each change moves a value to the wrong place in the bridge's layout.
    @Test(arguments: [
        ("4ClubV4loftSivg", "ret i64 %0", "ret i64 %2"),  // returns a String word instead of the Int
        ("4ClubV4nameSSvg", "i64 %2, 0", "i64 %0, 0"),  // the String's first word is the Int
        ("4ClubV4loft8isActive4nameACSi_SbSStcfC", "i1 %1, 1", "i1 false, 1"),  // init drops the Bool
        ("8describe", "[ 3,", "[ 2,"),  // the last enum case answers like the middle one
        ("3opt", "icmp eq i8 %7, 1", "icmp eq i8 %7, 0"),  // the Optional tag read the wrong way round
        ("4WideV5labelSSSgvg", "i64 %4, 1", "i64 %2, 1"),  // an Optional<String> with its words mixed up
        ("8makeWide", "i64 %5, i64 0,", "i64 %5, i64 1,"),  // the sret result gets c = 1
        ("7carried", "icmp ne i8 %1, 0", "icmp ne i8 %1, 1"),  // reads the payload of the other payload case
        ("9maybeKind", "[ 3, %2 ]", "[ 0, %2 ]"),  // nil written as .driver
        ("7orFalse", "icmp eq i8 %2, 2", "icmp eq i8 %2, 1"),  // true taken for nil
    ])
    func plantedChangesAreCaught(_ fragment: String, _ from: String, _ to: String) throws {
        let symbol = try AppFixture.symbol(fragment)
        let mutated = try LLVMModule(text: try AppFixture.mutate(try AppFixture.irText.get(), symbol: symbol, from, to))
        let verdict = try LLVMVerifier.proveEquivalentToSIL(symbol: symbol, silModule: try AppFixture.sil.get(), llvmModule: mutated)
        guard case .counterexample = verdict else {
            Issue.record("\(fragment): \(from) -> \(to) went unnoticed: \(verdict)")
            return
        }
    }

    /// What the bridge cannot tie is refused with a reason, never compared loosely.
    @Test func unbridgedSignaturesAreRefused() throws {
        let module = try LLVMModule(text: try AppFixture.irText.get())
        // A setter writes through `self`: its result is the memory, which the bridge does not compare yet.
        let setter = try AppFixture.symbol("4ClubV4loftSivs")
        #expect(throws: LLVMError.self) {
            _ = try LLVMVerifier.proveEquivalentToSIL(symbol: setter, silModule: try AppFixture.sil.get(), llvmModule: module)
        }
    }
}
