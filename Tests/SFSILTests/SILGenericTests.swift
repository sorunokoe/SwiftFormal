import Foundation
import SFBV
import SFCNF
import SFProve
import SFSIL
import SFTestSupport
import Testing

/// Plan item L7: calls to the module's own generic functions at `-Onone`, read at the call site's concrete types.
/// A generic function itself is never read "for all T".
enum GenericFixture {
    static let source = """
        public protocol Shape { func area() -> Int8 }
        public struct Square: Shape { public var side: Int8; public func area() -> Int8 { side * side } }
        public struct Unit: Shape { public func area() -> Int8 { 1 } }
        public protocol Doubler { func doubled() -> Int8 }
        public extension Doubler where Self: Shape { func doubled() -> Int8 { area() &* 2 } }
        extension Unit: Doubler {}
        public struct Wrapper<Inner> { public var inner: Inner }
        extension Wrapper: Shape where Inner: Shape { public func area() -> Int8 { inner.area() } }
        public func clampG<T: Comparable>(_ x: T, _ lo: T, _ hi: T) -> T { x < lo ? lo : (x > hi ? hi : x) }
        public func clampHand(_ x: Int8) -> Int8 { x < -10 ? -10 : (x > 10 ? 10 : x) }
        public func useClamp(_ x: Int8) -> Int8 { clampG(x, -10, 10) }
        public func useClampU(_ x: UInt16) -> UInt16 { clampG(x, 3, 300) }
        public func clampHandU(_ x: UInt16) -> UInt16 { x < 3 ? 3 : (x > 300 ? 300 : x) }
        public func same<T: Equatable>(_ a: T, _ b: T) -> Bool { a == b }
        public func useSame(_ a: Int, _ b: Int) -> Bool { same(a, b) }
        public func sameHand(_ a: Int, _ b: Int) -> Bool { a == b }
        public func lessEq<T: Comparable>(_ a: T, _ b: T) -> Bool { a <= b }
        public func useLessEq(_ a: Int8, _ b: Int8) -> Bool { lessEq(a, b) }
        public func lessEqHand(_ a: Int8, _ b: Int8) -> Bool { a <= b }
        public func atLeast<T: Comparable>(_ a: T, _ b: T) -> Bool { a >= b }
        public func useAtLeast(_ a: UInt8, _ b: UInt8) -> Bool { atLeast(a, b) }
        public func atLeastHand(_ a: UInt8, _ b: UInt8) -> Bool { a >= b }
        public func areaPlusOne<S: Shape>(_ s: S) -> Int8 { s.area() + 1 }
        public func useArea(_ side: Int8) -> Int8 { areaPlusOne(Square(side: side)) }
        public func useUnit() -> Int8 { areaPlusOne(Unit()) }
        public func twice<S: Doubler>(_ s: S) -> Int8 { s.doubled() }
        public func useDefault() -> Int8 { twice(Unit()) }
        public func ident<T>(_ x: T) -> T { x }
        public func useIdent(_ v: Int8) -> Int8 { ident(v) + 1 }
        public func outer<T>(_ x: T) -> T { ident(ident(x)) }
        public func useOuter(_ v: Int8) -> Int8 { outer(v) &+ 1 }
        public func useWrapper(_ side: Int8) -> Int8 { areaPlusOne(Wrapper(inner: Square(side: side))) }
        public func areaAny(_ s: any Shape) -> Int8 { ident(s).area() }
        public func countDownG<T: BinaryInteger>(_ n: T) -> T { n == 0 ? 0 : countDownG(n - 1) }
        public func useCountDown(_ n: Int8) -> Int8 { countDownG(n) }
        public func firstOf<C: Collection>(_ c: C) -> C.Element? { c.first }
        public func useFirstOf(_ a: [Int8]) -> Int8? { firstOf(a) }
        """
    static let onone = try! SILCompiler.module(source: source, name: "Gn", optimization: .none)
    static func symbol(_ name: String) throws -> String { try onone.symbol(module: "Gn", name: name) }

    static func unsupportedReason(_ name: String) throws -> String? {
        do {
            _ = try SILVerifier.prove(try symbol(name), in: onone)
            return nil
        } catch let error as SILError {
            if case .unsupported(let reason) = error { return reason }
            throw error
        }
    }
}

@Suite struct SILGenericTests {
    /// The plan's acceptance test: `clampG<Int8>` read at the call site equals the hand-specialized clamp on every input.
    @Test func aGenericCallAtAConcreteTypeEqualsTheHandSpecializedFunction() throws {
        let m = GenericFixture.onone
        for (generic, hand) in [
            ("useClamp", "clampHand"), ("useClampU", "clampHandU"), ("useSame", "sameHand"), ("useLessEq", "lessEqHand"),
            ("useAtLeast", "atLeastHand"),
        ] {
            let verdict = try SILVerifier.proveEquivalent(
                try GenericFixture.symbol(generic), in: m, try GenericFixture.symbol(hand), in: m)
            #expect(verdict == .proved, "\(generic) vs \(hand): \(verdict)")
        }
    }

    @Test func aTrapInsideTheGenericBodyOrItsWitnessIsFound() throws {
        let m = GenericFixture.onone
        // `ident(v) + 1` traps at 127; `Square.area()` (reached through `witness_method`) overflows at side 12.
        guard case .counterexample(let v) = try SILVerifier.prove(try GenericFixture.symbol("useIdent"), in: m) else {
            Issue.record("useIdent should trap")
            return
        }
        #expect(v == [127])
        guard case .counterexample(let side) = try SILVerifier.prove(try GenericFixture.symbol("useArea"), in: m) else {
            Issue.record("useArea should trap")
            return
        }
        let s = Int(Int8(bitPattern: UInt8(side[0])))
        #expect(s * s + 1 > 127, "side \(s) must overflow")
        #expect(try SILVerifier.prove(try GenericFixture.symbol("useUnit"), in: m) == .proved)
        #expect(try SILVerifier.prove(try GenericFixture.symbol("useOuter"), in: m) == .proved)
    }

    @Test func aDefaultImplementationInAProtocolExtensionIsReadAtTheConcreteType() throws {
        let m = GenericFixture.onone
        let verdict = try SILVerifier.prove(
            try GenericFixture.symbol("useDefault"), in: m, ensures: { c, _, r in c.eq(r, c.constant(2, width: 8)) })
        #expect(verdict == .proved)
    }

    @Test func theGenericFunctionItselfIsNeverReadForAllT() throws {
        for name in ["clampG", "ident", "areaPlusOne"] {
            #expect(throws: SILError.self) { try SILVerifier.prove(try GenericFixture.symbol(name), in: GenericFixture.onone) }
        }
    }

    @Test func whatCannotBeMonomorphisedIsRefusedWithTheReason() throws {
        // A conditional conformance (`Wrapper<Inner>: Shape where Inner: Shape`): its table is generic.
        let wrapper = try #require(try GenericFixture.unsupportedReason("useWrapper"))
        #expect(wrapper.contains("Wrapper<Square>"), "\(wrapper)")
        // An existential substitution.
        let existential = try #require(try GenericFixture.unsupportedReason("areaAny"))
        #expect(existential.contains("any Shape"), "\(existential)")
        // A protocol whose witness for a standard type is not in the module (`BinaryInteger.-` on Int8), or recursion.
        #expect(try GenericFixture.unsupportedReason("useCountDown") != nil)
        // An associated type (`C.Element`) or a standard-library generic body is not monomorphised.
        #expect(try GenericFixture.unsupportedReason("useFirstOf") != nil)
    }

    /// A generic callee does not parse on its own, but its body is read at the call's types, and so is what it calls:
    /// both must be part of a cached proof's key.
    @Test func theProofCacheKeyCoversTheGenericCalleesBody() throws {
        func key(_ source: String) throws -> String {
            let module = try SILCompiler.module(source: source, optimization: .none)
            return try ProofCache.key(
                symbol: try module.symbol(module: "Fixture", name: "useTwice"), in: module, claimID: "c",
                fingerprint: try CompilerFingerprint.current(optimization: .none))
        }
        let generic = """
            func twiceG<T: FixedWidthInteger>(_ x: T) -> T { helper(x) }
            func helper<T: FixedWidthInteger>(_ x: T) -> T { x }
            public func useTwice(_ a: Int8) -> Int8 { twiceG(a) }
            """
        let otherGeneric = generic.replacingOccurrences(of: "-> T { x }", with: "-> T { x &+ x }")
        #expect(try key(generic) != (try key(otherGeneric)), "generic callee body")
    }

    /// Text-level checks of the substitution, on hand-written SIL: a parameter named like a declared type, a lowercase
    /// name and a quoted occurrence.
    @Test func theSubstitutionRefusesNamesItCannotTellApart() throws {
        let sil = """
            sil_stage canonical

            struct Item {
              @_hasStorage var v: Int8 { get set }
            }

            sil hidden @$s2Gx3idAyxxlF : $@convention(thin) <Item> (@in_guaranteed Item) -> @out Item {
            bb0(%0 : $*Item, %1 : $*Item):
              copy_addr %1 to [init] %0
              %3 = tuple ()
              return %3
            }

            sil hidden @$s2Gx3idByxxlF : $@convention(thin) <T> (@in_guaranteed T) -> @out T {
            bb0(%0 : $*T, %1 : $*T):
              %2 = string_literal utf8 "T"
              copy_addr %1 to [init] %0
              %4 = tuple ()
              return %4
            }

            sil hidden @$s2Gx3idCyxxlF : $@convention(thin) <t> (@in_guaranteed t) -> @out t {
            bb0(%0 : $*t, %1 : $*t):
              copy_addr %1 to [init] %0
              %3 = tuple ()
              return %3
            }
            """
        let module = try SILModule(text: sil)
        #expect(throws: SILError.self) { try module.specialize("$s2Gx3idAyxxlF", ["Int8"]) }
        #expect(throws: SILError.self) { try module.specialize("$s2Gx3idCyxxlF", ["Int8"]) }
        #expect(throws: SILError.self) { try module.specialize("$s2Gx3idByxxlF", ["Int8", "Int8"]) }
        #expect(throws: SILError.self) { try module.specialize("$s2Gx3idByxxlF", ["τ_0_0"]) }
        #expect(throws: SILError.self) { try module.specialize("$s2Gx3idByxxlF", ["any Equatable"]) }
        #expect(throws: SILError.self) { try module.specialize("$s2Gx3idByxxlF", ["Nope"]) }
        let key = try module.specialize("$s2Gx3idByxxlF", ["Item"])
        let function = try module.function(key)
        #expect(function.parameterTypes == [try module.resolve("Item")])
        #expect(function.conventions == [.indirect])
    }
}
