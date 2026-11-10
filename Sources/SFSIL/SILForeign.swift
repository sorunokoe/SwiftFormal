import Foundation
import SFBV
import SFCNF

// Reading guide
// Objective-C objects, narrow (plan item R6-1). Kotlin/Native and every Objective-C framework export classes and
// protocols that the compiler imports from clang (the module `__C`). Logic reads a reference to one as an opaque
// handle: it can be held, passed, copied, stored in a struct, released and compared with `===`. A getter, setter or
// method of one (`objc_method … !foreign`, applied with `@convention(objc_method)`) runs code logic does not read: it
// is assumed to return normally and to change nothing logic reads, and its result is a *foreign result*, any value of
// the declared type (`String` bridged from an `NSString` included; a `_Nonnull` result is not nil). Every assumption is
// in docs/TRUST.md.
//
// - Which names are foreign comes from the compiler: SFVerifyKit demangles the symbols of the read modules that mention
//   the clang module (`So10GKTDomainXC`), and every class or protocol of `__C` in them is foreign
//   (`SILModule.foreignCandidateSymbols`, `confirmForeignTypes`). A name a read module declares is never foreign.
// - Dynamic dispatch must not reach Swift code of the read modules. A foreign type that a read class subclasses or
//   conforms to (directly, or through other foreign supertypes, which a compile probe decides: `foreignSupertypes`), a
//   member name a read module implements for Objective-C (`@objc` thunks), and a module that swaps method
//   implementations (`method_exchangeImplementations`, `@_dynamicReplacement`) are refused.
// - A foreign result is a fresh value. Inside `Verifier`'s main proof it is an existential witness recorded in a
//   `ForeignResults` (a task local): a counterexample comes with the values the foreign calls returned, read back
//   by a second solve. Elsewhere (loops, unwinding, cross-checks) it counts as an approximation, so a trap is reported
//   only when it happens whatever the foreign code returns.
// - Out of scope, refused with a reason: creating a foreign object, casts, blocks, printing one, `==` (which calls
//   `isEqual:`: Kotlin enums, sealed and data classes), `@objc` members of Swift classes.
//
// Tests: Tests/SFOracleTests/ForeignObjectTests.swift (a clang module shaped like a Kotlin export).

/// The Objective-C types of a module and what could make dispatch on them reach Swift code of the read modules.
struct ForeignTypes: Sendable {
    enum Kind: Sendable { case `class`, `protocol` }
    /// The symbols of the read modules that may name a type of `__C` (they contain `So` and a digit, how the mangling
    /// spells that module): what a demangler reads to find the foreign types.
    var symbols: Set<String> = []
    /// The classes and protocols of `__C` the demangler found in `symbols`.
    var confirmed: [String: Kind] = [:]
    /// Every name in an inheritance clause of a class, protocol or extension of the read modules.
    var inherited: Set<String> = []
    /// Members the read modules implement for Objective-C (`@objc Foo.count.getter`): base name -> owner types.
    var swiftMembers: [String: Set<String>] = [:]
    /// Some read module swaps Objective-C method implementations at run time.
    var swizzles = false
    /// The confirmed types that no foreign supertype of a read class converts to (a compile probe); nil before.
    var unrelated: Set<String>?

    mutating func link(_ other: ForeignTypes) {
        symbols.formUnion(other.symbols)
        confirmed.merge(other.confirmed) { first, _ in first }
        inherited.formUnion(other.inherited)
        swiftMembers.merge(other.swiftMembers) { $0.union($1) }
        swizzles = swizzles || other.swizzles
        unrelated = nil
    }

    /// Reads the mangled names, inheritance clauses, `@objc` thunks and run-time method replacements of SIL `lines`.
    static func scan(_ lines: [String]) -> ForeignTypes {
        var found = ForeignTypes()
        // The demangled name SIL prints above a function (`// @objc GKTDomainX.count.getter`), before other comments.
        var objcComment = ""
        for line in lines {
            if line.hasPrefix("// ") {
                if line.hasPrefix("// @objc ") { objcComment = line }
                continue
            }
            if line.hasPrefix("sil "), let at = line.range(of: " @$s") {
                let symbol = String(line[line.index(at.lowerBound, offsetBy: 2)...].prefix { $0 != " " })
                if Self.mayNameClangTypes(symbol) { found.symbols.insert(symbol) }
                if line.contains("[dynamic_replacement_for ") { found.swizzles = true }
                if line.hasSuffix("{"), line.contains(" : $@convention(objc_method)"), !objcComment.isEmpty {
                    found.recordSwiftMember(String(objcComment.dropFirst("// @objc ".count)))
                }
            } else if line.hasPrefix("  "), swizzlers.contains(where: { line.containsText($0) }) {
                found.swizzles = true
            } else if !line.hasPrefix("sil"), line.hasSuffix("{"), let clause = inheritanceClause(line) {
                found.inherited.formUnion(clause)
            }
            objcComment = ""
        }
        return found
    }

    /// Run-time functions that replace an Objective-C method's implementation.
    private static let swizzlers = ["method_exchangeImplementations", "class_replaceMethod", "method_setImplementation"]

    /// `So` followed by a digit: the start of an identifier in the clang module `__C` (also with word substitutions,
    /// `So09KmpDomaind6ReportE5StatsC`, which only a demangler reads). Other symbols name no foreign type.
    static func mayNameClangTypes(_ symbol: String) -> Bool {
        var previous: UInt8 = 0, beforePrevious: UInt8 = 0
        for byte in symbol.utf8 {
            if beforePrevious == UInt8(ascii: "S"), previous == UInt8(ascii: "o"), byte >= UInt8(ascii: "0"), byte <= UInt8(ascii: "9") {
                return true
            }
            (beforePrevious, previous) = (previous, byte)
        }
        return false
    }

    /// `Foo.count.getter`, `Foo.score(for:)`, `Outer.Inner.init(count:)` -> `count` of `Foo`, `score` of `Foo`,
    /// `init` of `Outer.Inner`.
    private mutating func recordSwiftMember(_ demangled: String) {
        let name = demangled.prefix { $0 != "(" && $0 != " " }
        var parts = name.split(separator: ".").map(String.init)
        if parts.count >= 3, ["getter", "setter", "modify"].contains(parts[parts.count - 1]) { parts.removeLast() }
        guard parts.count >= 2 else { return }
        let member = parts.removeLast()
        swiftMembers[member, default: []].insert(parts.joined(separator: "."))
    }

    /// The inherited names of `class Foo : Bar, Baz {`, `extension Foo : P {` or `protocol Q : P {` (attributes and
    /// modifiers before the keyword, generic arguments and `where` clauses dropped); nil for any other line.
    private static func inheritanceClause(_ line: String) -> [String]? {
        let words = line.trimmingCharacters(in: .whitespaces).split(separator: " ")
        guard let keyword = words.firstIndex(where: { ["class", "extension", "protocol", "actor"].contains($0) }),
            words[..<keyword].allSatisfy({ $0.hasPrefix("@") || modifiers.contains(String($0)) })
        else { return nil }
        // `extension Array where Element : P {` has no inheritance clause: its colon is in the `where` clause.
        var header = String(line.dropLast())
        if let whereClause = header.range(of: " where ") { header = String(header[..<whereClause.lowerBound]) }
        guard let colon = header.range(of: " : ") else { return nil }
        return splitTopLevel(String(header[colon.upperBound...])).compactMap { name in
            var n = name.trimmingCharacters(in: .whitespaces)
            // `@unchecked Sendable`, `@retroactive P`, `nonisolated P`: the attribute says nothing about the type.
            while let space = n.firstIndex(of: " "), n.hasPrefix("@") || clauseModifiers.contains(String(n[..<space])) {
                n = String(n[n.index(after: space)...])
            }
            n = String(n.prefix { $0 != "<" })
            return n.isEmpty || n.hasPrefix("~") ? nil : n
        }
    }

    private static let clauseModifiers: Set<String> = ["any", "nonisolated", "isolated", "sending"]

    private static let modifiers: Set<String> = [
        "public", "package", "internal", "fileprivate", "private", "open", "final", "nonisolated", "indirect",
    ]
}

extension SILModule {
    /// The symbols of the read modules that may name a type of `__C`, for a demangler (`confirmForeignTypes`).
    package var foreignCandidateSymbols: [String] { types.foreign.symbols.sorted() }

    /// Makes these names foreign: a demangler showed each as a class or protocol of `__C`, the module clang imports into.
    package mutating func confirmForeignTypes(classes: some Sequence<String>, protocols: some Sequence<String>) {
        types.foreign.confirmed = [:]
        for name in classes { types.foreign.confirmed[name] = .class }
        for name in protocols where types.foreign.confirmed[name] == nil { types.foreign.confirmed[name] = .protocol }
    }

    /// Renames confirmed foreign types to the names Swift (and SIL) gives them (`SharedKtDouble` -> `KotlinDouble`).
    package mutating func renameForeignTypes(_ renamed: [String: String]) {
        for (from, to) in renamed {
            guard let kind = types.foreign.confirmed.removeValue(forKey: from), !types.declaresName(to) else { continue }
            types.foreign.confirmed[to] = kind
        }
    }

    /// The confirmed foreign types (with `any` for a protocol) and the names a read class, protocol or extension inherits
    /// from that no read module declares: a foreign type is readable only when none of these converts to it.
    package var foreignSupertypeQuestion: (types: [String], supertypes: [String]) {
        let usable = types.foreign.confirmed.filter { !types.declaresName($0.key) && !types.foreign.inherited.contains($0.key) }
        let spelled = usable.map { $0.value == .protocol ? "any " + $0.key : $0.key }.sorted()
        let supertypes = types.foreign.inherited.filter { !types.declaresName($0) && !TypeContext.swiftOnlyProtocols.contains($0) }
        return (spelled, supertypes.sorted())
    }

    /// Records the foreign types (spelled as in `foreignSupertypeQuestion`) that none of the supertypes converts to.
    package mutating func confirmUnrelatedForeignTypes(_ spelled: some Sequence<String>) {
        types.foreign.unrelated = Set(spelled.map { $0.hasPrefix("any ") ? String($0.dropFirst(4)) : $0 })
    }
}

// MARK: - types

extension TypeContext {
    /// Every reference to an Objective-C object (and `AnyObject` made from one): one opaque 64-bit handle, its identity.
    static let objectHandle = ValueType.opaque(name: "object")

    /// Standard Swift protocols that no Objective-C type can be a subtype of: a supertype the probe need not ask about.
    static let swiftOnlyProtocols: Set<String> = [
        "Equatable", "Hashable", "Comparable", "Identifiable", "Sendable", "Codable", "Encodable", "Decodable", "CaseIterable",
        "Error", "RawRepresentable", "CustomStringConvertible", "CustomDebugStringConvertible", "Sequence", "Collection",
    ]

    /// True when a read module declares `name` (or it is ambiguous): then a use means that declaration.
    func declaresName(_ name: String) -> Bool {
        structs[name] != nil || enums[name] != nil || generics[name] != nil || rejected[name] != nil || ambiguous.contains(name)
    }

    /// Whether `name` is a confirmed foreign type of `kind` that logic may read. Throws, with the reason, for a foreign
    /// type whose dispatch or release could reach Swift code of the read modules.
    func readableForeign(_ name: String, kind: ForeignTypes.Kind) throws(SILError) -> Bool {
        guard foreign.confirmed[name] == kind, !declaresName(name) else { return false }
        let what = kind == .class ? "Objective-C class" : "Objective-C protocol"
        if foreign.swizzles {
            throw SILError.unsupported("\(what) \(name): a read module replaces Objective-C method implementations at run time")
        }
        if foreign.inherited.contains(name) {
            throw SILError.unsupported(
                "\(what) \(name), which a class of this module subclasses or conforms to: a call or a release may run its Swift code")
        }
        // When the probe ran, its answer decides: it also leaves out a name it could not resolve (ambiguous with a type
        // of another module, say). Without a probe, only a module whose classes have no supertype to ask about.
        let supertypes = foreign.inherited.filter { !declaresName($0) && !Self.swiftOnlyProtocols.contains($0) }
        guard foreign.unrelated?.contains(name) ?? supertypes.isEmpty else {
            guard !supertypes.isEmpty else {
                throw SILError.unsupported("\(what) \(name): the compiler did not resolve the name to that type alone")
            }
            throw SILError.unsupported(
                "\(what) \(name): a class of this module subclasses or conforms to \(supertypes.sorted().prefix(3).joined(separator: ", ")), "
                    + "which may make it one, and no check showed otherwise: a call or a release may run its Swift code")
        }
        return true
    }

    /// The layout of a foreign reference type: `objectHandle` for a foreign class, an existential of foreign protocols
    /// (or the type opened from one) and `AnyObject`; an empty value for `@objc_metatype C.Type`. Nil for other types.
    func foreignObject(_ text: String) throws(SILError) -> ValueType? {
        var t = text
        if t == "AnyObject" { return try heldUnlessDeinitsRunCode(t, Self.objectHandle) }
        if t.hasPrefix("@objc_metatype "), t.hasSuffix(".Type") {
            let name = String(t.dropFirst("@objc_metatype ".count).dropLast(".Type".count))
            return try readableForeign(name, kind: .class) ? .aggregate(name: t, fields: []) : nil
        }
        if t.hasPrefix("@opened(\""), t.hasSuffix(") Self"), let comma = t.range(of: "\", ") {
            t = String(t[comma.upperBound..<t.index(t.endIndex, offsetBy: -") Self".count)])
        }
        if t.hasPrefix("any ") {
            let names = t.dropFirst(4).components(separatedBy: " & ")
            for name in names where !(try readableForeign(name, kind: .protocol)) { return nil }
            return Self.objectHandle
        }
        return try readableForeign(t, kind: .class) ? Self.objectHandle : nil
    }

    /// True for a foreign reference type: releasing one runs foreign code only (TRUST.md).
    func isForeignObject(_ text: String) -> Bool {
        (try? foreignObject(text)) == Self.objectHandle && text != "AnyObject"
    }
}

// MARK: - identity

/// `===` of two `AnyObject?`: both nil, or the same object. With inactive payloads zero (`ValueType.enumeration`), that is
/// equality of the leaves.
enum ObjectIdentity {
    static let symbol = "$ss3eeeoiySbyXlSg_ABtF"

    static func encode(_ call: ComputedCall, in c: CNFBuilder) throws -> ComputedEffect {
        let operands = zip(call.inputs, call.conventions).filter { $1 != .out }.map(\.0)
        guard operands.count == 2, operands[0].map(\.width) == [1, 64], operands[1].map(\.width) == [1, 64],
            call.resultType.leafWidths == [1], call.writtenTypes.isEmpty
        else { throw SILError.invalid("\(call.name): operands of unexpected shape") }
        let same = c.and(c.eq(operands[0][0], operands[1][0]), c.eq(operands[0][1], operands[1][1]))
        return ComputedEffect(result: [BV(bits: [same])])
    }
}

extension StdlibSummary {
    /// `===`, exact on handles (`ObjectIdentity`).
    static func addObjectIdentity(to t: inout [String: Entry]) {
        func add(_ symbol: String, _ name: String, _ summary: StdlibSummary) {
            t[symbol] = Entry(name: name, summary: summary, isGeneric: false)
        }
        add("$ss3eeeoiySbyXlSg_ABtF", "===", .computed(.objectIdentity))
    }
}
