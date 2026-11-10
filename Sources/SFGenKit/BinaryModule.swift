public import Foundation

/// The public API of a compiled module as its symbol graph describes it, for `sfgen domains`: enough to build a walk
/// domain for each of its types through the type's own initializer, singleton or `onEnum(of:)` switch.
///
/// The symbol graph is the source of truth because it needs no knowledge of the language the framework was written in:
/// `swift symbolgraph-extract` reads a binary `.swiftmodule` and the module's Objective-C headers (with their API
/// notes) through the same importer the app's own compile uses, so every name and type is spelled as Swift sees it.
public struct BinaryModule: Sendable {
    public var name: String
    /// Types by their path inside the module (`Outer.Inner`).
    public var types: [String: BinaryType] = [:]
    /// Sealed hierarchies by the path of their base type.
    public var sealed: [String: SealedHierarchy] = [:]
    /// Public type aliases: the aliased spelling by the alias's path.
    public var aliases: [String: String] = [:]
    /// `onEnum(of:)` overloads whose `__Sealed` enum is not in the graph: extracted at `public` access, which hides it.
    public var sealedEnumsMissing = 0

    public init(name: String) { self.name = name }
}

public struct BinaryType: Sendable {
    public enum Kind: Sendable { case classType, structure, enumeration, protocolType }

    public var name: String
    public var kind: Kind
    /// `open`: other modules may subclass it, so its own initializer does not list every value it can be.
    public var isOpen = false
    public var isGeneric = false
    public var isCaseIterable = false
    /// Declared in Objective-C or C (a clang identifier): an imported enum may hold raw values outside its cases.
    public var isImported = false
    /// The superclass by its path in this module, or `nil` for a root class (or one whose root is `NSObject`).
    public var superclass: String?
    /// A superclass the graph does not describe (another module's class other than `NSObject`, or a hidden one):
    /// its state is unknown.
    public var unknownSuperclass: String?
    /// Cases the graph marks unavailable: they exist but the generated code cannot name them.
    public var unavailableCases: [String] = []
    /// A static `shared` property of the type itself: a singleton, such as a Kotlin `object`.
    public var hasShared = false
    /// Public instance properties, the state a mapper can read.
    public var properties: [TypeParam] = []
    /// Public instance properties that can be set.
    public var settable: Set<String> = []
    /// Public instance methods by name (`isEqual(_:)`), with `mutating` ones marked by a `mutating ` prefix.
    public var methods: [String] = []
    /// An enum's cases, with the type each carries when it carries exactly one.
    public var cases: [SealedHierarchy.Case] = []
    /// Public, available, non-deprecated, non-failable initializers.
    public var inits: [[TypeParam]] = []

    public init(name: String, kind: Kind) {
        self.name = name
        self.kind = kind
    }
}

/// A closed class or protocol hierarchy with a generated `onEnum(of:)` switch over its subtypes, as SKIE exports a
/// Kotlin `sealed` class or interface.
public struct SealedHierarchy: Sendable {
    public struct Case: Sendable, Equatable {
        public var name: String
        /// The subtype the case carries; nil for a case without one, such as SKIE's `else` for unexported subclasses.
        public var payload: String?
        /// The case carries associated values (`payload` names their type only when there is exactly one).
        public var carriesValues: Bool

        public init(name: String, payload: String?) {
            self.init(name: name, payload: payload, carriesValues: payload != nil)
        }

        public init(name: String, payload: String?, carriesValues: Bool) {
            self.name = name
            self.payload = payload
            self.carriesValues = carriesValues
        }
    }

    public var base: String
    public var baseIsProtocol: Bool
    public var enumName: String
    public var cases: [Case]

    public init(base: String, baseIsProtocol: Bool, enumName: String, cases: [Case]) {
        self.base = base
        self.baseIsProtocol = baseIsProtocol
        self.enumName = enumName
        self.cases = cases
    }
}

extension BinaryModule {
    /// Reads `swift symbolgraph-extract` output. Files named `Module@Other.symbols.json` only extend other modules
    /// and are left out by the caller.
    public static func load(_ urls: [URL]) throws -> BinaryModule {
        var module: BinaryModule?
        for url in urls {
            let data = try Data(contentsOf: url)
            guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { continue }
            let name = (root["module"] as? [String: Any])?["name"] as? String ?? "Module"
            var current = module ?? BinaryModule(name: name)
            current.add(graph: root)
            module = current
        }
        return module ?? BinaryModule(name: "Module")
    }

    /// What one graph's symbols say before its relationships are read.
    private struct SymbolIndex {
        var symbolByID: [String: [String: Any]] = [:]
        var typeNameByID: [String: String] = [:]
        var onEnums: [[String: Any]] = []
    }

    private static let nsObject = "c:objc(cs)NSObject"

    private static let typeKinds: [String: BinaryType.Kind] = [
        "swift.class": .classType, "swift.struct": .structure, "swift.enum": .enumeration, "swift.protocol": .protocolType,
    ]

    mutating func add(graph root: [String: Any]) {
        var index = SymbolIndex()
        for symbol in root["symbols"] as? [[String: Any]] ?? [] { addSymbol(symbol, to: &index) }
        for relationship in root["relationships"] as? [[String: Any]] ?? [] { addRelationship(relationship, index) }
        for function in index.onEnums { addSealed(function, index) }
    }

    private mutating func addSymbol(_ symbol: [String: Any], to index: inout SymbolIndex) {
        guard let id = Self.preciseID(symbol), let kind = Self.kind(symbol), let path = symbol["pathComponents"] as? [String]
        else { return }
        index.symbolByID[id] = symbol
        if kind == "swift.func", path == ["onEnum(of:)"], Self.isPublic(symbol) {
            index.onEnums.append(symbol)
            return
        }
        if kind == "swift.typealias", Self.isPublic(symbol), let equals = Self.text(symbol).range(of: " = ") {
            aliases[path.joined(separator: ".")] = String(Self.text(symbol)[equals.upperBound...])
            return
        }
        guard let typeKind = Self.typeKinds[kind] else { return }
        let name = path.joined(separator: ".")
        index.typeNameByID[id] = name
        guard Self.isPublic(symbol) else { return }
        var type = types[name] ?? BinaryType(name: name, kind: typeKind)
        type.isOpen = symbol["accessLevel"] as? String == "open"
        type.isGeneric = !(((symbol["swiftGenerics"] as? [String: Any])?["parameters"] as? [Any]) ?? []).isEmpty
        type.isImported = id.hasPrefix("c:")
        types[name] = type
    }

    private mutating func addRelationship(_ relationship: [String: Any], _ index: SymbolIndex) {
        guard let kind = relationship["kind"] as? String, let source = relationship["source"] as? String,
            let target = relationship["target"] as? String
        else { return }
        if kind == "conformsTo", target == "s:s12CaseIterableP", let name = index.typeNameByID[source] {
            types[name]?.isCaseIterable = true
            return
        }
        if kind == "inheritsFrom", let name = index.typeNameByID[source], types[name] != nil {
            if let superclass = index.typeNameByID[target], types[superclass] != nil {
                types[name]?.superclass = superclass
            } else if target != Self.nsObject {
                // `NSObject`'s own settable properties (accessibility, KVC) are not the value a mapper reads.
                types[name]?.unknownSuperclass =
                    index.typeNameByID[target] ?? relationship["targetFallback"] as? String ?? target
            }
            return
        }
        guard kind == "memberOf", let owner = index.typeNameByID[target], types[owner] != nil,
            let member = index.symbolByID[source], let memberKind = Self.kind(member), Self.isPublic(member)
        else { return }
        guard !Self.isUnavailable(member) else {
            if memberKind == "swift.enum.case" { types[owner]?.unavailableCases.append(Self.sealedCase(member).name) }
            return
        }
        addMember(member, kind: memberKind, to: owner)
    }

    private mutating func addMember(_ member: [String: Any], kind: String, to owner: String) {
        let title = ((member["names"] as? [String: Any])?["title"] as? String) ?? ""
        switch kind {
        case "swift.enum.case":
            types[owner]?.cases.append(Self.sealedCase(member))
        case "swift.init":
            if !Self.text(member).contains("init?"), !Self.isDeprecated(member), let parameters = Self.parameters(member) {
                types[owner]?.inits.append(parameters)
            }
        case "swift.property":
            if let type = Self.propertyType(member) { types[owner]?.properties.append(TypeParam(label: title, type: type)) }
            if Self.text(member).contains(" set") { types[owner]?.settable.insert(title) }
        case "swift.method":
            types[owner]?.methods.append((Self.text(member).hasPrefix("mutating ") ? "mutating " : "") + title)
        case "swift.type.property" where title == "shared":
            if Self.propertyType(member) == owner.split(separator: ".").last.map(String.init) { types[owner]?.hasShared = true }
        default: break
        }
    }

    private mutating func addSealed(_ function: [String: Any], _ index: SymbolIndex) {
        let parameter = Self.text(function).components(separatedBy: ") -> ").first ?? ""
        // SKIE's `onEnum<__Sealed: Base>(of: __Sealed)` names the base in its constraint; a plain
        // `onEnum(of: Base)` in its parameter. The overload taking an optional is left out.
        let constraint = ((function["swiftGenerics"] as? [String: Any])?["constraints"] as? [[String: Any]])?.first
        let signature = function["functionSignature"] as? [String: Any]
        let parameterFragments =
            (signature?["parameters"] as? [[String: Any]])?.first?["declarationFragments"] as? [[String: Any]] ?? []
        let parameterType = parameterFragments.last { $0["preciseIdentifier"] != nil }?["preciseIdentifier"] as? String
        guard !parameter.hasSuffix("?"),
            let basePrecise = constraint?["rhsPrecise"] as? String ?? parameterType, let base = index.typeNameByID[basePrecise],
            let returns = signature?["returns"] as? [[String: Any]],
            let enumPrecise = returns.last(where: { $0["preciseIdentifier"] != nil })?["preciseIdentifier"] as? String
        else { return }
        guard let enumName = index.typeNameByID[enumPrecise], let enumType = types[enumName] else {
            sealedEnumsMissing += 1
            return
        }
        sealed[base] = SealedHierarchy(
            base: base, baseIsProtocol: types[base]?.kind == .protocolType, enumName: enumName, cases: enumType.cases)
    }

    // MARK: Symbol fields

    private static func preciseID(_ symbol: [String: Any]) -> String? {
        (symbol["identifier"] as? [String: Any])?["precise"] as? String
    }

    private static func kind(_ symbol: [String: Any]) -> String? {
        (symbol["kind"] as? [String: Any])?["identifier"] as? String
    }

    private static func isPublic(_ symbol: [String: Any]) -> Bool {
        let level = symbol["accessLevel"] as? String ?? "public"
        return level == "public" || level == "open"
    }

    private static func isUnavailable(_ symbol: [String: Any]) -> Bool {
        let availability = symbol["availability"] as? [[String: Any]] ?? []
        return availability.contains { ($0["isUnconditionallyUnavailable"] as? Bool) == true }
    }

    private static func isDeprecated(_ symbol: [String: Any]) -> Bool {
        let availability = symbol["availability"] as? [[String: Any]] ?? []
        return availability.contains { ($0["isUnconditionallyDeprecated"] as? Bool) == true || $0["deprecated"] != nil }
    }

    private static func text(_ symbol: [String: Any]) -> String {
        (symbol["declarationFragments"] as? [[String: Any]] ?? []).compactMap { $0["spelling"] as? String }.joined()
    }

    /// `var name: Type { get }` gives `Type`.
    private static func propertyType(_ symbol: [String: Any]) -> String? {
        let declaration = text(symbol)
        guard let colon = declaration.range(of: ": ") else { return nil }
        let rest = declaration[colon.upperBound...]
        let end = rest.range(of: " {")?.lowerBound ?? rest.endIndex
        return String(rest[..<end]).trimmingCharacters(in: .whitespaces)
    }

    private static func parameters(_ symbol: [String: Any]) -> [TypeParam]? {
        guard let signature = symbol["functionSignature"] as? [String: Any] else { return [] }
        var result: [TypeParam] = []
        for parameter in signature["parameters"] as? [[String: Any]] ?? [] {
            guard let name = parameter["name"] as? String,
                let fragments = parameter["declarationFragments"] as? [[String: Any]]
            else { return nil }
            let text = fragments.compactMap { $0["spelling"] as? String }.joined()
            guard let colon = text.range(of: ": ") else { return nil }
            result.append(TypeParam(label: name == "_" ? nil : name, type: String(text[colon.upperBound...])))
        }
        return result
    }

    /// `case vectorGroup(UiVectorGroup)` gives the case `vectorGroup` carrying `UiVectorGroup`.
    private static func sealedCase(_ symbol: [String: Any]) -> SealedHierarchy.Case {
        let path = symbol["pathComponents"] as? [String] ?? []
        let full = path.last ?? ""
        let name = String(full.prefix { $0 != "(" })
        let declaration = text(symbol)
        guard let open = declaration.firstIndex(of: "("), declaration.hasSuffix(")") else {
            return .init(name: name, payload: nil, carriesValues: declaration.contains("("))
        }
        let payload = declaration[declaration.index(after: open)..<declaration.index(before: declaration.endIndex)]
        return .init(name: name, payload: payload.contains(",") || payload.contains(":") ? nil : String(payload), carriesValues: true)
    }
}
