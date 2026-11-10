import Foundation
package import SFBV
import SFCNF

// Objective-C calls (plan item R6-1): the instructions that reach foreign code and what logic makes of their results.
// The reading guide is at the top of `SILForeign.swift`.

// MARK: - instructions

/// `objc_method`, `apply` with `@convention(objc_method)`, and the casts between foreign references; nil for any other
/// instruction (or a cast that is not between foreign references). Throws for what this item leaves out.
func parseForeignInstruction(_ line: String, types: TypeContext) throws(SILError) -> Instruction? {
    guard let eq = line.range(of: " = ") else { return nil }
    let result = String(line[..<eq.lowerBound])
    let rhs = line[eq.upperBound...]
    guard isValue(result), let space = rhs.firstIndex(of: " ") else { return nil }
    let head = String(rhs[..<space])
    let rest = String(rhs[rhs.index(after: space)...])
    switch head {
    case "objc_method": return try objcMethod(result, rest, line, types: types)
    case "apply" where rest.contains(") : $@convention(objc_method) "): return try objcApply(result, rest, line, types: types)
    case "alloc_ref_dynamic", "thick_to_objc_metatype":
        throw SILError.unsupported("creating an Objective-C object is not read yet (\(head))")
    default:
        return try foreignCast(head, result, rest, types: types)
    }
}

/// `init_existential_ref`, `open_existential_ref` and `upcast` from a foreign reference to another: the same object.
/// Nil for any other instruction or types.
private func foreignCast(_ head: String, _ result: String, _ rest: String, types: TypeContext) throws(SILError) -> Instruction? {
    switch head {
    case "init_existential_ref":
        // `%0 : $GKTDomainX : $GKTDomainX, $AnyObject`: the same object, seen as an existential.
        guard let comma = rest.range(of: ", $", options: .backwards), let colon = rest.range(of: " : $") else { return nil }
        let source = String(rest[..<colon.lowerBound])
        let from = String(rest[colon.upperBound...].prefix { $0 != " " && $0 != "," })
        guard isValue(source), try types.foreignObject(from) == TypeContext.objectHandle,
            try types.foreignObject(String(rest[comma.upperBound...])) == TypeContext.objectHandle
        else { return nil }
        return .alias(result: result, source: source)
    case "open_existential_ref", "upcast", "unchecked_ref_cast":
        // `%0 to $@opened("…", any P) Self`, `%0 to $GKTBase`, and a metatype `%1 to $@thick NSObject.Type` (no data).
        guard let to = rest.range(of: " to $", options: .backwards) else { return nil }
        let source = String(rest[..<to.lowerBound].prefix { $0 != " " })
        let target = String(rest[to.upperBound...])
        let metatype = target.hasPrefix("@thick ") && target.hasSuffix(".Type")
        let readable =
            metatype
            ? try types.readableForeign(String(target.dropFirst("@thick ".count).dropLast(".Type".count)), kind: .class)
            : try types.foreignObject(target) == TypeContext.objectHandle
        guard isValue(source), readable else { return nil }
        return .alias(result: result, source: source)
    default:
        return nil
    }
}

/// `objc_method %2, #GKTDomainX.count!getter.foreign : <formal type>, $@convention(objc_method) …`: the method, as a
/// function reference `ForeignCall` recognizes.
private func objcMethod(_ result: String, _ rest: String, _ line: String, types: TypeContext) throws(SILError) -> Instruction {
    guard let hash = rest.range(of: ", #"), let colon = rest.range(of: " : ", range: hash.upperBound..<rest.endIndex) else {
        throw SILError.unsupported("objc_method: \(line)")
    }
    let reference = String(rest[hash.upperBound..<colon.lowerBound])
    guard reference.hasSuffix(".foreign") || reference.hasSuffix("!foreign"), let dot = reference.firstIndex(of: "."),
        let bang = reference[dot...].firstIndex(of: "!")
    else { throw SILError.unsupported("objc_method: \(line)") }
    let owner = String(reference[..<dot])
    let member = String(reference[reference.index(after: dot)..<bang])
    guard !owner.isEmpty, !member.isEmpty else { throw SILError.unsupported("objc_method: \(line)") }
    var readableOwner = try types.readableForeign(owner, kind: .class)
    if !readableOwner { readableOwner = try types.readableForeign(owner, kind: .protocol) }
    guard readableOwner else {
        throw SILError.unsupported(
            types.declaresName(owner)
                ? "an @objc member of \(owner), a type of this module, called through the Objective-C runtime: not read"
                : "an Objective-C call on \(owner), which the compiler did not show to be an imported Objective-C type: \(line)")
    }
    if reference.contains("!initializer") || reference.contains("!allocator") {
        throw SILError.unsupported("creating an Objective-C object (\(owner).\(member)) is not read yet")
    }
    // A member a read module adds to a type it does not declare (`extension GKTDomainX { @objc func m() }`) may be what
    // the call reaches. One of a read class is reached only through an object of that class, which the supertype check
    // has already refused.
    if let owners = types.foreign.swiftMembers[member], let added = owners.first(where: { !types.declaresName($0) }) {
        throw SILError.unsupported(
            "Objective-C call to \(owner).\(member): this module also implements \(member) for Objective-C (on \(added)), "
                + "and the call may reach it")
    }
    // The formal result type (`(GKTDomainX) -> () -> Int32`), for reports: SIL's own result type has no signedness.
    let formal = String(rest[colon.upperBound...])
    let formalResult = formal.range(of: " -> ", options: .backwards).map { String(formal[$0.upperBound...].prefix { $0 != "," }) } ?? ""
    return .functionRef(result: result, symbol: ForeignCall.prefix + reference + ForeignCall.separator + formalResult)
}

/// `apply %4(%2) : $@convention(objc_method) (GKTDomainX) -> Int32`: `self` comes last. Every argument must be a value
/// logic reads that foreign code cannot call back through: an integer, `Bool`, floating point, a foreign reference, an
/// Optional of one or a metatype. Blocks, closures and Swift objects are refused.
private func objcApply(_ result: String, _ rest: String, _ line: String, types: TypeContext) throws(SILError) -> Instruction {
    var argumentsFrom = rest.startIndex
    if let a = rest.firstIndex(of: "<"), let p = rest.firstIndex(of: "("), a < p, let c = matchingClose(rest[a...], open: "<", close: ">") {
        argumentsFrom = c
    }
    guard let open = rest[argumentsFrom...].firstIndex(of: "("), let close = rest.range(of: ") : $@convention(objc_method) ") else {
        throw SILError.unsupported("apply: \(line)")
    }
    var callee = String(rest[..<open])
    var substitutions: [String] = []
    if let angle = callee.firstIndex(of: "<"), callee.hasSuffix(">") {
        substitutions = splitTopLevel(String(callee[callee.index(after: angle)..<callee.index(before: callee.endIndex)]))
        callee = String(callee[..<angle])
    }
    let arguments = try parseValueList(String(rest[rest.index(after: open)..<close.lowerBound]))
    var signature = Substring(rest[close.upperBound...])
    // `<τ_0_0 where τ_0_0 : GKTDomainRecord>`: a protocol's method, generic over `self` only.
    var generic: String?
    if signature.hasPrefix("<"), let end = matchingClose(signature, open: "<", close: ">") {
        let parameters = signature[signature.index(after: signature.startIndex)..<end]
        guard parameters.hasPrefix("τ_0_0 where τ_0_0 : "), !parameters.contains(","), substitutions.count == 1,
            try types.foreignObject(substitutions[0]) == TypeContext.objectHandle
        else { throw SILError.unsupported("generic Objective-C call: \(line)") }
        generic = "τ_0_0"
        signature = signature[signature.index(after: end)...].drop { $0 == " " }
    }
    guard isValue(callee), signature.hasPrefix("("), let end = matchingClose(signature, open: "(", close: ")"),
        signature[signature.index(after: end)...].hasPrefix(" -> ")
    else { throw SILError.unsupported("apply: \(line)") }
    let parameters = splitTopLevel(String(signature[signature.index(after: signature.startIndex)..<end]))
    guard parameters.count == arguments.count, !parameters.isEmpty else { throw SILError.invalid("apply argument count: \(line)") }
    try checkForeignArguments(parameters, generic: generic, types: types)
    let resultText = ForeignCall.strippingConventions(String(signature[signature.index(end, offsetBy: 5)...]))
    let type = try types.resolve(resultText)
    guard !resultText.contains("τ_"), ForeignCall.isPlainValue(type) || type == .aggregate(name: "", fields: []) else {
        throw SILError.unsupported("an Objective-C call that returns a \(resultText)")
    }
    return .apply(
        result: result, callee: callee, arguments: arguments, type: type, substitutions: [],
        conventions: Array(repeating: .value, count: arguments.count))
}

/// Refuses an argument foreign code could call back through or change. `AnyObject` may hold an object of the read
/// modules, and a metatype argument may be a Swift class's: foreign code could send them messages. Only `self` (last)
/// may be a metatype (a class property or method), or the generic parameter of a protocol's method.
private func checkForeignArguments(_ parameters: [String], generic: String?, types: TypeContext) throws(SILError) {
    for (k, parameter) in parameters.enumerated() {
        let text = ForeignCall.strippingConventions(parameter)
        let isSelf = k == parameters.count - 1
        if isSelf, text == generic { continue }
        guard !text.contains("τ_"), !text.contains("AnyObject"), let type = try? types.resolve(text), ForeignCall.isPlainValue(type),
            isSelf || !ForeignCall.isMetatype(type)
        else {
            throw SILError.unsupported("an Objective-C call that takes a \(text): foreign code could call back through it or change it")
        }
    }
}

// MARK: - calls

/// What logic knows of a call into foreign code: its label in reports, and the shape of the values it takes and gives.
enum ForeignCall {
    /// Prefix of the function reference an `objc_method` becomes: `foreign:GKTDomainX.count!getter.foreign : Int32`.
    static let prefix = "foreign:"
    /// Between the member reference and its formal result type in such a function reference.
    static let separator = " : "
    /// The approximation recorded for a foreign result outside `Verifier`'s main proof.
    static let approximation = "results of Objective-C calls"
    /// `String._unconditionallyBridgeFromObjectiveC(_:)`: an `NSString?` as a `String` (nil gives ""). A foreign result.
    static let stringFromNSString = "$sSS10FoundationE36_unconditionallyBridgeFromObjectiveCySSSo8NSStringCSgFZ"
    /// `String._bridgeToObjectiveC()`: a `String` as an `NSString`, to pass to foreign code. A foreign result.
    static let nsStringFromString = "$sSS10FoundationE19_bridgeToObjectiveCSo8NSStringCyF"

    /// True for a call `ForeignCall` answers: an Objective-C method or a bridge between `String` and `NSString`.
    static func answers(_ target: String) -> Bool {
        target.hasPrefix(prefix) || target == stringFromNSString || target == nsStringFromString
    }

    /// `@autoreleased Optional<NSString>` -> `Optional<NSString>`.
    static func strippingConventions(_ text: String) -> String {
        var t = text.trimmingCharacters(in: .whitespaces)
        for convention in ["@autoreleased ", "@owned ", "@guaranteed ", "@unowned_inner_pointer ", "@unowned "]
        where t.hasPrefix(convention) {
            t.removeFirst(convention.count)
        }
        return t
    }

    /// A value foreign code can neither call back through nor change: a scalar, a foreign reference, a metatype, or an
    /// Optional of one.
    static func isPlainValue(_ type: ValueType) -> Bool {
        switch type {
        case .scalar: return true
        case .opaque: return type == TypeContext.objectHandle
        case .aggregate(let name, let fields): return fields.isEmpty && name.hasSuffix(".Type")
        case .enumeration(let name, let cases):
            return name.hasPrefix("Optional<") && cases.count == 2 && cases[1].payload.map(isPlainValue) == true
        case .array, .hashed: return false
        }
    }

    /// The (empty) layout of a metatype, `@objc_metatype C.Type` or `@thick T.Type`.
    static func isMetatype(_ type: ValueType) -> Bool {
        if case .aggregate(let name, let fields) = type { return fields.isEmpty && name.hasSuffix(".Type") }
        return false
    }

    /// A receiver an Objective-C method can be sent to: a reference, or the metatype of a class (a class property).
    static func isReceiver(_ type: ValueType) -> Bool {
        if type == TypeContext.objectHandle { return true }
        if case .aggregate(let name, let fields) = type { return fields.isEmpty && name.hasPrefix("@objc_metatype ") }
        return false
    }

    /// The Swift result type of a call `answers`, as declared (`Int32`, `String?`).
    static func resultText(_ target: String) -> String {
        if target == stringFromNSString { return "String" }
        if target == nsStringFromString { return "NSString" }
        return target.range(of: separator).map { String(target[$0.upperBound...]) } ?? ""
    }

    /// `count`, `score(…)` for the reference `foreign:GKTDomainX.count!getter.foreign : Int32`.
    static func memberLabel(_ target: String) -> String {
        if target == stringFromNSString { return "as String" }
        if target == nsStringFromString { return "as NSString" }
        let reference = target.dropFirst(prefix.count).prefix { $0 != " " }
        guard let dot = reference.firstIndex(of: "."), let bang = reference[dot...].firstIndex(of: "!") else { return String(reference) }
        let member = String(reference[reference.index(after: dot)..<bang])
        return reference[bang...].hasPrefix("!getter") || reference[bang...].hasPrefix("!setter") ? member : member + "(…)"
    }

    /// What a report says the call `target` was trusted with (`Assumptions`).
    static func assumption(_ target: String, _ type: ValueType) -> String {
        if target == stringFromNSString { return "an NSString read as a String may be any String" }
        if target == nsStringFromString { return "a String passed to Objective-C as an NSString is assumed not to trap" }
        let result = Assumptions.typeText(resultText(target))
        let returns = type == .aggregate(name: "", fields: []) || result.isEmpty ? "returns" : "may return any \(result)"
        return "`\(owner(target)).\(memberLabel(target))` (Objective-C) \(returns) and is assumed not to trap"
    }

    /// The owner class or protocol of `foreign:GKTDomainX.count!getter.foreign`.
    static func owner(_ target: String) -> String {
        String(target.dropFirst(prefix.count).prefix { $0 != "." })
    }
}

/// The foreign results of one claim, for `Verifier`: recorded while proving, supplied while reading back what the
/// foreign calls returned. Bound with `ForeignResults.$current` around the encodings it concerns; one thread each.
package final class ForeignResults: @unchecked Sendable {
    /// One foreign result: where it was made, what it is, and its leaves in the encoding that made it.
    package struct Result {
        /// `<scanned or spec symbol>#<n>`: the n-th foreign result of an encoding of that symbol.
        package let key: String
        /// `input.count`, `GKTKind.driver`: who was asked.
        package let label: String
        /// The Swift type of the result, as SIL prints it (`Int32`, `Optional<NSString>`, `String`).
        package let typeText: String
        package let type: ValueType
        package let leaves: [BV]
        /// When the call is reached in that encoding.
        package let reached: Int32
    }

    @TaskLocal package static var current: ForeignResults?

    /// The values to use for each key (`Verifier`'s read-back and replay); empty while recording.
    let supplied: [String: [BV]]
    /// Whether results get labels (`input.count`): only a replay that reports them needs them.
    package let wantsLabels: Bool
    package private(set) var made: [Result] = []

    package init(supplying supplied: [String: [BV]] = [:], labels: Bool = false) {
        self.supplied = supplied
        self.wantsLabels = labels
    }

    /// The results of one encoding, in order, without the ones an earlier encoding of the same claim already made.
    package var distinct: [Result] {
        var seen: Set<String> = []
        return made.filter { seen.insert($0.key).inserted }
    }

    func record(_ result: Result) { made.append(result) }
}

extension SILEncoder {
    /// The result of the call `target` (an Objective-C method, `self` last, or a String bridge) on `operands`, as
    /// `foreignResult` makes it. Throws when the receiver is not a foreign reference.
    func foreignCall(
        _ target: String, _ type: ValueType, _ operands: [(name: String, type: ValueType?)], reached: Int32, in function: String
    )
        throws -> (leaves: [BV], approximate: Bool)
    {
        let isMethod = target.hasPrefix(ForeignCall.prefix)
        guard let receiver = isMethod ? operands.last : operands.first, let receiverType = receiver.type,
            !isMethod || ForeignCall.isReceiver(receiverType)
        else {
            throw SILError.unsupported("an Objective-C call on a value Scan does not read as an object (\(target))")
        }
        foreignCount.made += 1
        return foreignResult(
            target, type, key: "\(foreignCount.root)#\(foreignCount.made)",
            label: { self.foreignLabel(target, receiver: receiver.name, in: function) }, reached: reached)
    }

    /// The leaves of a foreign result of `type` at `key`, and whether it counts as an approximation (outside
    /// `Verifier`'s main proof, or a key the read-back did not supply). Supplied leaves are assumed valid values.
    func foreignResult(_ target: String, _ type: ValueType, typeText: String? = nil, key: String, label: () -> String, reached: Int32)
        -> (leaves: [BV], approximate: Bool)
    {
        guard let results = ForeignResults.current else { return (fresh(type), true) }
        var leaves = fresh(type)
        var approximate = !results.supplied.isEmpty
        if let given = results.supplied[key], given.map(\.width) == type.leafWidths {
            leaves = given
            approximate = false
            let valid = type.validity(c, leaves[...])
            assumption = c.and(assumption ?? c.trueLit, valid)
        }
        results.record(
            ForeignResults.Result(
                key: key, label: results.wantsLabels ? label() : "", typeText: typeText ?? ForeignCall.resultText(target), type: type,
                leaves: leaves,
                reached: reached))
        return (leaves, approximate)
    }

    /// Who a foreign call in `function` asks, from the names the debug info gives its values: `input.count`,
    /// `self.parent.count` (written `parent.count`), or the owner's name when the receiver has none.
    func foreignLabel(_ target: String, receiver: String?, in function: String) -> String {
        let member = ForeignCall.memberLabel(target)
        let names = ForeignNames.names(in: module.bodyLines(of: function) ?? [])
        if target == ForeignCall.stringFromNSString || target == ForeignCall.nsStringFromString {
            return receiver.flatMap { names[$0] } ?? member
        }
        let base = receiver.flatMap { names[$0] } ?? ForeignCall.owner(target)
        return base + "." + member
    }
}

/// Dotted names of the values of a function body, from `debug_value` names, field extractions and foreign getters.
enum ForeignNames {
    static func names(in body: [String]) -> [String: String] {
        var names: [String: String] = [:]
        var methods: [String: (receiver: String, member: String)] = [:]
        func join(_ base: String?, _ member: String) -> String? {
            guard let base else { return nil }
            return base == "self" ? member : base + "." + member
        }
        for raw in body {
            let line = stripComment(raw).trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("debug_value "), let name = line.range(of: ", name \"") {
                let value = String(line.dropFirst("debug_value ".count).prefix { $0 != "," })
                let text = line[name.upperBound...].prefix { $0 != "\"" }
                if isValue(value), names[value] == nil { names[value] = String(text) }
                continue
            }
            guard let eq = line.range(of: " = ") else { continue }
            let result = String(line[..<eq.lowerBound])
            let rhs = line[eq.upperBound...]
            let parts = splitTopLevel(String(rhs.drop { $0 != " " }))
            let operand = parts.first.map { String($0.prefix { $0 != " " }) } ?? ""
            if rhs.hasPrefix("struct_extract "), parts.count == 2, let dot = parts[1].lastIndex(of: ".") {
                names[result] = join(names[operand], String(parts[1][parts[1].index(after: dot)...]))
            } else if rhs.hasPrefix("objc_method "), let hash = line.range(of: ", #"),
                let dot = line[hash.upperBound...].firstIndex(of: "."),
                let bang = line[dot...].firstIndex(of: "!")
            {
                methods[result] = (operand, String(line[line.index(after: dot)..<bang]))
            } else if rhs.hasPrefix("apply "), let method = methods[String(rhs.dropFirst("apply ".count).prefix { $0 != "(" && $0 != "<" })]
            {
                names[result] = join(names[method.receiver], method.member)
            } else if rhs.hasPrefix("enum "), parts.count == 3 {
                names[result] = names[parts[2]]
            } else if ["open_existential_ref ", "upcast ", "init_existential_ref ", "begin_borrow ", "copy_value "].contains(where: {
                rhs.hasPrefix($0)
            }) {
                names[result] = names[operand]
            }
        }
        return names
    }
}
