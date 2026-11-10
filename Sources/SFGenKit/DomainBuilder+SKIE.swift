import Foundation

// Types exported from Kotlin by SKIE (https://skie.touchlab.co).
extension DomainBuilder {
    /// SKIE spells Kotlin interface types it could not name as `__Skie__TypeDef__N__id_<Name>_`.
    static func skieTypeDefTarget(_ name: String) -> String? {
        guard let range = name.range(of: "__Skie__TypeDef__") else { return nil }
        let rest = name[range.upperBound...]
        guard let id = rest.range(of: "__id_") else { return nil }
        var target = String(rest[id.upperBound...])
        if target.hasSuffix("_") { target.removeLast() }
        return target.isEmpty ? nil : target
    }

    /// SKIE may glue the framework name and Kotlin package onto a typedef target (`SharedKtModelsShot`). When the
    /// target names no type but starts with a known module, the longest camel-case tail that names a type is used.
    func unprefixed(_ target: String) -> String {
        guard index.resolve(target) == nil else { return target }
        let modules = Set(index.types.values.compactMap(\.module)).filter { target.hasPrefix($0) && target.count > $0.count }
        guard let module = modules.max(by: { $0.count < $1.count }) else { return target }
        var tail = target.dropFirst(module.count)
        while !tail.isEmpty {
            if tail.first?.isUppercase == true, index.resolve(String(tail)) != nil { return String(tail) }
            tail = tail.dropFirst()
        }
        return target
    }
}
