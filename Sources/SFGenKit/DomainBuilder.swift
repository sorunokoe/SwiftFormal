import Foundation

/// Why a type could not be turned into a domain.
public struct Unsupported: Error, CustomStringConvertible {
    public let reason: String
    public init(_ reason: String) { self.reason = reason }
    public var description: String { reason }
}

/// Values worth trying for each scalar type, taken from the literals in one Rule's own code.
public struct ValuePool: Sendable {
    public var id: String
    public var ints: [Int]
    public var doubles: [Double]
    public var strings: [String]

    public init(id: String, ints: [Int] = [], doubles: [Double] = [], strings: [String] = []) {
        self.id = id
        self.ints = ints
        self.doubles = doubles
        self.strings = strings
    }
}

/// Turns a Swift type into the source text of a `Domain` of that type.
///
/// The generated declarations are file-level `private let`s named `sfd_N`, in dependency order, so they are
/// built once and shared. Scalars get the literals of the Rule (and the values just beside them, which is where
/// `<` and `==` change their answer) plus a few fixed edge values. Enums become the union of their cases,
/// classes and structs the combinations of their initialiser arguments, protocols the union of their
/// constructible conformers. Everything built from sampled values is marked a sample, so verdicts over it
/// are `bounded`, never `proved`.
public final class DomainBuilder {
    public let index: TypeIndex
    /// Declarations in dependency order.
    public private(set) var declarations: [String] = []
    /// How many conformers or cases were dropped because they could not be built, per type, for the report.
    public private(set) var dropped: [String: [String]] = [:]

    private var built: [String: String] = [:]
    private var failed: [String: Unsupported] = [:]
    private var inProgress: Set<String> = []
    private var counter = 0

    private let maxConformers = 12
    private let maxDepth = 8

    public init(index: TypeIndex) { self.index = index }

    /// A built domain: the name of its global and the Swift spelling of its value type.
    public struct Built {
        public let name: String
        public let type: String
    }

    public func domain(for spelling: String, scope: String?, pool: ValuePool?) throws -> Built {
        try build(spelling, scope: scope, pool: pool, depth: 0)
    }

    // MARK: Dispatch

    private func build(_ rawSpelling: String, scope: String?, pool: ValuePool?, depth: Int) throws -> Built {
        guard depth <= maxDepth else { throw Unsupported("nesting deeper than \(maxDepth)") }
        var spelling = rawSpelling.trimmingCharacters(in: .whitespaces)
        for noise in ["@escaping ", "@Sendable ", "inout ", "borrowing ", "consuming "] where spelling.hasPrefix(noise) {
            spelling = String(spelling.dropFirst(noise.count))
        }
        if spelling.contains("->") { throw Unsupported("closure type \(spelling)") }

        if spelling.hasSuffix("?") || spelling.hasSuffix("!") {
            let inner = try build(String(spelling.dropLast()), scope: scope, pool: pool, depth: depth + 1)
            let type = "\(parenthesised(inner.type))?"
            return memo("optional|\(type)|\(pool?.id ?? "")", type: type) {
                "Domain<\(type)>.optional(\(inner.name))"
            }
        }
        if spelling.hasPrefix("Optional<"), spelling.hasSuffix(">") {
            return try build(String(spelling.dropFirst(9).dropLast()) + "?", scope: scope, pool: pool, depth: depth)
        }
        if spelling.hasPrefix("Array<"), spelling.hasSuffix(">") {
            return try build("[" + String(spelling.dropFirst(6).dropLast()) + "]", scope: scope, pool: pool, depth: depth)
        }
        if spelling.hasPrefix("["), spelling.hasSuffix("]") {
            let inner = String(spelling.dropFirst().dropLast())
            if inner.contains(":") { throw Unsupported("dictionary type \(spelling)") }
            let element = try build(inner, scope: scope, pool: pool, depth: depth + 1)
            let type = "[\(element.type)]"
            return memo("array|\(type)|\(pool?.id ?? "")", type: type) {
                "Domain<\(type)>.arrays(of: \(element.name).evenlySpaced(3), maxLength: 2)"
            }
        }
        if spelling.hasPrefix("(") { throw Unsupported("tuple or parenthesised type \(spelling)") }
        if spelling.contains("<") { throw Unsupported("generic type \(spelling)") }

        var bare = spelling.hasPrefix("any ") ? String(spelling.dropFirst(4)) : spelling
        if let target = Self.skieTypeDefTarget(bare) { bare = unprefixed(target) }
        if let scalar = try scalar(bare, pool: pool) { return scalar }
        if let target = index.aliases[scope.map { "\($0).\(bare)" } ?? bare] ?? index.aliases[bare] {
            return try build(target, scope: scope, pool: pool, depth: depth + 1)
        }
        guard let info = index.resolve(bare, scope: scope) else { throw Unsupported("unknown type \(bare)") }
        return try buildNamed(info, pool: info.fromSource ? pool : nil, depth: depth)
    }

    private func parenthesised(_ type: String) -> String { type.hasPrefix("any ") ? "(\(type))" : type }

    // MARK: Named types

    private func buildNamed(_ info: TypeInfo, pool: ValuePool?, depth: Int) throws -> Built {
        let key = "type|\(qualified(info))|\(info.fromSource ? pool?.id ?? "" : "")"
        if let name = built[key] { return Built(name: name, type: spelling(of: info)) }
        if let failure = failed[key] { throw failure }
        if inProgress.contains(key) { throw Unsupported("recursive type \(info.name)") }
        inProgress.insert(key)
        defer { inProgress.remove(key) }
        // Names inside a type's own declaration mean what that module means by them.
        let outerModules = index.visibleModules
        if let module = info.module { index.visibleModules = info.fromSource ? outerModules.union([module]) : [module] }
        defer { index.visibleModules = outerModules }

        do {
            if info.isGeneric { throw Unsupported("generic type \(info.name)") }
            if info.isPrivate { throw Unsupported("private type \(info.name)") }
            if let module = info.module, module != index.ruleModule, !index.reachableModules.isEmpty,
                !index.reachableModules.contains(module)
            {
                throw Unsupported("type \(info.name) is in module \(module), which the generated file does not import")
            }
            if info.fromSource, !info.isPublic, let module = info.module, module != index.ruleModule {
                throw Unsupported("internal type \(info.name) of module \(module)")
            }
            if let reason = info.unsupported { throw Unsupported("\(info.name): \(reason)") }
            let type = spelling(of: info)
            let expression: String
            switch info.kind {
            case .enumeration: expression = try enumerationExpression(info, type: type, pool: pool, depth: depth)
            case .protocolType: expression = try unionExpression(info, type: type, pool: pool, depth: depth)
            case .structure, .classType:
                if info.hasShared {
                    expression = "Domain<\(type)>.just(\(qualified(info)).shared)"
                } else {
                    do {
                        expression = try constructExpression(info, type: type, pool: pool, depth: depth)
                    } catch let constructionError as Unsupported {
                        guard let union = try? unionExpression(info, type: type, pool: pool, depth: depth) else {
                            throw constructionError
                        }
                        expression = union
                    }
                }
            }
            let name = declare("Domain<\(type)>", expression)
            built[key] = name
            return Built(name: name, type: type)
        } catch let error as Unsupported {
            // A cycle only fails this attempt: the same type can be built when it is the outermost one.
            if !error.reason.hasPrefix("recursive type") { failed[key] = error }
            throw error
        }
    }

    private func spelling(of info: TypeInfo) -> String {
        info.kind == .protocolType ? "any \(qualified(info))" : qualified(info)
    }

    /// The name to write in generated code: with its module when two modules declare the same name.
    private func qualified(_ info: TypeInfo) -> String {
        if index.isAmbiguous(info.name), let module = info.module { return "\(module).\(info.name)" }
        return info.name
    }

    private func enumerationExpression(_ info: TypeInfo, type: String, pool: ValuePool?, depth: Int) throws -> String {
        guard !info.cases.isEmpty else { throw Unsupported("enum \(info.name) has no cases") }
        if info.cases.allSatisfy({ $0.params.isEmpty }) {
            return "Domain<\(type)>.of([\(info.cases.map { "\(type).\(identifier($0.name))" }.joined(separator: ", "))])"
        }
        var parts: [String] = []
        var partial = false
        for enumCase in info.cases {
            if enumCase.params.isEmpty {
                parts.append("Domain<\(type)>.just(\(type).\(identifier(enumCase.name)))")
                continue
            }
            do {
                parts.append(
                    try combinationExpression(
                        type: type, call: "\(type).\(identifier(enumCase.name))", params: enumCase.params,
                        scope: info.name, pool: pool, depth: depth
                    ))
            } catch let error as Unsupported {
                partial = true
                dropped[info.name, default: []].append("case \(enumCase.name): \(error.reason)")
            }
        }
        guard !parts.isEmpty else { throw Unsupported("no case of \(info.name) could be built") }
        return "Domain<\(type)>.union([\(parts.joined(separator: ", "))])" + (partial ? ".asSample" : "")
    }

    private func constructExpression(_ info: TypeInfo, type: String, pool: ValuePool?, depth: Int) throws -> String {
        var lastError = Unsupported("\(info.name) has no usable initialiser")
        let sameModule = info.module == nil || info.module == index.ruleModule
        let usable = info.inits + (sameModule ? info.internalOnlyInits : [])
        for params in usable.sorted(by: { $0.count < $1.count }) {
            do {
                return try combinationExpression(
                    type: type, call: qualified(info), params: params, scope: info.name, pool: pool, depth: depth
                )
            } catch let error as Unsupported { lastError = error }
        }
        throw lastError
    }

    private func unionExpression(_ info: TypeInfo, type: String, pool: ValuePool?, depth: Int) throws -> String {
        var seen: Set<String> = [info.name]
        var queue = [info.name]
        var concrete: [TypeInfo] = []
        while !queue.isEmpty {
            let current = queue.removeFirst()
            for childName in index.subtypes[current] ?? [] where seen.insert(childName).inserted {
                queue.append(childName)
                guard let child = index.type(named: childName) ?? index.resolve(childName), child.kind != .protocolType else { continue }
                if !child.isGeneric, !child.isPrivate { concrete.append(child) }
            }
        }
        // Simplest constructors first: they are the least likely to fail and the cheapest to build.
        func size(_ type: TypeInfo) -> Int { type.hasShared ? -1 : (type.inits + type.internalOnlyInits).map(\.count).min() ?? 99 }
        concrete.sort { size($0) < size($1) }
        var parts: [String] = []
        var reasons: [String] = []
        for child in concrete {
            if parts.count >= maxConformers {
                dropped[info.name, default: []].append("more than \(maxConformers) conformers; the rest are not covered"); break
            }
            do {
                let member = try buildNamed(child, pool: child.fromSource ? pool : nil, depth: depth + 1)
                parts.append("\(member.name).map { (value: \(member.type)) -> \(type) in value }")
            } catch let error as Unsupported { reasons.append("\(child.name): \(error.reason)") }
        }
        if !reasons.isEmpty { dropped[info.name, default: []].append(contentsOf: reasons) }
        guard !parts.isEmpty else {
            throw Unsupported("no constructible subtype of \(info.name)" + (reasons.first.map { " (\($0))" } ?? ""))
        }
        let partial = !reasons.isEmpty || concrete.count > maxConformers
        return "Domain<\(type)>.union([\(parts.joined(separator: ", "))])" + (partial ? ".asSample" : "")
    }

    private func combinationExpression(
        type: String, call: String, params: [TypeParam], scope: String, pool: ValuePool?, depth: Int
    ) throws -> String {
        if params.isEmpty { return "Domain<\(type)>.just(\(call)())" }
        let domains = try params.map { try build($0.type, scope: scope, pool: pool, depth: depth + 1) }
        let levels = domains.map { "\($0.name).count" }.joined(separator: ", ")
        let complete = domains.map { "\($0.name).complete" }.joined(separator: " && ")
        let arguments = zip(params, domains).enumerated().map { offset, pair in
            (pair.0.label.map { "\(identifier($0)): " } ?? "") + "\(pair.1.name)[$0[\(offset)]]"
        }.joined(separator: ", ")
        return "Domain<\(type)>.combinations(levels: [\(levels)], complete: \(complete)) { \(call)(\(arguments)) }"
    }

    // MARK: Scalars

    private func scalar(_ name: String, pool: ValuePool?) throws -> Built? {
        let key = "scalar|\(name)|\(pool?.id ?? "")"
        if let existing = built[key] { return Built(name: existing, type: name) }
        let expression: String
        switch name {
        case "Bool": expression = "Domain<Bool>.bool"
        case "Int", "Int8", "Int16", "Int32", "Int64", "UInt", "UInt8", "UInt16", "UInt32", "UInt64":
            let (low, high) = Self.range(of: name)
            let values = Self.intValues(pool?.ints ?? []).filter { $0 >= low && $0 <= high }
            expression = "Domain<\(name)>.samples([\(values.map { "\($0)" }.joined(separator: ", "))])"
        case "Double", "Float", "CGFloat", "TimeInterval", "Float32", "Float64":
            let values = Self.doubleValues(pool?.doubles ?? [])
            expression = "Domain<\(name)>.samples([\(values.map { Self.literal($0) }.joined(separator: ", "))])"
        case "String":
            let values = Self.stringValues(pool?.strings ?? [])
            expression = "Domain<String>.samples([\(values.map(Self.quoted).joined(separator: ", "))])"
        case "Date":
            expression = "Domain<Date>.samples([Date(timeIntervalSince1970: 0), Date(timeIntervalSince1970: 1_700_000_000)])"
        case "Locale":
            expression = "Domain<Locale>.samples([Locale(identifier: \"en_US\"), Locale(identifier: \"da_DK\")])"
        case "TimeZone":
            expression = "Domain<TimeZone>.samples([TimeZone(identifier: \"UTC\")!, TimeZone(identifier: \"Europe/Copenhagen\")!])"
        case "KotlinInstant":
            let instants = ["0", "1_700_000_000_000"].map {
                "KotlinInstant.Companion.shared.fromEpochMilliseconds(epochMilliseconds: \($0))"
            }
            expression = "Domain<KotlinInstant>.samples([\(instants.joined(separator: ", "))])"
        case "Kotlinx_datetimeLocalDate":
            // Its Kotlin initializer throws on an invalid date, and a Kotlin exception ends the process, so never combine free Ints.
            let dates = [(2024, 2, 29), (2023, 12, 31), (2000, 1, 1)].map {
                "Kotlinx_datetimeLocalDate(year: \($0.0), month: \($0.1), day: \($0.2))"
            }
            expression = "Domain<Kotlinx_datetimeLocalDate>.samples([\(dates.joined(separator: ", "))])"
        case "UUID":
            expression = "Domain<UUID>.samples([UUID(uuidString: \"00000000-0000-0000-0000-000000000000\")!])"
        case "URL":
            expression = "Domain<URL>.samples([URL(string: \"https://example.com\")!, URL(string: \"https://example.com/a?b=1\")!])"
        case "Void", "Never", "Any", "AnyObject": throw Unsupported("type \(name) has no domain")
        case "KotlinInt", "KotlinLong", "KotlinShort", "KotlinByte", "KotlinDouble", "KotlinFloat", "KotlinBoolean":
            let boxed = Self.boxed(name)
            let values: [String] =
                switch boxed.label {
                case "bool": ["false", "true"]
                case "double", "float": Self.doubleValues(pool?.doubles ?? []).map(Self.literal)
                default: Self.intValues(pool?.ints ?? []).map { "\($0)" }
                }
            expression = "Domain<\(name)>.samples([\(values.map { "\(name)(\(boxed.label): \($0))" }.joined(separator: ", "))])"
        default: return nil
        }
        let global = declare("Domain<\(name)>", expression)
        built[key] = global
        return Built(name: global, type: name)
    }

    private static func boxed(_ name: String) -> (label: String, unused: Void) {
        switch name {
        case "KotlinInt": ("int", ())
        case "KotlinLong": ("longLong", ())
        case "KotlinShort": ("short", ())
        case "KotlinByte": ("char", ())
        case "KotlinDouble": ("double", ())
        case "KotlinFloat": ("float", ())
        default: ("bool", ())
        }
    }

    static func range(of type: String) -> (Int, Int) {
        switch type {
        case "Int8": (Int(Int8.min), Int(Int8.max))
        case "Int16": (Int(Int16.min), Int(Int16.max))
        case "Int32": (Int(Int32.min), Int(Int32.max))
        case "UInt8": (0, Int(UInt8.max))
        case "UInt16": (0, Int(UInt16.max))
        case "UInt32": (0, Int(UInt32.max))
        case "UInt", "UInt64": (0, Int.max)
        default: (Int.min, Int.max)
        }
    }

    /// Fixed edges, the Rule's integer literals, and the values just beside each literal.
    static func intValues(_ literals: [Int]) -> [Int] {
        var values: Set<Int> = [0, 1, -1, 2]
        for literal in literals.prefix(8) { values.formUnion([literal, literal - 1, literal + 1]) }
        return Array(values.sorted().prefix(24))
    }

    static func doubleValues(_ literals: [Double]) -> [Double] {
        var values: Set<Double> = [0, 0.5, 1, -1, 100]
        for literal in literals.prefix(8) {
            let step = abs(literal) < 1 ? 0.1 : 1
            values.formUnion([literal, literal - step, literal + step])
        }
        return Array(values.sorted().prefix(24))
    }

    static func stringValues(_ literals: [String]) -> [String] {
        var values = ["", "a", "Hello World"]
        for literal in literals.prefix(8) where !values.contains(literal) { values.append(literal) }
        return values
    }

    static func literal(_ value: Double) -> String {
        value == value.rounded() && abs(value) < 1e9 ? String(format: "%.1f", value) : "\(value)"
    }

    static func quoted(_ text: String) -> String {
        var result = "\""
        for scalar in text.unicodeScalars {
            switch scalar {
            case "\\": result += "\\\\"
            case "\"": result += "\\\""
            case "\n": result += "\\n"
            case "\t": result += "\\t"
            case "\r": result += "\\r"
            default: result.unicodeScalars.append(scalar)
            }
        }
        return result + "\""
    }

    // MARK: Output

    private func memo(_ key: String, type: String, _ expression: () -> String) -> Built {
        if let name = built[key] { return Built(name: name, type: type) }
        let name = declare("Domain<\(type)>", expression())
        built[key] = name
        return Built(name: name, type: type)
    }

    private func declare(_ type: String, _ expression: String) -> String {
        counter += 1
        let name = "sfd_\(counter)"
        declarations.append("private let \(name): \(type) = \(expression)")
        return name
    }

    private static let keywords: Set<String> = [
        "default", "self", "Self", "init", "in", "is", "as", "class", "struct", "enum", "protocol", "func", "var", "let", "for",
        "while", "if", "else", "switch", "case", "return", "import", "operator", "repeat", "subscript", "true", "false", "nil", "super",
        "throw", "throws", "try", "catch", "where", "static", "internal", "private", "public", "extension", "Type", "Protocol",
    ]

    func identifier(_ name: String) -> String { Self.keywords.contains(name) ? "`\(name)`" : name }
}
