/// What the generator knows about the types a Rule can take as input.
/// Filled from two compiler-derived sources: the Swift symbol graph of a framework (`SymbolGraphLoader`)
/// and the syntax of the app's own sources (`SourceIndexer`).
public struct TypeParam: Equatable, Sendable {
    public var label: String?
    public var type: String

    public init(label: String?, type: String) {
        self.label = label
        self.type = type
    }
}

public struct TypeEnumCase: Equatable, Sendable {
    public var name: String
    public var params: [TypeParam]

    public init(name: String, params: [TypeParam] = []) {
        self.name = name
        self.params = params
    }
}

public enum TypeKind: Sendable { case enumeration, structure, classType, protocolType }

public struct TypeInfo: Sendable {
    public var name: String
    public var kind: TypeKind
    public var cases: [TypeEnumCase] = []
    public var inits: [[TypeParam]] = []
    public var hasShared = false
    public var isGeneric = false
    public var isPrivate = false
    /// Declared `public` or `open`; a type that is not cannot be named from another module.
    public var isPublic = false
    /// Initialisers that are not `public` (and the memberwise one, which is internal): usable only inside the module.
    public var internalOnlyInits: [[TypeParam]] = []
    public var fromSource = false
    /// The module that declares the type, when known; used to tell apart equal names from different modules.
    public var module: String?
    /// Why a source type cannot be built (property wrappers, private storage), if it cannot.
    public var unsupported: String?

    public init(name: String, kind: TypeKind) {
        self.name = name
        self.kind = kind
    }
}

public final class TypeIndex {
    /// One type per canonical name: the source declaration when both a source and a framework declare the name.
    public private(set) var types: [String: TypeInfo] = [:]
    private var variants: [String: [TypeInfo]] = [:]
    private var byLastComponent: [String: [String]] = [:]
    /// What the Rule being generated can see: its module and the modules its file imports. It decides which
    /// declaration wins when two modules declare the same name.
    public var visibleModules: Set<String> = []
    /// The module of the Rule being generated; its own internal types and initialisers are reachable.
    public var ruleModule: String?
    /// Modules the generated file imports; a type from any other module cannot be named there.
    public var reachableModules: Set<String> = []
    /// Direct subtypes by the parent's canonical name (symbol graph) or last component (source).
    public private(set) var subtypes: [String: [String]] = [:]
    /// `typealias` declarations by canonical name.
    public var aliases: [String: String] = [:]

    public init() {}

    public func add(_ info: TypeInfo) {
        if variants[info.name] == nil {
            byLastComponent[Self.lastComponent(info.name), default: []].append(info.name)
        }
        if let existing = variants[info.name]?.firstIndex(where: { $0.module == info.module }) {
            variants[info.name]?[existing] = info
        } else {
            variants[info.name, default: []].append(info)
        }
        types[info.name] = primary(of: info.name)
    }

    /// Changes the declaration of `name` in `module` (the only one, when `module` is nil).
    public func update(_ name: String, module: String? = nil, _ change: (inout TypeInfo) -> Void) {
        guard var list = variants[name],
            let position = list.firstIndex(where: { module == nil || $0.module == module })
        else { return }
        change(&list[position])
        variants[name] = list
        types[name] = primary(of: name)
    }

    /// True when two modules declare `name`, so generated code must spell the module.
    public func isAmbiguous(_ name: String) -> Bool { (variants[name]?.count ?? 0) > 1 }

    private func primary(of name: String) -> TypeInfo? {
        guard let list = variants[name] else { return nil }
        if list.count > 1 {
            let visible = list.filter { $0.module.map(visibleModules.contains) ?? false }
            if let best = visible.first(where: \.fromSource) ?? visible.first { return best }
        }
        return list.first(where: \.fromSource) ?? list.first
    }

    public func addSubtype(_ child: String, of parent: String) {
        if !(subtypes[parent]?.contains(child) ?? false) { subtypes[parent, default: []].append(child) }
    }

    /// Finds the type a source spelling refers to. `scope` is the canonical name of the enclosing type
    /// (for a nested `Input` inside `XRule`, the scope is `XRule`).
    public func resolve(_ spelling: String, scope: String? = nil) -> TypeInfo? {
        var name = spelling
        for prefix in ["any ", "some "] where name.hasPrefix(prefix) { name = String(name.dropFirst(prefix.count)) }
        var current = scope
        while let scopeName = current {
            if let found = primary(of: "\(scopeName).\(name)") { return found }
            current = scopeName.lastIndex(of: ".").map { String(scopeName[..<$0]) }
        }
        if let found = primary(of: name) { return found }
        // `Module.Type` spellings: drop leading components until something matches.
        var parts = name.split(separator: ".").map(String.init)
        while parts.count > 1 {
            parts.removeFirst()
            if let found = primary(of: parts.joined(separator: ".")) { return found }
        }
        let candidates = byLastComponent[Self.lastComponent(name)] ?? []
        return candidates.count == 1 ? primary(of: candidates[0]) : nil
    }

    public func type(named name: String) -> TypeInfo? { primary(of: name) }

    static func lastComponent(_ name: String) -> String {
        name.split(separator: ".").last.map(String.init) ?? name
    }
}
