// Type declarations of the read modules and how a SIL type spelling resolves to a `ValueType` (plan item H1).

import Foundation
import SFSemantics

/// Struct declarations printed at the top of the canonical SIL, plus the names of declarations the frontend
/// refuses (classes, enums, generic structs), so that errors can say what was rejected.
struct TypeContext: Sendable {
    var structs: [String: [(name: String, type: String)]] = [:]
    /// Non-generic, non-indirect enums: their cases in declaration order, with the payload type text if any.
    var enums: [String: [(name: String, payload: String?)]] = [:]
    /// The `@objc` enums among `enums`: their values are their raw values in memory (`SILEnumTags.swift`).
    var objcEnums: Set<String> = []
    /// Generic structs and non-indirect enums, by name without arguments. A use such as `LoadingState<Int8>` is
    /// resolved by writing the arguments into the declared fields and cases.
    var generics: [String: GenericDeclaration] = [:]
    var rejected: [String: String] = [:]
    /// The printed declarations of the structs and enums in `structs` and `enums` (concrete playback writes values of
    /// them as Swift literals; nothing here changes how a type is read).
    var declarations: [String: TypeDeclarationText] = [:]
    /// Eligible classes and their stored properties (plan item L5, `SILClasses.swift`); each is also in `rejected`.
    var classes: [String: [(name: String, type: String)]] = [:]
    /// Names declared more than once. SIL prints types without their file or module (two `private struct Row` in two
    /// files are both `Row`), so a use cannot say which declaration it means: such a name is never resolved.
    private(set) var ambiguous: Set<String> = []
    /// The classes of the read modules whose deinit calls code or can trap (`SILDeinits.swift`), sorted; nil until the
    /// bodies are read, which counts as some.
    var codeRunningDeinits: [String]?
    /// Package types (`packageTypes`) that a compile probe confirmed for this build (see `SILPackageTypes.swift`).
    var confirmedPackageTypes: Set<String> = []
    /// The Objective-C types the compiler imported, and what could make them unreadable (`SILForeign.swift`).
    var foreign = ForeignTypes()
    /// The enums and calls of the binary modules this SIL imports, and how calls with no body are read
    /// (`SILBinaryTypes.swift`).
    var binary = BinaryTypes()

    struct GenericDeclaration: Sendable {
        let parameters: [String]
        let isEnum: Bool
        let fields: [(name: String, type: String)]
        let cases: [(name: String, payload: String?)]
    }

    /// Records the declaration of `name` with `store`, or makes the name ambiguous if it is already declared.
    mutating func declare(_ name: String, _ store: (inout TypeContext) -> Void) {
        guard !ambiguous.contains(name) else { return }
        guard structs[name] == nil, enums[name] == nil, generics[name] == nil, rejected[name] == nil else {
            markAmbiguous(name)
            return
        }
        store(&self)
    }

    /// Adds the declarations of another module; a name declared in both becomes ambiguous.
    mutating func link(_ other: TypeContext) {
        foreign.link(other.foreign)
        binary.link(other.binary)
        for name in other.ambiguous { markAmbiguous(name) }
        for (name, fields) in other.structs { declare(name) { $0.structs[name] = fields } }
        for (name, cases) in other.enums {
            declare(name) {
                $0.enums[name] = cases
                if other.objcEnums.contains(name) { $0.objcEnums.insert(name) }
            }
        }
        for (name, text) in other.declarations where declarations[name] == nil && (structs[name] != nil || enums[name] != nil) {
            declarations[name] = text
        }
        for (name, declaration) in other.generics { declare(name) { $0.generics[name] = declaration } }
        for (name, reason) in other.rejected where !other.ambiguous.contains(name) {
            declare(name) {
                $0.rejected[name] = reason
                $0.classes[name] = other.classes[name]
            }
        }
    }

    mutating func markAmbiguous(_ name: String) {
        structs[name] = nil
        declarations[name] = nil
        enums[name] = nil
        objcEnums.remove(name)
        generics[name] = nil
        classes[name] = nil
        rejected[name] = SILError.ambiguousTypeKind
        ambiguous.insert(name)
    }

    func resolve(_ text: String, depth: Int = 0) throws(SILError) -> ValueType {
        var t = text.trimmingCharacters(in: .whitespaces)
        if t.hasPrefix("$") { t.removeFirst() }
        // Ownership conventions say who releases a value, not what it is.
        for convention in ["@owned ", "@guaranteed "] where t.hasPrefix(convention) { t.removeFirst(convention.count) }
        if ambiguous.contains(t) { throw SILError.unsupported("\(SILError.ambiguousTypeKind) \(t)\(SILError.supportedTypesNote)") }
        if let w = scalarWidth(t) { return .scalar(w) }
        if t == "()" { return .aggregate(name: "", fields: []) }
        if Self.isFunctionType(t) { return try closureType(t) }
        if let handle = try referenceHandle(t) { return handle }
        if let name = opaqueTypeName(t) { return .opaque(name: name) }
        if let handle = try hashedLayout(t) { return handle }
        guard depth < 16 else { throw SILError.unsupported("type nesting too deep: \(text)") }
        if let element = arrayElement(t) {
            // Elements are resolved only where one is read. Destroying an array destroys its elements, which must
            // not run code of the verified modules (release and destroy instructions are not modelled).
            guard destroysWithoutModuleCode(element) else {
                throw SILError.unsupported(
                    "array of \(element): destroying its elements may run code of this module (classes, closures, existentials)")
            }
            return .array(element: ArrayElement(text: element))
        }
        if let wrapped = optionalWrapped(t) {
            let payload = try resolve(wrapped, depth: depth + 1)
            return .enumeration(
                name: "Optional<\(payload.description)>",
                cases: [.init(name: "none", payload: nil), .init(name: "some", payload: payload)])
        }
        if t.hasPrefix("("), t.hasSuffix(")") { return try tupleType(String(t.dropFirst().dropLast()), depth: depth) }
        // `@thin P.Type`: the receiver of a static method or memberwise initializer. A thin metatype is known
        // statically and carries no data, whatever P is (P itself is still checked wherever a P value is used).
        // `@thick P.Type` (the `Self.Type` argument of a protocol witness) also carries no data for a struct or enum P;
        // class types, whose dynamic type could differ, are rejected wherever their values appear.
        if t.hasPrefix("@thin ") || t.hasPrefix("@thick "), t.hasSuffix(".Type") {
            return .aggregate(name: t, fields: [])
        }
        if let fields = structs[t] {
            // A struct without stored properties has no leaves. A property the declaration scanner missed cannot
            // hide here: `struct_extract` of it, or `struct` with its operand, is rejected as not matching the type.
            return .aggregate(
                name: t,
                fields: try fields.map { (f) throws(SILError) in ValueType.Field(name: f.name, type: try resolve(f.type, depth: depth + 1))
                })
        }
        if let cases = enums[t] {
            guard !cases.isEmpty else { throw SILError.unsupported("enum \(t) has no cases (it has no values)") }
            return .enumeration(
                name: t,
                cases: try cases.map { (k) throws(SILError) in
                    ValueType.Case(name: k.name, payload: try k.payload.map { (p) throws(SILError) in try resolve(p, depth: depth + 1) })
                })
        }
        if let instance = try binaryEnumOrInstance(t, depth: depth) { return instance }
        if let instance = try iterationType(t, depth: depth) { return instance }
        if let instance = standardFloatEnum(t) ?? cgFloatType(t) { return instance }
        if let layout = try opaqueValueType(t) { return layout }
        if let package = packageType(t) { return try heldUnlessDeinitsRunCode(t, package) }
        if let kind = rejected[t] { throw SILError.unsupported("\(kind) \(t)\(SILError.supportedTypesNote)") }
        throw SILError.unsupported("type \(t)\(SILError.supportedTypesNote)")
    }

    /// The tuple type whose elements are written in `inner` (`a: Int8, Bool`); element labels are dropped.
    private func tupleType(_ inner: String, depth: Int) throws(SILError) -> ValueType {
        let elements = try splitTopLevel(inner).map { (element) throws(SILError) -> ValueType in
            var e = element
            if let colon = e.firstIndex(of: ":"), e[..<colon].allSatisfy({ $0.isLetter || $0.isNumber || $0 == "_" }) {
                e = String(e[e.index(after: colon)...]).trimmingCharacters(in: .whitespaces)
            }
            return try resolve(e, depth: depth + 1)
        }
        guard !elements.isEmpty else { throw SILError.unsupported("empty tuple type") }
        return .aggregate(name: "", fields: elements.enumerated().map { .init(name: "\($0)", type: $1) })
    }

    /// The stored property names of the struct named in `#Pair.a`, and what the extracted-from value must be.
    func fieldOwner(_ name: String) throws(SILError) -> (fields: [String], owner: FieldOwner) {
        if let declaration = try genericDeclaration(of: name), !declaration.isEnum {
            return (declaration.fields.map(\.name), .instance(of: name))
        }
        let type = try resolve(name)
        guard case .aggregate(_, let fields) = type else { throw SILError.unsupported("fields of \(name)") }
        return (fields.map(\.name), .type(type))
    }

    /// `t` as an enum of a binary module when nothing scanned declares it (`SILBinaryTypes.swift`), else as an
    /// instance of a declared generic type.
    private func binaryEnumOrInstance(_ t: String, depth: Int) throws(SILError) -> ValueType? {
        if !declaresName(t), let binary = try binaryEnum(t, depth: depth) { return binary }
        return try instantiate(t, depth: depth)
    }

    /// `Pair<Int8, Bool>` for a declared `struct Pair<A, B>`: the declaration with `A` and `B` replaced.
    /// Nil when `t` is not a use of a declared generic type.
    private func instantiate(_ t: String, depth: Int) throws(SILError) -> ValueType? {
        guard t.hasSuffix(">"), let open = t.firstIndex(of: "<") else { return nil }
        if ambiguous.contains(String(t[..<open])) {
            throw SILError.unsupported("\(SILError.ambiguousTypeKind) \(t)\(SILError.supportedTypesNote)")
        }
        guard let declaration = try genericDeclaration(of: String(t[..<open])) else { return nil }
        let arguments = splitTopLevel(String(t[t.index(after: open)..<t.index(before: t.endIndex)]))
        guard arguments.count == declaration.parameters.count else {
            throw SILError.unsupported("type \(t): expected \(declaration.parameters.count) generic arguments")
        }
        let map = Dictionary(zip(declaration.parameters, arguments), uniquingKeysWith: { first, _ in first })
        if declaration.isEnum {
            guard !declaration.cases.isEmpty else { throw SILError.unsupported("enum \(t) has no cases (it has no values)") }
            return .enumeration(
                name: t,
                cases: try declaration.cases.map { (c) throws(SILError) in
                    ValueType.Case(
                        name: c.name,
                        payload: try c.payload.map { (p) throws(SILError) in try resolve(substituting(map, in: p), depth: depth + 1) })
                })
        }
        return .aggregate(
            name: t,
            fields: try declaration.fields.map { (f) throws(SILError) in
                ValueType.Field(name: f.name, type: try resolve(substituting(map, in: f.type), depth: depth + 1))
            }
        )
    }

    /// `text` with every identifier that is a key of `map` replaced (`Optional<T>` -> `Optional<Int8>`).
    /// A member name after a dot (`X.T`) is left alone.
    func substituting(_ map: [String: String], in text: String) -> String {
        var result = ""
        var word = ""
        var afterDot = false
        func flush() {
            result += afterDot ? word : (map[word] ?? word)
            word = ""
        }
        for character in text {
            if character.isLetter || character.isNumber || character == "_" {
                if word.isEmpty { afterDot = result.last == "." }
                word.append(character)
            } else {
                flush()
                result.append(character)
            }
        }
        flush()
        return result
    }

    /// The standard-library types modelled as opaque handles (see `ValueType.opaque`).
    private func opaqueTypeName(_ t: String) -> String? {
        let name = t.hasPrefix("Swift.") ? String(t.dropFirst(6)) : t
        return [
            "String", "Substring", "Character", "Hasher", "DefaultStringInterpolation", "Builtin.RawPointer", "String.LocalizationValue",
            "StaticString",
        ]
        .contains(name)
            ? name : nil
    }

    /// `X` for `[X]`, `Array<X>` and `Swift.Array<X>`; nil for anything else (`[K: V]` is a dictionary).
    package static func arrayElement(_ text: String) -> String? {
        let t = text.trimmingCharacters(in: .whitespaces)
        for prefix in ["Array<", "Swift.Array<"] where t.hasPrefix(prefix) && t.hasSuffix(">") {
            let inner = String(t.dropFirst(prefix.count).dropLast())
            return splitTopLevel(inner).count == 1 ? inner : nil
        }
        guard t.hasPrefix("["), t.hasSuffix("]"), matchingClose(Substring(t), open: "[", close: "]") == t.index(before: t.endIndex)
        else { return nil }
        let inner = String(t.dropFirst().dropLast())
        var depth = 0
        for ch in inner {
            if "<([".contains(ch) { depth += 1 }
            if ">)]".contains(ch) { depth -= 1 }
            if ch == ":" && depth == 0 { return nil }
        }
        return inner.trimmingCharacters(in: .whitespaces)
    }

    private func arrayElement(_ t: String) -> String? { Self.arrayElement(t) }
}

// MARK: - destroying values

extension TypeContext {
    /// True when destroying a `text` value can run only code outside the verified modules: no class, actor,
    /// closure or existential of any kind, and no type of these modules that could hold one. Types declared
    /// elsewhere (`Date`, generic parameters) are trusted, like the standard library.
    func destroysWithoutModuleCode(_ text: String, depth: Int = 0) -> Bool {
        var t = text.trimmingCharacters(in: .whitespaces)
        if t.hasPrefix("$") { t.removeFirst() }
        if isForeignObject(t) { return true }
        if Self.isFunctionType(t) || Self.isExistential(t) || keyPathType(t) != nil || packageType(t) != nil {
            return closureDestroysWithoutModuleCode(t)
        }
        guard depth < 16, !t.isEmpty, !Self.mayHoldReferences(t), !ambiguous.contains(t) else { return false }
        if scalarWidth(t) != nil || opaqueTypeName(t) != nil || t == "()" { return true }
        let next = depth + 1
        if let inner = optionalWrapped(t) ?? arrayElement(t) { return destroysWithoutModuleCode(inner, depth: next) }
        if let parts = componentTypes(t) { return parts.allSatisfy { destroysWithoutModuleCode($0, depth: next) } }
        if let fields = structs[t] { return fields.allSatisfy { destroysWithoutModuleCode($0.type, depth: next) } }
        if let cases = enums[t] { return cases.allSatisfy { $0.payload.map { destroysWithoutModuleCode($0, depth: next) } ?? true } }
        if let kind = rejected[t] { return objectReleaseRunsNoModuleCode(kind) }
        // A member type (`Outer.Inner`) of this module is declared under that name; anything else is external.
        return genericInstanceDestroysWithoutModuleCode(t, depth: next)
    }

    /// Closures, existentials and attributed types: their values may hold a reference to anything.
    private static func mayHoldReferences(_ t: String) -> Bool {
        t.contains("->") || t.hasPrefix("any ") || t.hasPrefix("some ") || t.hasPrefix("@")
            || ["Any", "AnyObject", "AnyHashable", "Swift.AnyHashable"].contains(t)
    }

    /// The element types of a tuple `(A, label: B)` or a dictionary `[K: V]`; nil for any other type.
    private func componentTypes(_ t: String) -> [String]? {
        if t.hasPrefix("("), t.hasSuffix(")") {
            return splitTopLevel(String(t.dropFirst().dropLast())).map { element in
                guard let colon = element.firstIndex(of: ":"), element[..<colon].allSatisfy({ $0.isLetter || $0.isNumber || $0 == "_" })
                else { return element }
                return String(element[element.index(after: colon)...])
            }
        }
        if t.hasPrefix("["), t.hasSuffix("]") {
            return splitTopLevel(String(t.dropFirst().dropLast()).replacingOccurrences(of: ":", with: ","))
        }
        return nil
    }

    /// `destroysWithoutModuleCode` for a generic instance `G<A, B>`: every argument, and every field or payload of
    /// a generic type of this module after substitution. True for any other type that reaches it (see above).
    private func genericInstanceDestroysWithoutModuleCode(_ t: String, depth: Int) -> Bool {
        guard t.hasSuffix(">"), let open = t.firstIndex(of: "<") else { return true }
        let name = String(t[..<open])
        if ambiguous.contains(name) { return false }
        if let kind = rejected[name], !objectReleaseRunsNoModuleCode(kind) { return false }
        let arguments = splitTopLevel(String(t[t.index(after: open)..<t.index(before: t.endIndex)]))
        guard arguments.allSatisfy({ destroysWithoutModuleCode($0, depth: depth) }) else { return false }
        guard let declaration = generics[name] else { return true }
        let map = Dictionary(zip(declaration.parameters, arguments), uniquingKeysWith: { first, _ in first })
        return declaration.fields.allSatisfy { destroysWithoutModuleCode(substituting(map, in: $0.type), depth: depth) }
            && declaration.cases.allSatisfy {
                $0.payload.map { destroysWithoutModuleCode(substituting(map, in: $0), depth: depth) } ?? true
            }
    }

    /// `T` for `Optional<T>`, `T?` and `T!`.
    private func optionalWrapped(_ t: String) -> String? {
        for prefix in ["Optional<", "Swift.Optional<"] where t.hasPrefix(prefix) && t.hasSuffix(">") {
            let inner = String(t.dropFirst(prefix.count).dropLast())
            if splitTopLevel(inner).count == 1 { return inner }
        }
        // `() -> Int?` is a function; `(() -> Int)?` is an optional.
        if (t.hasSuffix("?") || t.hasSuffix("!")) && !Self.isFunctionType(t) { return String(t.dropLast()) }
        return nil
    }
}
