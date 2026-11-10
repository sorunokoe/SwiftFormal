import Foundation
import SFSIL

/// The memberwise initializer of a struct, read from its printed declaration. The compiler prints the implicit one
/// as `init(index: Int = 0, flag: Bool)`; only an initializer whose labels are exactly the struct's settable stored
/// properties (in any order) counts, so a hand-written `init(b:)` that computes the fields is never mistaken for it.
/// A property with an init accessor (`@storageRestrictions(initializes: _index)`, as TCA's `@ObservableState` writes)
/// is taken by its own name and stands for the backing property `_index`. A stored property whose name contains `$`
/// (`_$observationRegistrar`, which only a macro can declare) may be missing from the initializer: it keeps its
/// initial value, and the replay's proof treats it as unknown.
struct MemberwiseInitializer {
    struct Parameter {
        let label: String
        let type: String
        let hasDefault: Bool
        /// The index of the stored property it sets.
        let field: Int
    }
    /// One parameter as printed: `index: Int = 0`.
    struct PrintedParameter {
        let label: String
        let type: String
        let hasDefault: Bool
    }
    let parameters: [Parameter]

    init?(_ declaration: TypeDeclarationText, stored: [String]) {
        let (settable, privateFields) = Self.settableProperties(declaration, stored: stored)
        var best: [Parameter]?
        for member in declaration.members {
            guard let printed = Self.initializerParameters(member) else { continue }
            let mapped = printed.compactMap { p -> Parameter? in
                guard let field = settable[p.label], !privateFields.contains(field) else { return nil }
                return Parameter(label: p.label, type: p.type, hasDefault: p.hasDefault, field: field)
            }
            guard mapped.count == printed.count else { continue }
            // Every settable property is a parameter, except a private one with a default (left out of the internal
            // initializer) and one a macro declared (`_$observationRegistrar`).
            let covered = Set(mapped.map(\.field))
            let complete = settable.allSatisfy { covered.contains($0.value) || privateFields.contains($0.value) || $0.key.contains("$") }
            guard complete else { continue }
            if mapped.count > best?.count ?? -1 { best = mapped }
        }
        guard let best else { return nil }
        parameters = best
    }

    /// The labels a memberwise initializer takes, each with the stored property it sets, and the private stored
    /// properties. A `let` with an initial value is not settable; an init accessor's property stands for `_name`.
    private static func settableProperties(_ declaration: TypeDeclarationText, stored: [String]) -> ([String: Int], Set<Int>) {
        var settable: [String: Int] = [:]
        var privateFields: Set<Int> = []
        var currentProperty: String?
        for member in declaration.members {
            let words = member.split(separator: " ")
            if member.hasPrefix("@_hasStorage"), let name = propertyName(member), let index = stored.firstIndex(of: name) {
                if words.contains("private") || words.contains("fileprivate") { privateFields.insert(index) }
                if !(words.contains("let") && member.contains("@_hasInitialValue")) { settable[name] = index }
                continue
            }
            if member.hasSuffix("{"), let name = propertyName(member) { currentProperty = name }
            if member == "}" { currentProperty = nil }
            if let property = currentProperty, let range = member.range(of: "@storageRestrictions(initializes: ") {
                let target = String(member[range.upperBound...].prefix { $0 != ")" && $0 != "," })
                if target == "_" + property, let index = stored.firstIndex(of: target) {
                    settable[target] = nil
                    settable[property] = index
                }
            }
        }
        return (settable, privateFields)
    }

    /// `index` for `@_hasStorage @_hasInitialValue var index: Int { get set }` or `var selectedTab: Int {`.
    static func propertyName(_ member: String) -> String? {
        guard let keyword = member.range(of: "var ") ?? member.range(of: "let ") else { return nil }
        let rest = member[keyword.upperBound...]
        guard let colon = rest.firstIndex(of: ":") else { return nil }
        let name = String(rest[..<colon])
        return name.allSatisfy { $0.isLetter || $0.isNumber || $0 == "_" || $0 == "$" } ? name : nil
    }

    /// The parameters of `init(index: Int = 0, flag: Bool)`, or nil for another member, a failable, throwing or
    /// `async` initializer, or one with an unlabeled parameter.
    static func initializerParameters(_ member: String) -> [PrintedParameter]? {
        var m = member
        for prefix in ["internal ", "public ", "package ", "nonisolated ", "@inlinable "] where m.hasPrefix(prefix) {
            m.removeFirst(prefix.count)
        }
        guard m.hasPrefix("init("), let close = m.lastIndex(of: ")") else { return nil }
        if m[m.index(after: close)...].contains("throws") || m.contains("async") { return nil }
        var result: [PrintedParameter] = []
        for parameter in splitAtTopLevelCommas(String(m[m.index(m.startIndex, offsetBy: "init(".count)..<close])) {
            let p = parameter.trimmingCharacters(in: .whitespaces)
            guard let colon = p.firstIndex(of: ":") else { return nil }
            let label = String(p[..<colon])
            guard !label.contains(" "), label != "_" else { return nil }
            var type = String(p[p.index(after: colon)...]).trimmingCharacters(in: .whitespaces)
            let hasDefault = type.contains(" = ")
            if let eq = type.range(of: " = ") { type = String(type[..<eq.lowerBound]) }
            result.append(PrintedParameter(label: label, type: type, hasDefault: hasDefault))
        }
        return result
    }
}
