import Foundation

/// Builds the domains `BinaryDomainWriter.generate` writes, one type at a time, remembering each type's outcome.
final class BinaryDomainBuilder {
    typealias Failure = BinaryDomainWriter.Failure

    struct Built {
        /// An expression of type `SwiftFormal.Domain<swiftType>`.
        var expression: String
        var swiftType: String
        /// Empty when the domain is exhaustive.
        var sampled: [String]
    }

    /// The body of a type's generated `Domain` member, and why it is a sample if it is one.
    struct Made {
        var body: String
        var sampled: [String]
        var category: BinaryDomainEntry.Category
    }

    struct Member {
        var swiftType: String
        var body: String
        var entry: BinaryDomainEntry
    }

    let module: BinaryModule
    let excluded: Set<String>
    var entries: [String: BinaryDomainEntry] = [:]
    var bodies: [String: Member] = [:]
    var usedMembers: Set<String> = []
    /// Per sealed hierarchy or enum, a `switch` that stops compiling when a case is added or removed.
    var caseChecks: [String: String] = [:]
    var failures: [String: String] = [:]
    var inProgress: Set<String> = []

    let sealedEnums: Set<String>

    init(module: BinaryModule, excluded: Set<String>) {
        self.module = module
        self.excluded = excluded
        sealedEnums = Set(module.sealed.values.map(\.enumName))
    }

    func qualified(_ name: String) -> String { "\(module.name).\(name)" }

    func root(_ name: String) {
        guard let type = module.types[name], entries[name] == nil else { return }
        // A sealed hierarchy's switch enum belongs to its base; a caseless enum is a namespace.
        if type.kind == .enumeration, sealedEnums.contains(name) || (type.cases.isEmpty && !type.isCaseIterable) { return }
        if type.kind == .enumeration, !type.isCaseIterable {
            entries[name] = BinaryDomainEntry(
                type: name, category: .enumeration, status: .skipped, reason: "enum is not CaseIterable", member: nil)
            return
        }
        if type.isOpen && module.sealed[name] == nil {
            entries[name] = BinaryDomainEntry(
                type: name, category: .initializer, status: .skipped,
                reason: "open class: it may be abstract and its subclasses are not listed (built only as another type's field)",
                member: nil)
            return
        }
        _ = named(name)
    }

    /// The domain of a module type, generated once as a `Domain` member.
    func named(_ name: String) -> Result<Built, Failure> {
        let swiftType = module.types[name]?.kind == .protocolType ? "any \(qualified(name))" : qualified(name)
        if let entry = entries[name], let member = entry.member {
            return .success(
                Built(
                    expression: "SwiftFormal.Domain<\(swiftType)>.\(member)", swiftType: swiftType,
                    sampled: entry.status == .bounded ? [name] : []))
        }
        if let reason = failures[name] { return .failure(Failure(reason)) }
        if inProgress.contains(name) { return .failure(Failure("recursive type \(name)")) }
        guard let type = module.types[name] else { return .failure(Failure("no domain for \(name)")) }
        if excluded.contains(name) { return fail(name, .other, "excluded") }
        if type.isGeneric { return fail(name, .other, "generic type") }
        if type.kind == .enumeration {
            guard type.isCaseIterable else { return fail(name, .enumeration, "enum is not CaseIterable") }
            return record(name, type, swiftType: swiftType, .success(enumeration(name, type, swiftType: swiftType)))
        }

        inProgress.insert(name)
        defer { inProgress.remove(name) }
        return record(name, type, swiftType: swiftType, make(name, type, swiftType: swiftType))
    }

    func make(_ name: String, _ type: BinaryType, swiftType: String) -> Result<Made, Failure> {
        if let hierarchy = module.sealed[name] { return sealed(hierarchy, swiftType: swiftType) }
        if type.kind == .protocolType { return .failure(Failure("protocol without an onEnum(of:) switch")) }
        guard type.hasShared && type.inits.allSatisfy(\.isEmpty) else { return initializer(type, swiftType: swiftType) }
        // A singleton; its `init()`, if any, returns the same instance (a Kotlin `object` exports both).
        let sampled = (type.isOpen ? ["open class"] : []) + mutableState(type)
        let body = "SwiftFormal.Domain<\(swiftType)>.just(\(swiftType).shared)" + (sampled.isEmpty ? "" : ".asSample")
        return .success(Made(body: body, sampled: sampled, category: .object))
    }

    func record(_ name: String, _ type: BinaryType, swiftType: String, _ made: Result<Made, Failure>) -> Result<Built, Failure> {
        switch made {
        case .failure(let failure):
            let category: BinaryDomainEntry.Category =
                module.sealed[name] != nil ? .sealed : type.kind == .protocolType ? .other : type.hasShared ? .object : .initializer
            return fail(name, category, failure.reason)
        case .success(let made):
            let sampled = made.sampled
            let member = memberName(for: name)
            let reason = Array(Set(sampled)).sorted().joined(separator: "; ")
            let entry = BinaryDomainEntry(
                type: name, category: made.category, status: sampled.isEmpty ? .exhaustive : .bounded, reason: reason, member: member)
            entries[name] = entry
            bodies[name] = Member(swiftType: swiftType, body: made.body, entry: entry)
            return .success(
                Built(
                    expression: "SwiftFormal.Domain<\(swiftType)>.\(member)", swiftType: swiftType,
                    sampled: sampled.isEmpty ? [] : [name]))
        }
    }

    func fail(_ name: String, _ category: BinaryDomainEntry.Category, _ reason: String) -> Result<Built, Failure> {
        failures[name] = reason
        if entries[name] == nil {
            entries[name] = BinaryDomainEntry(type: name, category: category, status: .skipped, reason: reason, member: nil)
        }
        return .failure(Failure(reason))
    }
}

extension BinaryDomainBuilder {
    // MARK: Kinds of types

    func sealed(_ hierarchy: SealedHierarchy, swiftType: String)
        -> Result<Made, Failure>
    {
        guard !hierarchy.cases.isEmpty else { return .failure(Failure("onEnum(of:) has no cases")) }
        var parts: [String] = []
        var sampled: [String] = []
        let ordered = hierarchy.cases.sorted { $0.name < $1.name }
        for item in ordered {
            guard let payload = item.payload else {
                sampled.append("case \(item.name) carries no subtype")
                continue
            }
            switch domain(of: TypeSpelling.parse(payload)) {
            case .success(let built):
                parts.append("\(built.expression).map { $0 as \(swiftType) }")
                if !built.sampled.isEmpty { sampled.append("case \(item.name) is bounded") }
            case .failure(let failure):
                sampled.append("case \(item.name) dropped: \(failure.reason)")
            }
        }
        guard !parts.isEmpty else { return .failure(Failure("no case of the sealed hierarchy can be built")) }
        // State the base class declares, or inherits, is state of every case.
        if let base = module.types[hierarchy.base], base.kind == .classType { sampled += mutableState(base) }
        let cases = ordered.map { ".\(escaped($0.name))" }.joined(separator: ", ")
        caseChecks[hierarchy.base] = """
            private func sfgenSealedCheck_\(identifier(hierarchy.base))(_ value: \(swiftType)) {
                switch \(module.name).onEnum(of: value) {
                case \(cases): break
                }
            }
            """
        var body = "SwiftFormal.Domain<\(swiftType)>.union([\n" + parts.map { "    \($0),\n" }.joined() + "])"
        if !sampled.isEmpty { body += ".asSample" }
        return .success(Made(body: body, sampled: sampled, category: .sealed))
    }

    func initializer(_ type: BinaryType, swiftType: String)
        -> Result<Made, Failure>
    {
        let propertyNames = Set(type.properties.compactMap(\.label))
        // The initializer that sets the most public properties, then the shortest, then the first by labels.
        let candidates = type.inits.sorted { left, right in
            let leftCovered = Set(left.compactMap(\.label)).intersection(propertyNames).count
            let rightCovered = Set(right.compactMap(\.label)).intersection(propertyNames).count
            if leftCovered != rightCovered { return leftCovered > rightCovered }
            if left.count != right.count { return left.count < right.count }
            return left.map { $0.label ?? "_" }.joined(separator: ":") < right.map { $0.label ?? "_" }.joined(separator: ":")
        }
        guard !candidates.isEmpty else {
            return .failure(Failure(type.hasShared ? "singleton with a public initializer" : "no public initializer"))
        }
        var lastFailure = Failure("no public initializer")
        for parameters in candidates {
            switch build(type, parameters: parameters, swiftType: swiftType, propertyNames: propertyNames) {
            case .success(let made): return .success(made)
            case .failure(let failure): lastFailure = failure
            }
        }
        return .failure(lastFailure)
    }

    func build(_ type: BinaryType, parameters: [TypeParam], swiftType: String, propertyNames: Set<String>)
        -> Result<Made, Failure>
    {
        var sampled: [String] = []
        if type.isOpen { sampled.append("open class") }
        sampled += mutableState(type)
        let uncovered = propertyNames.subtracting(parameters.compactMap(\.label)).sorted()
        if !uncovered.isEmpty {
            sampled.append("properties not set by init(\(labels(parameters))): \(uncovered.joined(separator: ", "))")
        }
        if parameters.isEmpty {
            let body = "SwiftFormal.Domain<\(swiftType)>.just(\(swiftType)())" + (sampled.isEmpty ? "" : ".asSample")
            return .success(Made(body: body, sampled: sampled, category: .initializer))
        }
        var fields: [Built] = []
        for parameter in parameters {
            switch domain(of: TypeSpelling.parse(parameter.type)) {
            case .success(let built):
                fields.append(built)
                sampled += built.sampled.map { "\(parameter.label ?? "_"): \($0) is bounded" }
            case .failure(let failure):
                return .failure(Failure("init(\(labels(parameters))): \(parameter.label ?? "_"): \(failure.reason)"))
            }
        }
        let names = fields.indices.map { "f\($0)" }
        var body = ""
        for (name, field) in zip(names, fields) { body += "let \(name) = \(field.expression)\n" }
        let levels = names.map { "\($0).count" }.joined(separator: ", ")
        let complete = names.map { "\($0).complete" }.joined(separator: " && ")
        let arguments = zip(parameters, names).enumerated().map { index, pair in
            let (parameter, name) = pair
            return parameter.label.map { "\($0): \(name)[$0[\(index)]]" } ?? "\(name)[$0[\(index)]]"
        }.joined(separator: ", ")
        body += "return SwiftFormal.Domain<\(swiftType)>.combinations(levels: [\(levels)], complete: \(complete)) {\n"
        body += "    \(swiftType)(\(arguments))\n"
        body += "}" + (sampled.isEmpty ? "" : ".asSample")
        return .success(Made(body: body, sampled: sampled, category: .initializer))
    }

    /// Why values built by an initializer may not be all the values of `type`: a class's state can change after
    /// it is built, through a settable property or a method, its own or one it inherits from any superclass; a
    /// struct's through a `mutating` method. A superclass the graph does not describe may hold any state.
    func mutableState(_ type: BinaryType) -> [String] {
        var reasons: [String] = []
        var visited: Set<String> = [type.name]
        var current: BinaryType? = type
        while let owner = current {
            let from = owner.name == type.name ? "" : " (from \(owner.name))"
            if owner.kind == .classType, !owner.settable.isEmpty {
                reasons.append("settable \(owner.settable.sorted().joined(separator: ", "))\(from)")
            }
            let changing = owner.methods.filter { method in
                if owner.kind == .structure { return method.hasPrefix("mutating ") }
                return !BinaryDomainWriter.stateless(method)
            }
            if !changing.isEmpty {
                let shown = changing.sorted().prefix(3).joined(separator: ", ") + (changing.count > 3 ? ", …" : "")
                reasons.append("methods may change its state: \(shown)\(from)")
            }
            if let unknown = owner.unknownSuperclass { reasons.append("superclass \(unknown) is not in the symbol graph") }
            guard let superclass = owner.superclass, visited.insert(superclass).inserted else { break }
            current = module.types[superclass]
        }
        return reasons
    }

    /// A `CaseIterable` enum: `allCases`, complete only when the walk finds it lists each of the cases the graph
    /// declares, none twice. A hand-written `allCases` that leaves a case out gives a sample instead.
    func enumeration(_ name: String, _ type: BinaryType, swiftType: String) -> Made {
        var sampled = type.cases.filter(\.carriesValues).map { "case \($0.name) carries values" }
        sampled += type.unavailableCases.sorted().map { "case \($0) is unavailable" }
        if type.isImported { sampled.append("an imported C enum may hold values outside its cases") }
        let all = "Array(\(swiftType).allCases)"
        guard sampled.isEmpty, !type.cases.isEmpty else {
            if type.cases.isEmpty { sampled.append("no cases in the symbol graph") }
            return Made(body: "SwiftFormal.Domain<\(swiftType)>.samples(\(all))", sampled: sampled, category: .enumeration)
        }
        let count = type.cases.count
        let cases = type.cases.map { ".\(escaped($0.name))" }.sorted().joined(separator: ", ")
        caseChecks[name] = """
            private func sfgenEnumCheck_\(identifier(name))(_ value: \(swiftType)) {
                switch value {
                case \(cases): break
                }
            }
            """
        let body = """
            let all = \(swiftType).allCases
            guard all.count == \(count), Set(all).count == \(count) else {
                return SwiftFormal.Domain<\(swiftType)>.samples(Array(all))
            }
            return SwiftFormal.Domain<\(swiftType)>.of(Array(all))
            """
        return Made(body: body, sampled: [], category: .enumeration)
    }
}
