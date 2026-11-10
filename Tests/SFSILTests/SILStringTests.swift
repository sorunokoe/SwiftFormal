import Foundation
import Testing
import SFBV
import SFCNF
import SFProve
import SFSIL

/// Strings, hashing, `inout` parameters and protocol witnesses in real `swiftc` output.
enum StringFixture {
    static let source = """
        public enum Kind: String { case driver, iron, putter }
        public enum Surface { case grass, sand, water }
        public struct Named { public var name: String; public var n: Int32 }
        public struct Pt: Hashable { public var x: Int32; public var y: Int8?; public var surface: Surface; public var kind: Kind }
        public struct Score: CustomStringConvertible {
            public var v: Int32
            public var description: String { "\\(v + 1)" }
        }
        public struct Bad: Hashable {
            public var v: Int32
            public func hash(into h: inout Hasher) { h.combine(v + 1) }
        }
        public struct Wrap: Hashable { public var b: Bad; public var tag: String }
        public struct Counter { public var a: Int32; public var b: Int16 }
        @inline(never) public func ident<T>(_ x: T) -> T { x }

        public func label(_ k: Surface) -> String { switch k { case .grass: "Grass"; case .sand: "Sand"; case .water: "Water" } }
        public func nameOf(_ n: Named) -> String { n.name }
        public func mk(_ s: String, _ n: Int32) -> Named { Named(name: s, n: n) }
        public func orEmpty(_ s: String?) -> String { s ?? "" }
        public func code(_ s: String) -> Int32 { switch s { case "a": 1; case "b": 2; default: 0 } }
        public func text(_ x: Int32, _ k: Surface) -> String { "\\(x) at \\(label(k))" }
        public func kindText(_ k: Kind) -> String { k.rawValue }
        public func len(_ s: String) -> Int { s.count }
        public func lenPlusOne(_ s: String) -> Int { s.count + 1 }
        public func dependsOnEq(_ s: String, _ x: Int32) -> Int32 { s == "x" ? x + 1 : x }
        public func dependsOnEmpty(_ s: String, _ x: Int32) -> Int32 { s.isEmpty ? x + 1 : x &+ 1 }
        public func realTrap(_ s: String, _ x: Int32) -> Int32 { if s.isEmpty { return x + 1 }; return x + 1 }
        public func shown(_ s: Score) -> String { "\\(s)" }
        public func hashPt(_ p: Pt, _ h: inout Hasher) { p.hash(into: &h) }
        public func hashWrap(_ w: Wrap, _ h: inout Hasher) { w.hash(into: &h) }
        public func bump(_ c: inout Counter, _ by: Int32) { c.a &+= by; c.b = c.b &+ 1 }
        public func checkedBump(_ c: inout Counter) { c.a += 1 }
        public func callsGeneric(_ x: Int32) -> Int32 { ident(x) }
        public struct Outer { public var s: Score; public var n: Int8 }
        public enum Slot { case empty, held(Score), pair(Int8, Score) }
        public struct Mirrored: CustomReflectable { public var v: Int8; public var customMirror: Mirror { Mirror(self, children: []) } }
        public func shownOuter(_ o: Outer) -> String { "\\(o)" }
        public func shownSlot(_ s: Slot) -> String { String(describing: s) }
        public func shownTuple(_ t: (Int8, Score?)) -> String { "\\(t)" }
        public func shownPlain(_ c: Counter) -> String { "\\(c)" }
        public func shownMirrored(_ m: Mirrored) -> String { "\\(m)" }
        public struct Box<T> { public let v: T; public let n: Int8 }
        extension Box: CustomStringConvertible { public var description: String { fatalError() } }
        public struct HoldsBox { public var b: Box<Int8> }
        public func shownBox(_ b: Box<Int8>) -> String { "\\(b)" }
        public func shownHoldsBox(_ h: HoldsBox) -> String { "\\(h)" }
        public func lowerThenCompare(_ x: Int8) -> Int8 { "Sand".lowercased() == "sand" ? x + 1 : x }
        public func crlfIsOneCharacter(_ x: Int8) -> Int8 { "\\r\\n".count == 1 ? x + 1 : x }
        public func ordered(_ x: Int8) -> Int8 { "Grass" < "Water" ? x + 1 : x }
        public func joinedLiterals(_ x: Int8) -> Int8 { "Gra" + "ss" == "Grass" ? x + 1 : x }
        public func emptyPrefix(_ s: String, _ x: Int8) -> Int8 { s.hasPrefix("") && s.hasSuffix(s) ? x : x + 1 }
        public func appendKeepsText(_ s: String, _ x: Int8) -> Int8 { var t = s; t += ""; return t == s ? x : x + 1 }
        public func notEmptyAfterJoin(_ s: String, _ x: Int8) -> Int8 { ("a" + s).isEmpty ? x + 1 : x }
        public func precomposed(_ x: Int8) -> Int8 { "\\u{E9}" == "e\\u{301}" ? x + 1 : x }
        public func greekQuestionMark(_ x: Int8) -> Int8 { ";" == "\\u{37E}" ? x + 1 : x }
        """
    static let onone = try! SILCompiler.module(source: source, name: "St", optimization: .none)
    static func symbol(_ name: String) throws -> String { try onone.symbol(module: "St", name: name) }
}

@Suite(.tags(.slow)) struct SILStringTests {
    private static func verdict(_ name: String) throws -> ProofVerdict {
        try SILVerifier.proveAggregate(try StringFixture.symbol(name), in: StringFixture.onone)
    }

    @Test func stringCodeThatCannotTrapIsProved() throws {
        for name in ["label", "nameOf", "mk", "orEmpty", "code", "text", "kindText", "len", "hashPt", "bump"] {
            #expect(try Self.verdict(name) == .proved, "\(name)")
        }
    }

    @Test func equalityAndEmptinessOfStringsAreExact() throws {
        // A string is the handle of its value, and an ASCII literal has a fixed handle: `s == "x"` and `s.isEmpty`
        // pick out exactly one string, so the overflow behind them is a real bug with a real input.
        guard case .counterexample(let eq) = try Self.verdict("dependsOnEq") else { Issue.record("s == \"x\" then x + 1"); return }
        #expect(eq.first.flatMap(StringIdentity.text(of:)) == "x" && eq.last == UInt64(Int32.max), "\(eq)")
        guard case .counterexample(let empty) = try Self.verdict("dependsOnEmpty") else { Issue.record("isEmpty then x + 1"); return }
        #expect(empty.first.flatMap(StringIdentity.text(of:)) == "", "\(empty)")
        // The length of a string that is not a literal stays unknown: neither proved nor reported.
        #expect(try Self.verdict("lenPlusOne") == .unknown)
    }

    @Test func operationsOnKnownTextsAreComputed() throws {
        // Each of these overflows at Int8.max exactly because the text operation gives true, as it does in Swift.
        for name in ["lowerThenCompare", "crlfIsOneCharacter", "ordered", "joinedLiterals"] {
            #expect(try Self.verdict(name) == .counterexample([UInt64(Int8.max)]), "\(name)")
        }
        // Facts that hold for every string, known or not.
        for name in ["emptyPrefix", "appendKeepsText", "notEmptyAfterJoin"] {
            #expect(try Self.verdict(name) == .proved, "\(name)")
        }
    }

    @Test func nonASCIITextsThatSwiftCallsEqualAreNeverProvedDifferent() throws {
        // Swift's `==` is canonical equivalence: both comparisons are true, so both functions overflow at 127.
        // Logic does not decide non-ASCII literals; it must never call these functions safe.
        for name in ["precomposed", "greekQuestionMark"] {
            #expect(try Self.verdict(name) == .unknown, "\(name)")
        }
    }

    @Test func silStringLiteralsAreDecoded() {
        #expect(StringIdentity.unescapeSIL(#"a\"b\\c\n\t\u{01}é"#) == "a\"b\\c\n\t\u{01}é")
        #expect(StringIdentity.unescapeSIL(#"bad\q"#) == nil)
        #expect(StringIdentity.swiftLiteral("a\"b\n") == #""a\"b\n""#)
        #expect(StringIdentity.id(of: "é") == nil, "non-ASCII texts have no fixed handle")
        #expect(StringIdentity.id(of: "Grass").flatMap(StringIdentity.text(of:)) == "Grass")
    }

    @Test func aTrapThatHappensWhateverTheStringIsIsFound() throws {
        guard case .counterexample(let v) = try Self.verdict("realTrap") else {
            Issue.record("x + 1 overflows for every string"); return
        }
        #expect(v.last == UInt64(Int32.max), "\(v)")
    }

    @Test func userCodeBehindWitnessesIsChecked() throws {
        // String interpolation calls Score.description, whose `v + 1` overflows.
        guard case .counterexample(let s) = try Self.verdict("shown") else {
            Issue.record("description traps at Int32.max"); return
        }
        #expect(s == [UInt64(Int32.max)])
        // The synthesized Wrap.hash(into:) calls Hasher.combine(b), which runs Bad.hash(into:) and its `v + 1`.
        guard case .counterexample(let w) = try Self.verdict("hashWrap") else {
            Issue.record("Bad.hash(into:) traps at Int32.max"); return
        }
        #expect(w.first == UInt64(Int32.max), "\(w)")
    }

    @Test func printingWithoutADescriptionRunsTheDescriptionsOfTheParts() throws {
        // Swift prints a value without a description of its own by reflection, which runs each part's description.
        for name in ["shownOuter", "shownSlot", "shownTuple"] {
            guard case .counterexample = try Self.verdict(name) else { Issue.record("\(name): Score.description traps"); continue }
        }
        #expect(try Self.verdict("shownPlain") == .proved)
        #expect(throws: SILError.self) { try Self.verdict("shownMirrored") }
        // A generic conformance's witness is not called, so printing such a type is refused rather than skipped.
        #expect(throws: SILError.self) { try Self.verdict("shownBox") }
        #expect(throws: SILError.self) { try Self.verdict("shownHoldsBox") }
    }

    @Test func inoutParametersAreWrittenBack() throws {
        let function = try StringFixture.onone.function(try StringFixture.symbol("bump"))
        var state: UInt64 = 0x1234_5678
        for _ in 0..<200 {
            state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
            let a = Int32(truncatingIfNeeded: state >> 7), b = Int16(truncatingIfNeeded: state >> 41)
            let by = Int32(truncatingIfNeeded: state >> 23)
            let c = CNFBuilder()
            let inputs = zip(
                function.parameterWidths, [UInt64(UInt32(bitPattern: a)), UInt64(UInt16(bitPattern: b)), UInt64(UInt32(bitPattern: by))]
            )
            .map { c.constant($1, width: $0) }
            let e = try SILEncoder(module: StringFixture.onone, builder: c).encode(
                symbol: try StringFixture.symbol("bump"), arguments: inputs)
            #expect(e.trap == c.falseLit)
            let written = try e.writtenBack.map { try #require(c.constantValue($0)) }
            #expect(written == [UInt64(UInt32(bitPattern: a &+ by)), UInt64(UInt16(bitPattern: b &+ 1))], "a \(a) b \(b) by \(by)")
        }
        guard case .counterexample(let v) = try Self.verdict("checkedBump") else {
            Issue.record("c.a += 1 overflows"); return
        }
        #expect(v.first == UInt64(Int32.max))
    }

    /// Plan item L7: a generic function of the module is read at the call's concrete type (`ident<Int32>`).
    @Test func genericCallsOfUserCodeAreReadAtTheCallsTypes() throws {
        #expect(try Self.verdict("callsGeneric") == .proved)
    }
}
