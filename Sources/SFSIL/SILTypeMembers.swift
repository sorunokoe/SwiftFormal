// The members of a declared type as written, for reports that say where a type Scan cannot read sits (app study round 6,
// L3 and L10). No proof reads them: the encoder resolves types with `TypeContext.resolve`.

import Foundation

extension SILModule {
    /// The stored properties of a struct, or the cases that carry a payload of an enum (name and payload type), as the
    /// read modules declare them, with the arguments of a generic type written in. Nil for a type they do not declare
    /// as a struct or enum (a class, a type of another module, a standard type).
    package func declaredMembers(of type: String) -> [(name: String, type: String)]? {
        var t = type.trimmingCharacters(in: .whitespaces)
        for convention in ["@owned ", "@guaranteed "] where t.hasPrefix(convention) { t.removeFirst(convention.count) }
        if let fields = types.structs[t] { return fields }
        if let cases = types.enums[t] { return cases.compactMap { c in c.payload.map { (c.name, $0) } } }
        guard t.hasSuffix(">"), let open = t.firstIndex(of: "<"),
            let declaration = try? types.genericDeclaration(of: String(t[..<open]))
        else { return nil }
        let arguments = splitTopLevel(String(t[t.index(after: open)..<t.index(before: t.endIndex)]))
        guard arguments.count == declaration.parameters.count else { return nil }
        let map = Dictionary(zip(declaration.parameters, arguments), uniquingKeysWith: { first, _ in first })
        if declaration.isEnum {
            return declaration.cases.compactMap { c in c.payload.map { (c.name, types.substituting(map, in: $0)) } }
        }
        return declaration.fields.map { ($0.name, types.substituting(map, in: $0.type)) }
    }
}
