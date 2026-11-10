import Foundation
import SFSIL

/// Where a type Scan cannot read sits in what a function reads (app study round 6, L3): `BagStore.State.showTabs` stopped
/// at "type Color" with no place, because the `Color` is a stored field several levels inside `self`. The path follows
/// the declarations the way the type resolver does (stored properties, enum payloads, tuple elements, optionals; not
/// array elements or class fields, which it does not resolve there) and names the first place the type is used.
struct OpaqueTypePath {
    private let target: String
    private let module: SILModule
    private var visited: Set<String> = []

    /// `self.tabs.style: Color` for the type `target` in the parameters (then the result) of `info`, or nil when no
    /// declaration leads to it.
    static func find(_ target: String, in info: FunctionInfo, module: SILModule) -> String? {
        var starts: [(path: String, type: String)] = []
        for (index, type) in info.parameterTypes.enumerated() {
            let isSelf = info.isMethod && index == info.parameterTypes.count - 1
            starts.append((isSelf ? "self" : Verifier.parameterName(index, info: info, labels: info.argumentLabels), type))
        }
        starts.append(("result", info.resultType))
        var search = OpaqueTypePath(target: target, module: module)
        for start in starts {
            if let found = search.path(start.path, start.type, depth: 0) { return found }
        }
        return nil
    }

    private init(target: String, module: SILModule) {
        self.target = target
        self.module = module
    }

    private mutating func path(_ path: String, _ written: String, depth: Int) -> String? {
        let type = Self.plain(written)
        if type == target || type.hasPrefix(target + "<") { return "\(path): \(type)" }
        guard depth < 8 else { return nil }
        if let wrapped = StdlibSummary.optionalWrapped(type) { return self.path(path + "?", wrapped, depth: depth + 1) }
        if type.hasPrefix("("), type.hasSuffix(")") {
            for (index, element) in SpecIndex.passingForm(type).enumerated() {
                if let found = self.path("\(path).\(index)", element, depth: depth + 1) { return found }
            }
            return nil
        }
        guard visited.insert(type).inserted, let members = module.declaredMembers(of: type) else { return nil }
        for member in members {
            if let found = self.path("\(path).\(member.name)", member.type, depth: depth + 1) { return found }
        }
        return nil
    }

    /// The type without how it is passed (`@in_guaranteed`, `@inout`, `$`).
    private static func plain(_ type: String) -> String {
        var t = Substring(type.trimmingCharacters(in: .whitespaces))
        if t.hasPrefix("$") { t = t.dropFirst() }
        for prefix in ["@inout ", "@out ", "@in_guaranteed ", "@in_constant ", "@in ", "@guaranteed ", "@owned "]
        where t.hasPrefix(prefix) {
            t = t.dropFirst(prefix.count)
        }
        return String(t)
    }
}

extension Verifier {
    /// Fills `typePath` of a function that a type stopped (`type Color`, `class Cache`, `indirect enum Tree`, …) and
    /// puts what blocks it in front of the hint: "blocked by field 'model.player.photo' of type CharacterSet."
    /// (app study round 6, L3 and L10).
    static func placeOpaqueType(_ report: inout FunctionReport, _ info: FunctionInfo, module: SILModule) {
        guard let type = refusedType(report.detail ?? ""),
            let path = OpaqueTypePath.find(type, in: info, module: module)
        else { return }
        report.typePath = path
        report.hint = blockedBy(path) + ". " + (report.hint ?? hint(forCategory: report.category ?? "other"))
    }

    /// `K` for the detail `UNSUPPORTED: class K` of a type Scan refuses (the kinds `TypeContext.resolve` throws), or nil
    /// for any other refusal.
    static func refusedType(_ detail: String) -> String? {
        guard detail.hasPrefix("UNSUPPORTED: ") else { return nil }
        let rest = detail.dropFirst("UNSUPPORTED: ".count)
        let kinds = [
            "type ", "\(SILError.ambiguousTypeKind) ", "indirect enum ", "noncopyable struct with a deinit (destroying it runs code) ",
            "noncopyable enum with a deinit (destroying it runs code) ", "generic class ", "generic struct ", "generic enum ",
            "generic protocol ", "generic actor ", "class ", "protocol ", "actor ",
        ]
        guard let kind = kinds.first(where: rest.hasPrefix) else { return nil }
        let type = rest.dropFirst(kind.count).trimmingCharacters(in: .whitespaces)
        return type.isEmpty ? nil : type
    }

    /// "blocked by field 'main.style.link' of type CharacterSet" for the type path `self.main.style.link: CharacterSet`;
    /// a parameter, `self` or the result itself is named as such.
    static func blockedBy(_ typePath: String) -> String {
        guard let split = typePath.range(of: ": ") else { return "blocked by \(typePath)" }
        let place = String(typePath[..<split.lowerBound]), type = String(typePath[split.upperBound...])
        if place == "self" || place == "result" { return "blocked by \(place == "self" ? "self" : "the result"), of type \(type)" }
        if place.hasPrefix("self.") { return "blocked by field '\(place.dropFirst("self.".count))' of type \(type)" }
        if place.contains(".") || place.contains("?") { return "blocked by field '\(place)' of type \(type)" }
        return "blocked by parameter '\(place)' of type \(type)"
    }
}
