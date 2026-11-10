import Foundation
import Testing
import SFBV
import SFCNF
import SFProve
import SFSIL

/// Foundation and SwiftUI values held as opaque identities (`SILOpaqueValues.swift`), in real `swiftc` output. The
/// fixture is shaped like a Composable Architecture state: one `UUID` or `URL` used to make every accessor of it
/// unsupported.
enum OpaqueFixture {
    static let source = """
        import Foundation
        import SwiftUI

        public struct Item: Equatable, Hashable {
            public let id: UUID
            public var url: URL?
            public var count: Int
            public var locale: Locale
            public var day: Date
            public var tint: Color
        }
        public func getID(_ s: Item) -> UUID { s.id }
        public func getURL(_ s: Item) -> URL? { s.url }
        public func setURL(_ s: inout Item, _ u: URL?) { s.url = u }
        public func getCount(_ s: Item) -> Int { s.count }
        public func setCount(_ s: inout Item, _ n: Int) { s.count = n }
        public func setTint(_ s: inout Item, _ c: Color) { s.tint = c }
        public func make(_ id: UUID, _ u: URL?, _ l: Locale, _ d: Date, _ c: Color) -> Item {
            Item(id: id, url: u, count: 0, locale: l, day: d, tint: c)
        }
        public func same(_ a: Item, _ b: Item) -> Bool { a == b }
        public func hashItem(_ s: Item, _ h: inout Hasher) { s.hash(into: &h) }
        public func hashValueOf(_ s: Item) -> Int { s.hashValue }
        public func label(_ s: Item) -> String { "\\(s.id) \\(s.count)" }
        public func urlsEqual(_ a: URL?, _ b: URL?) -> Bool { a == b }
        public func contains(_ ids: [UUID], _ id: UUID) -> Bool { ids.contains(id) }
        public func lookup(_ d: [UUID: Int8], _ id: UUID) -> Int8? { d[id] }

        public func pick(_ s: Item) -> Int { [1, 2][s.count] }
        public func sameIDTrap(_ s: Item, _ x: Int8) -> Int8 { s.id == s.id ? x + 1 : x }
        public func idsEqualTrap(_ a: Item, _ b: Item, _ x: Int8) -> Int8 { a.id == b.id ? x + 1 : x }
        public func idsDiffer(_ a: Item, _ b: Item, _ x: Int8) -> Int8 { a.id != b.id ? x + 1 : x }
        public func twoFresh(_ x: Int8) -> Int8 { UUID() == UUID() ? x + 1 : x }
        public func twoFreshDiffer(_ x: Int8) -> Int8 { UUID() != UUID() ? x + 1 : x }
        public func freshEqualsGiven(_ id: UUID, _ x: Int8) -> Int8 { UUID() == id ? x + 1 : x }
        public func urlSelf(_ u: URL, _ x: Int8) -> Int8 { u == u ? x &+ 1 : x + 1 }
        public func urlCopy(_ s: Item, _ x: Int8) -> Int8 { s.url == s.url ? x &+ 1 : x + 1 }
        public func urlTwo(_ a: URL, _ b: URL, _ x: Int8) -> Int8 { a == b ? x + 1 : x }
        public func localeSelf(_ l: Locale, _ x: Int8) -> Int8 { l == l ? x &+ 1 : x + 1 }
        public func dateSelf(_ d: Date, _ x: Int8) -> Int8 { d == d ? x &+ 1 : x + 1 }
        public func colorSelf(_ c: Color, _ x: Int8) -> Int8 { c == c ? x &+ 1 : x + 1 }
        public func itemSelf(_ s: Item, _ x: Int8) -> Int8 { s == s ? x &+ 1 : x + 1 }
        public func sameText(_ id: UUID, _ x: Int8) -> Int8 { id.uuidString == id.uuidString ? x &+ 1 : x + 1 }
        public func sameHash(_ id: UUID, _ x: Int8) -> Int8 { id.hashValue == id.hashValue ? x &+ 1 : x + 1 }
        public func sameAbsolute(_ u: URL, _ x: Int8) -> Int8 { u.absoluteString == u.absoluteString ? x &+ 1 : x + 1 }
        public func textOfTwo(_ a: UUID, _ b: UUID, _ x: Int8) -> Int8 { a.uuidString == b.uuidString ? x + 1 : x }
        public func textIsLiteral(_ id: UUID, _ x: Int8) -> Int8 { id.uuidString == "x" ? x + 1 : x }
        public func sameSeconds(_ d: Date, _ x: Int8) -> Int8 { d.timeIntervalSince1970 == d.timeIntervalSince1970 ? x &+ 1 : x + 1 }
        public func parsed(_ s: String, _ x: Int8) -> Int8 { URL(string: s) == nil ? x + 1 : x }
        public func path(_ u: URL) -> String { u.path }
        @inline(never) public func equalG<T: Equatable>(_ a: T, _ b: T) -> Bool { a == b }
        public func genericSelf(_ id: UUID, _ x: Int8) -> Int8 { equalG(id, id) ? x + 1 : x }
        public func genericURLs(_ a: URL, _ b: URL) -> Bool { equalG(a, b) }
        """
    static let all = ["UUID", "URL", "Locale", "Date", "Color"]
    static func module(confirmed: [String] = all) throws -> SILModule {
        var module = try SILCompiler.module(source: source, name: "Ov", optimization: .none)
        module.confirmPackageTypes(confirmed)
        return module
    }
    static let confirmed = try! module()

    static func verdict(_ name: String, in module: SILModule = confirmed) throws -> ProofVerdict {
        try SILVerifier.proveAggregate(try module.symbol(module: "Ov", name: name), in: module)
    }
    static func rejection(_ name: String, in module: SILModule) -> String? {
        do {
            _ = try verdict(name, in: module)
            return nil
        } catch {
            return "\(error)"
        }
    }
}

@Suite(.tags(.slow)) struct SILOpaqueValueTests {
    @Test func accessorsAndSynthesizedConformancesOfAStateWithIdentitiesAreProved() throws {
        let names = [
            "getID", "getURL", "setURL", "getCount", "setCount", "setTint", "make", "same", "hashItem", "hashValueOf", "label",
            "urlsEqual", "contains", "lookup",
        ]
        for name in names { #expect(try OpaqueFixture.verdict(name) == .proved, "\(name)") }
        // The synthesized `==` itself: `UUID.==`, then `Optional<URL>.==` through Foundation's witness, then the rest.
        let module = OpaqueFixture.confirmed
        let equals = try #require(module.symbols.first { $0.hasPrefix("$s2Ov4ItemV23__derived_struct_equals") })
        #expect(try SILVerifier.proveAggregate(equals, in: module) == .proved)
    }

    @Test func aTrapBesideTheIdentitiesIsFound() throws {
        guard case .counterexample = try OpaqueFixture.verdict("pick") else {
            Issue.record("[1, 2][count] traps for count 2")
            return
        }
    }

    @Test func aUUIDIsItsValue() throws {
        // The same UUID equals itself; two unknown ones may be equal (pass one twice) or different.
        for name in ["sameIDTrap", "idsEqualTrap", "idsDiffer"] {
            guard case .counterexample(let inputs) = try OpaqueFixture.verdict(name) else {
                Issue.record("\(name): overflows at 127")
                continue
            }
            #expect(inputs.last == 127, "\(name): \(inputs)")
        }
    }

    @Test func freshUUIDsAreNeitherEqualNorDifferent() throws {
        // Two `UUID()` calls are different in practice, but nothing in the model says so: never proved, never refuted.
        for name in ["twoFresh", "twoFreshDiffer", "freshEqualsGiven", "parsed"] {
            #expect(try OpaqueFixture.verdict(name) == .unknown, "\(name)")
        }
    }

    @Test func equalityFollowsEachTypesIdentity() throws {
        // A copy of a URL or Locale equals itself.
        for name in ["urlSelf", "urlCopy", "localeSelf"] { #expect(try OpaqueFixture.verdict(name) == .proved, "\(name)") }
        // Two URLs may be equal (the same one twice): the overflow is reachable.
        guard case .counterexample = try OpaqueFixture.verdict("urlTwo") else {
            Issue.record("urlTwo: a == b for the same URL")
            return
        }
        // A NaN date is not equal to itself (Foundation compares the `Double`s): the overflow is reachable. Color's `==`
        // is not read: never proved, never refuted; nor is an item holding both.
        guard case .counterexample = try OpaqueFixture.verdict("dateSelf") else {
            Issue.record("dateSelf: a NaN date")
            return
        }
        for name in ["colorSelf", "itemSelf"] { #expect(try OpaqueFixture.verdict(name) == .unknown, "\(name)") }
    }

    @Test func aValueDerivedFromAnIdentityIsTheSameForTheSameValue() throws {
        for name in ["sameText", "sameHash", "sameAbsolute"] { #expect(try OpaqueFixture.verdict(name) == .proved, "\(name)") }
        // The same UUID twice gives the same text: reachable. A NaN interval is not equal to itself: reachable too.
        guard case .counterexample = try OpaqueFixture.verdict("textOfTwo") else {
            Issue.record("textOfTwo: the same UUID twice")
            return
        }
        guard case .counterexample = try OpaqueFixture.verdict("sameSeconds") else {
            Issue.record("sameSeconds: a NaN date")
            return
        }
        // The text is unknown: it is never shown to equal a literal.
        #expect(try OpaqueFixture.verdict("textIsLiteral") == .unknown)
    }

    @Test func aGenericFunctionOfTheModuleIsReadAtAFoundationType() throws {
        // `equalG<UUID>`: its `witness_method $UUID, #Equatable."=="` is `UUID.==`, exact on the same value.
        guard case .counterexample(let inputs) = try OpaqueFixture.verdict("genericSelf") else {
            Issue.record("equalG(id, id) is true, so x + 1 overflows at 127")
            return
        }
        #expect(inputs.last == 127, "\(inputs)")
        #expect(try OpaqueFixture.verdict("genericURLs") == .proved)
    }

    @Test func anyOtherCallIsRefusedWithTheCallsThatAreRead() throws {
        let reason = try #require(OpaqueFixture.rejection("path", in: OpaqueFixture.confirmed))
        #expect(reason.contains("URL") && reason.contains("absoluteString"), "\(reason)")
    }

    @Test func anUnconfirmedNameIsNotRead() throws {
        let module = try OpaqueFixture.module(confirmed: [])
        let reason = try #require(OpaqueFixture.rejection("getID", in: module))
        #expect(reason.contains("UUID"), "\(reason)")
    }

    @Test func aTypeOfTheModuleWithAFoundationNameIsNeverTakenForIt() throws {
        // No Foundation import: `UUID` and `URL` are this module's types, whose own `hash(into:)` and `==` run.
        let source = """
            public struct UUID: Hashable {
                public var v: Int8
                public func hash(into h: inout Hasher) { h.combine(v + 1) }
            }
            public struct URL: Equatable {
                public var v: Int8
                public static func == (a: URL, b: URL) -> Bool { a.v + 1 == b.v }
            }
            public struct Holder: Hashable { public var id: UUID }
            public func hashHolder(_ h: Holder, _ hasher: inout Hasher) { h.hash(into: &hasher) }
            public func urls(_ a: URL, _ b: URL) -> Bool { a == b }
            """
        var module = try SILCompiler.module(source: source, name: "Own", optimization: .none)
        module.confirmPackageTypes(OpaqueFixture.all)  // even if a probe had confirmed the names
        for name in ["hashHolder", "urls"] {
            guard case .counterexample = try SILVerifier.proveAggregate(try module.symbol(module: "Own", name: name), in: module) else {
                Issue.record("\(name): the module's own code overflows at 127")
                continue
            }
        }
    }

    @Test func destroyingAColorIsRefusedWhileADeinitRunsCode() throws {
        let source =
            OpaqueFixture.source + """

                public final class Noisy { var n: Int8 = 0; deinit { n += 1 } }
                public func keep(_ n: Noisy) -> Noisy { n }
                """
        var module = try SILCompiler.module(source: source, name: "Ov", optimization: .none)
        module.confirmPackageTypes(OpaqueFixture.all)
        let reason = try #require(OpaqueFixture.rejection("setTint", in: module))
        #expect(reason.contains("Color") && reason.contains("deinit"), "\(reason)")
        #expect(try OpaqueFixture.verdict("sameText", in: module) == .proved, "a UUID holds no object")
    }

    /// Every read call is a symbol that `swiftc` emits for that API, with the shape the summary expects.
    @Test func everyReadSymbolIsTheOneSwiftcEmits() throws {
        let probe = """
            import Foundation
            import SwiftUI
            public func probe(_ u: UUID, _ r: URL, _ l: Locale, _ d: Date, _ c: Color, _ s: String, _ h: inout Hasher) {
                _ = (u == u, r == r, l == l, d == d, c == c, d < d)
                u.hash(into: &h); r.hash(into: &h); l.hash(into: &h); d.hash(into: &h); c.hash(into: &h)
                _ = (u.hashValue, r.hashValue, l.hashValue, d.hashValue, c.hashValue)
                _ = (u.description, r.description, l.description, d.description, c.description)
                _ = (UUID(), UUID(uuidString: s), u.uuidString, u.debugDescription)
                _ = (URL(string: s), r.absoluteString)
                _ = (Locale.current, Locale(identifier: s), l.identifier)
                _ = (Date(), Date.now, Date(timeIntervalSince1970: 1), d.timeIntervalSince1970)
                _ = (c.opacity(0.5), Color.red, Color.orange, Color.yellow, Color.green, Color.mint, Color.teal, Color.cyan)
                _ = (Color.blue, Color.indigo, Color.purple, Color.pink, Color.brown, Color.white, Color.gray, Color.black)
                _ = (Color.clear, Color.primary, Color.secondary, Color.accentColor)
            }
            public func probeMore(
                _ d: inout Date, _ t: Double, _ x: Decimal, _ k: Calendar, _ z: TimeZone, _ p: DateComponents,
                _ q: URLComponents, _ e: CharacterSet, _ h: inout Hasher
            ) {
                _ = (Date(timeIntervalSinceReferenceDate: t), d.timeIntervalSinceReferenceDate, Date.distantPast)
                _ = (Date.distantFuture, Date(timeInterval: t, since: d), d.addingTimeInterval(t), d + t, d - t)
                d += t
                d -= t
                d.addTimeInterval(t)
                _ = (d.timeIntervalSince(d), d > d, x == x, x == 1, Calendar.current, TimeZone.current)
                _ = (k == k, z == z, p == p, q == q, e == e, k.hashValue, z.hashValue, p.hashValue, q.hashValue, e.hashValue)
                k.hash(into: &h); z.hash(into: &h); p.hash(into: &h); q.hash(into: &h); e.hash(into: &h)
            }
            """
        let text = try SILCompiler.emit(source: probe, module: "Probe", optimization: .none)
        #expect(OpaqueValues.table.count >= 50)
        for (symbol, entry) in OpaqueValues.table.sorted(by: { $0.key < $1.key }) where !OpaqueValues.witnessOnly.contains(symbol) {
            #expect(text.contains("@\(symbol) : $@convention(method)"), "\(entry.name) (\(symbol)) is not what swiftc emits")
        }
    }
}
