public import Foundation

/// Reads the output of `swift symbolgraph-extract` (the compiler's own description of a module's public
/// API, as Swift sees it) into a `TypeIndex`: classes, protocols, enums with their cases, initialisers with
/// labels and types, `shared` singletons, and who conforms to or inherits from whom.
public enum SymbolGraphLoader {
    public static func load(_ urls: [URL], into index: TypeIndex) throws {
        for url in urls {
            let data = try Data(contentsOf: url)
            guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                let symbols = root["symbols"] as? [[String: Any]],
                let relationships = root["relationships"] as? [[String: Any]]
            else { continue }
            let module = (root["module"] as? [String: Any])?["name"] as? String
            load(symbols: symbols, relationships: relationships, module: module, into: index)
        }
    }

    static func load(
        symbols: [[String: Any]], relationships: [[String: Any]], module moduleName: String? = nil, into index: TypeIndex
    ) {
        var typeNameByID: [String: String] = [:]
        var symbolByID: [String: [String: Any]] = [:]

        for symbol in symbols {
            guard let id = (symbol["identifier"] as? [String: Any])?["precise"] as? String,
                let kind = (symbol["kind"] as? [String: Any])?["identifier"] as? String,
                let path = symbol["pathComponents"] as? [String]
            else { continue }
            symbolByID[id] = symbol
            let typeKind: TypeKind
            switch kind {
            case "swift.class": typeKind = .classType
            case "swift.struct": typeKind = .structure
            case "swift.enum": typeKind = .enumeration
            case "swift.protocol": typeKind = .protocolType
            default: continue
            }
            guard path.first != "Skie", isPublic(symbol) else { continue }
            let name = path.joined(separator: ".")
            typeNameByID[id] = name
            var info = TypeInfo(name: name, kind: typeKind)
            info.module = moduleName
            info.isPublic = true
            if index.type(named: name)?.module != moduleName { index.add(info) }
        }

        for relationship in relationships {
            guard let kind = relationship["kind"] as? String,
                let source = relationship["source"] as? String,
                let target = relationship["target"] as? String
            else { continue }
            switch kind {
            case "conformsTo", "inheritsFrom":
                if let child = typeNameByID[source], let parent = typeNameByID[target], child != parent {
                    index.addSubtype(child, of: parent)
                }
            case "memberOf":
                guard let owner = typeNameByID[target], let member = symbolByID[source],
                    let memberKind = (member["kind"] as? [String: Any])?["identifier"] as? String,
                    isPublic(member), !isUnavailable(member)
                else { continue }
                let title = ((member["names"] as? [String: Any])?["title"] as? String) ?? ""
                switch memberKind {
                case "swift.init":
                    if let params = parameters(of: member), !fragmentText(member).contains("init?") {
                        index.update(owner, module: moduleName) { $0.inits.append(params) }
                    }
                case "swift.enum.case":
                    let caseName = (member["pathComponents"] as? [String])?.last ?? title
                    index.update(owner, module: moduleName) { $0.cases.append(TypeEnumCase(name: caseName)) }
                case "swift.type.property" where title == "shared":
                    index.update(owner, module: moduleName) { $0.hasShared = true }
                default: break
                }
            default: break
            }
        }
    }

    private static func isPublic(_ symbol: [String: Any]) -> Bool {
        let level = symbol["accessLevel"] as? String ?? "public"
        return level == "public" || level == "open"
    }

    private static func isUnavailable(_ symbol: [String: Any]) -> Bool {
        let availability = symbol["availability"] as? [[String: Any]] ?? []
        return availability.contains { ($0["isUnconditionallyUnavailable"] as? Bool) == true }
    }

    private static func fragmentText(_ symbol: [String: Any]) -> String {
        (symbol["declarationFragments"] as? [[String: Any]] ?? []).compactMap { $0["spelling"] as? String }.joined()
    }

    private static func parameters(of symbol: [String: Any]) -> [TypeParam]? {
        guard let signature = symbol["functionSignature"] as? [String: Any] else { return [] }
        var result: [TypeParam] = []
        for parameter in signature["parameters"] as? [[String: Any]] ?? [] {
            guard let name = parameter["name"] as? String,
                let fragments = parameter["declarationFragments"] as? [[String: Any]]
            else { return nil }
            var text = fragments.compactMap { $0["spelling"] as? String }.joined()
            guard let colon = text.range(of: ": ") else { return nil }
            text = String(text[colon.upperBound...])
            result.append(TypeParam(label: name == "_" ? nil : name, type: text))
        }
        return result
    }
}
