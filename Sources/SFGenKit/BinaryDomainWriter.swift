import Foundation

/// A Swift type spelling, parsed far enough to choose a domain for it.
indirect enum TypeSpelling: Equatable {
    case named(String)
    case optional(TypeSpelling)
    case array(TypeSpelling)
    case existential(String)
    case unsupported(String)

    /// Parses the spelling the symbol graph gives a parameter or property, such as `[Surface]?` or `any Shape`.
    static func parse(_ raw: String) -> TypeSpelling {
        var text = raw.trimmingCharacters(in: .whitespaces)
        for noise in ["@escaping ", "@Sendable ", "inout ", "borrowing ", "consuming ", "__owned "] where text.hasPrefix(noise) {
            text = String(text.dropFirst(noise.count))
        }
        if text.contains("->") { return .unsupported("closure type \(text)") }
        if text.hasSuffix("?") || text.hasSuffix("!") { return wrap(parse(String(text.dropLast())), in: TypeSpelling.optional) }
        if text.hasPrefix("[") && text.hasSuffix("]") {
            let inner = String(text.dropFirst().dropLast())
            if topLevelColon(inner) { return .unsupported("dictionary type \(text)") }
            return wrap(parse(inner), in: TypeSpelling.array)
        }
        if text.hasPrefix("(") && text.hasSuffix(")") && !topLevelComma(String(text.dropFirst().dropLast())) {
            return parse(String(text.dropFirst().dropLast()))
        }
        if text.hasPrefix("(") { return .unsupported("tuple type \(text)") }
        if text.hasPrefix("any ") || text.hasPrefix("some ") {
            let name = String(text.drop { $0 != " " }.dropFirst())
            return isPlainName(name) ? .existential(name) : .unsupported("existential \(text)")
        }
        if text.contains("<") { return .unsupported("generic type \(text)") }
        if text.contains("&") { return .unsupported("composition \(text)") }
        return isPlainName(text) ? .named(text.hasPrefix("Swift.") ? String(text.dropFirst(6)) : text) : .unsupported(text)
    }

    private static func wrap(_ inner: TypeSpelling, in make: (TypeSpelling) -> TypeSpelling) -> TypeSpelling {
        if case .unsupported = inner { return inner }
        return make(inner)
    }

    private static func isPlainName(_ text: String) -> Bool {
        !text.isEmpty && text.allSatisfy { $0.isLetter || $0.isNumber || $0 == "_" || $0 == "." }
    }

    private static func topLevelColon(_ text: String) -> Bool { hasTopLevel(":", in: text) }

    private static func topLevelComma(_ text: String) -> Bool { hasTopLevel(",", in: text) }

    private static func hasTopLevel(_ separator: Character, in text: String) -> Bool {
        var depth = 0
        for character in text {
            switch character {
            case "[", "(", "<": depth += 1
            case "]", ")", ">": depth -= 1
            case separator where depth == 0: return true
            default: break
            }
        }
        return false
    }
}

/// What `sfgen domains` did with one type of the module.
public struct BinaryDomainEntry: Equatable, Sendable {
    public enum Category: String, Sendable { case enumeration = "enum", sealed, object, initializer = "init", other }
    public enum Status: String, Sendable {
        /// Every value the type can have: walks over it can prove.
        case exhaustive
        /// Representative values: walks over it are bounded, never proved.
        case bounded
        case skipped
    }

    public var type: String
    public var category: Category
    public var status: Status
    /// Why the domain is bounded or skipped; empty when exhaustive.
    public var reason: String
    /// The `Domain` member generated for the type (`Domain<T>.member`), if any.
    public var member: String?
}

/// The generated Swift file and one entry per type, sorted by type name.
public struct BinaryDomainResult: Sendable {
    public var source: String
    public var entries: [BinaryDomainEntry]
}

/// Writes walk domains for the types of a compiled module, as Swift source to add to a test target.
///
/// Each type `T` gets `extension Domain where Value == T { static var t: Self }`, so a walk reads
/// `Prove(it: map, over: .t)`. The domains are built only from what the module exports:
///
/// - an enum whose `CaseIterable` the compiler synthesized needs nothing: `Domain.allCases` (and `CaseIterable.domain`)
///   already list every case; fields of such a type use it;
/// - a sealed hierarchy with an `onEnum(of:)` switch (SKIE's export of a Kotlin `sealed` class or interface) is the
///   union of a domain per case's subtype, plus a compile-time check that the switch still has exactly those cases;
/// - a singleton (a static `shared` of the type and no initializer, such as a Kotlin `object`) is that one value;
/// - other classes and structs are built through an initializer from domains of its parameters.
///
/// A domain is exhaustive, and walks over it can prove, only when nothing was sampled: every field's domain is
/// exhaustive (`Bool`, `CaseIterable` enums, other exhaustive generated domains, optionals of those), the type is not
/// `open`, and every public property is an initializer parameter of the same name, so the initializer reaches all the
/// state a mapper can read. Numbers and strings use a few boundary values, arrays a few short ones, and the domain is
/// then a sample: walks over it are `bounded`, never `proved`.
public enum BinaryDomainWriter {
    /// The domains for every type of `module`, except the `excluded` ones, in a file that also imports `imports`.
    public static func generate(_ module: BinaryModule, imports: [String] = [], excluded: Set<String> = []) -> BinaryDomainResult {
        let builder = BinaryDomainBuilder(module: module, excluded: excluded)
        for name in module.types.keys.sorted() { builder.root(name) }
        return builder.result(imports: imports)
    }

    /// Names already used by `Domain`'s own static members; a generated member must not shadow them.
    static let reservedMembers: Set<String> = [
        "allCases", "arrays", "asSample", "bool", "boundaries", "combinations", "complete", "count", "evenlySpaced",
        "filter", "int", "just", "map", "named", "of", "optional", "product", "samples", "union",
    ]

    static let keywords: Set<String> = [
        "as", "break", "case", "catch", "class", "continue", "default", "defer", "do", "else", "enum", "extension",
        "fallthrough", "false", "for", "func", "guard", "if", "import", "in", "init", "is", "let", "nil", "operator",
        "protocol", "repeat", "return", "self", "static", "struct", "subscript", "super", "switch", "throw", "throws",
        "true", "try", "typealias", "var", "where", "while",
    ]

    /// Instance methods that only read: equality, hashing and description, and the copy and component methods a
    /// Kotlin data class exports. Any other method of a class may change state its initializer does not set.
    static func stateless(_ method: String) -> Bool {
        if ["isEqual(_:)", "hash()", "hash(into:)", "description()", "debugDescription()"].contains(method) { return true }
        if method.hasPrefix("doCopy(") { return true }
        return method.hasPrefix("component") && method.hasSuffix("()") && method.dropFirst(9).dropLast(2).allSatisfy(\.isNumber)
    }

    static let integers: Set<String> = ["Int", "Int8", "Int16", "Int32", "Int64", "UInt", "UInt8", "UInt16", "UInt32", "UInt64", "CChar"]
    static let floats: Set<String> = ["Float", "Double", "CGFloat", "Float32", "Float64"]

    struct Failure: Error {
        let reason: String
        init(_ reason: String) { self.reason = reason }
    }
}
