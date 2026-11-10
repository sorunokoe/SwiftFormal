import Foundation
import Testing
import SFProve
import SFSIL

/// String facts (`SILStringFacts.swift`): `_findStringSwitchCase` (a `String` raw-value `init(rawValue:)`), case
/// conversion of strings logic does not know, and the decimal text of an integer.
enum StringFactsFixture {
    static let source = """
        public enum Kind: String { case driver, iron, putter }
        public enum Accent: String { case plain = "e", accented = "\\u{E9}" }
        public enum Host { case home, api, portal }

        public func kindOf(_ s: String) -> Kind? { Kind(rawValue: s) }
        public func ironBoost(_ s: String, _ x: Int8) -> Int8 { if case .iron? = Kind(rawValue: s) { return x + 1 }; return x }
        public func literalKind(_ x: Int8) -> Int8 { if case .putter? = Kind(rawValue: "putter") { return x + 1 }; return x }
        public func neverKind(_ x: Int8) -> Int8 { if case .none = Kind(rawValue: "wood") { return x }; return x + 1 }
        public func roundTrip(_ k: Kind, _ x: Int8) -> Int8 {
            let back = Kind(rawValue: k.rawValue)
            switch k {
            case .driver: if case .driver? = back { return x }
            case .iron: if case .iron? = back { return x }
            case .putter: if case .putter? = back { return x }
            }
            return x + 1
        }
        public func plainBoost(_ s: String, _ x: Int8) -> Int8 { if case .plain? = Accent(rawValue: s) { return x + 1 }; return x }
        public func accentBoost(_ s: String, _ x: Int8) -> Int8 { if case .accented? = Accent(rawValue: s) { return x + 1 }; return x }

        public func host(_ input: String?) -> Host? {
            switch input?.lowercased() {
            case "home": .home
            case "api.example.org", "api.example.com": .api
            case "portal.example.com": .portal
            default: nil
            }
        }
        public func homeIsHome(_ input: String?, _ x: Int8) -> Int8 { input == "home" && host(input) != .home ? x + 1 : x }
        public func upperOfKnown(_ s: String, _ x: Int8) -> Int8 { s == "Home" && s.uppercased() != "HOME" ? x + 1 : x }
        public func lowerOfUnknown(_ s: String, _ x: Int8) -> Int8 { s.lowercased() == "home" ? x + 1 : x }
        public func lowerOfTwo(_ a: String, _ b: String, _ x: Int8) -> Int8 { a.lowercased() == b.lowercased() ? x + 1 : x }
        public func nonASCIILower(_ x: Int8) -> Int8 { "\\u{C9}".lowercased() == "\\u{E9}" ? x + 1 : x }
        public func lowerKeepsEmpty(_ s: String, _ x: Int8) -> Int8 { s.lowercased().isEmpty != s.isEmpty ? x + 1 : x }

        public func neverF(_ n: Int, _ x: Int8) -> Int8 { "\\(n)" == "F" ? x + 1 : x }
        public func eighteen(_ n: Int, _ x: Int8) -> Int8 { "\\(n)" == "18" ? x + 1 : x }
        public func leadingZeros(_ n: Int, _ x: Int8) -> Int8 { "\\(n)" == "007" ? x + 1 : x }
        public func minusZero(_ n: Int, _ x: Int8) -> Int8 { "\\(n)" == "-0" ? x + 1 : x }
        public func plusSign(_ n: Int, _ x: Int8) -> Int8 { "\\(n)" == "+5" ? x + 1 : x }
        public func neverEmpty(_ n: Int, _ x: Int8) -> Int8 { "\\(n)".isEmpty ? x + 1 : x }
        public func mostNegative(_ n: Int8, _ x: Int8) -> Int8 { String(n) == "-128" ? x + 1 : x }
        public func outOfRange(_ n: Int8, _ x: Int8) -> Int8 { n.description == "128" ? x + 1 : x }
        public func unsignedTop(_ n: UInt8, _ x: Int8) -> Int8 { String(describing: n) == "255" ? x + 1 : x }
        public func knownNumber(_ x: Int8) -> Int8 { "\\(42)" == "42" ? x + 1 : x }
        public func mixedText(_ a: Int, _ b: Int, _ x: Int8) -> Int8 { "\\(a)/\\(b)" == "1/2" ? x + 1 : x }
        """
    static let onone = try! SILCompiler.module(source: source, name: "Sf", optimization: .none)
    static func symbol(_ name: String) throws -> String { try onone.symbol(module: "Sf", name: name) }
}

@Suite(.tags(.slow)) struct SILStringFactsTests {
    private static func verdict(_ name: String) throws -> ProofVerdict {
        try SILVerifier.proveAggregate(try StringFactsFixture.symbol(name), in: StringFactsFixture.onone)
    }

    private static func text(_ handle: UInt64?) -> String? { handle.flatMap(StringIdentity.text(of:)) }

    @Test func aStringRawValueInitializerIsRead() throws {
        // `init(rawValue:)` calls `_findStringSwitchCase(cases:string:)` with the case texts as an array literal.
        #expect(try Self.verdict("kindOf") == .proved)
        #expect(try Self.verdict("neverKind") == .proved)
        #expect(try Self.verdict("roundTrip") == .proved)
        #expect(try Self.verdict("literalKind") == .counterexample([UInt64(Int8.max)]))
        guard case .counterexample(let v) = try Self.verdict("ironBoost") else {
            Issue.record("Kind(rawValue: \"iron\") then x + 1"); return
        }
        #expect(Self.text(v.first) == "iron" && v.last == UInt64(Int8.max), "\(v)")
    }

    @Test func aNonASCIICaseTextLeavesItsMatchUnknown() throws {
        // "e" is decided exactly; whether a string equals "é" is not (Swift's `==` is canonical equivalence).
        guard case .counterexample(let v) = try Self.verdict("plainBoost") else { Issue.record("Accent(rawValue: \"e\")"); return }
        #expect(Self.text(v.first) == "e", "\(v)")
        #expect(try Self.verdict("accentBoost") == .unknown)
    }

    @Test func caseConversionOfAStringThatIsLaterSeenAsALiteralIsKnown() throws {
        // `input?.lowercased()` comes before the literals it is compared with; the fact still applies to them.
        #expect(try Self.verdict("homeIsHome") == .proved)
        #expect(try Self.verdict("upperOfKnown") == .proved)
        #expect(try Self.verdict("lowerKeepsEmpty") == .proved)
    }

    @Test func caseConversionOfUnknownTextIsNeverProvedWrong() throws {
        // Real traps: "HOME".lowercased() == "home", two strings can lowercase alike, and "É".lowercased() == "é".
        for name in ["lowerOfUnknown", "lowerOfTwo"] {
            let verdict = try Self.verdict(name)
            #expect(verdict != .proved, "\(name)")
            if case .counterexample(let v) = verdict, name == "lowerOfUnknown" {
                #expect(Self.text(v.first)?.lowercased() == "home", "\(v)")
            }
        }
        #expect(try Self.verdict("nonASCIILower") == .unknown)
    }

    @Test func theDecimalTextOfAnIntegerIsExact() throws {
        for name in ["neverF", "leadingZeros", "minusZero", "plusSign", "neverEmpty", "outOfRange"] {
            #expect(try Self.verdict(name) == .proved, "\(name)")
        }
        #expect(try Self.verdict("eighteen") == .counterexample([18, UInt64(Int8.max)]))
        #expect(try Self.verdict("mostNegative") == .counterexample([0x80, UInt64(Int8.max)]))
        #expect(try Self.verdict("unsignedTop") == .counterexample([255, UInt64(Int8.max)]))
        #expect(try Self.verdict("knownNumber") == .counterexample([UInt64(Int8.max)]))
    }

    @Test func textMixingNumbersAndLiteralsIsNeverProvedWrong() throws {
        // "\(1)/\(2)" == "1/2": a real trap at x = 127.
        let verdict = try Self.verdict("mixedText")
        #expect(verdict != .proved)
        if case .counterexample(let v) = verdict { #expect(v == [1, 2, UInt64(Int8.max)], "\(v)") }
    }
}
