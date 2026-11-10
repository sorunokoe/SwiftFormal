import Foundation
import SFBV
import SFCNF

// Reading guide
// Calls with no body (`SILBinaryTypes.swift` says which modules have none): what a scan may assume about them, and the
// list of those assumptions a report shows (`Assumptions`).
//
// With `OpaqueCallMode.all` (Verifier's default), a call into a binary module, `init(truncating:)` of an `NSNumber`,
// and `==` of two Objective-C objects each return a fresh value of their result type: any value, a new one at each
// call (no purity is assumed). That only widens what a proof covers. What it does assume is that the call does not
// trap and changes nothing Scan reads: the arguments must be plain data or Objective-C objects, so that the callee
// cannot call back into the scanned code. Each such call is an assumption the report names.
//
// `derived_enum_equals` of a binary enum without payloads is exact: the same case, or (an open enum's unknown case on
// both sides) either answer.
// Part of `FunctionRun` (`SILFunctionRun.swift`).

/// The assumptions of one function's verdict, for its report: bound with `Assumptions.$current` around the encodings
/// of one function. Every encoding records what it took on trust; reading them back is for the report only.
package final class Assumptions: @unchecked Sendable {
    @TaskLocal package static var current: Assumptions?

    /// `@autoreleased Optional<X>` -> `Optional<X>`: a result type as SIL prints it, without its ownership convention.
    static func typeText(_ sil: String) -> String { sil.replacing(#/@[a-z_]+ /#, with: "") }

    private let lock = NSLock()
    private var texts: Set<String> = []

    package init() {}

    package func record(_ text: String) {
        lock.lock()
        defer { lock.unlock() }
        texts.insert(text)
    }

    /// Sorted.
    package var all: [String] {
        lock.lock()
        defer { lock.unlock() }
        return texts.sorted()
    }

    static func note(_ text: @autoclosure () -> String) { current?.record(text()) }
}

extension OpaqueCallMode {
    /// The note a refusal gets in strict mode.
    static let strictNote = "(--no-opaque-calls: a call with no body is not assumed to return any value without trapping)"
}

/// `==` and `!=` of `NSObject`: the Objective-C object's `isEqual:`.
enum ObjectiveCEquality {
    static let equal = "$sSo8NSObjectC10ObjectiveCE2eeoiySbAB_ABtFZ"
    static let notEqual = "$sSo8NSObjectC10ObjectiveCE2neoiySbAB_ABtFZ"
    static let refusal =
        "== on Objective-C objects calls their isEqual: (Kotlin enums, sealed and data classes), which Scan does not read yet"
    static let assumption = "`==` on Objective-C objects (isEqual:) may give either answer"
}

extension FunctionRun {
    /// Encodes `request` when `target` is a call with no body this file reads; false when it is not one.
    func encodeOpaqueCall(_ target: String, _ request: SummarizedCall) throws -> Bool {
        if target == ObjectiveCEquality.equal || target == ObjectiveCEquality.notEqual {
            guard module.opaqueCalls == .all else {
                throw SILError.unsupported(
                    ObjectiveCEquality.refusal + (module.opaqueCalls == .none ? " " + OpaqueCallMode.strictNote : ""))
            }
            let objects = try request.names.filter { name in try valueType(lookup(name)) == TypeContext.objectHandle }
            guard objects.count == 2, request.type == .scalar(1) else {
                throw SILError.unsupported("== on Objective-C objects of an unexpected shape (\(target))")
            }
            try freeResult(target, request, typeText: "Bool", label: "==")
            Assumptions.note(ObjectiveCEquality.assumption)
            return true
        }
        guard let declaration = module.externalDeclaration(of: target) else { return false }
        if module.semanticsTags(of: target).contains("derived_enum_equals"), try derivedEnumEquals(target, request) { return true }
        guard let call = module.binary.calls[target] else { return false }
        let origin = module.binary.origin(of: call.module)
        guard module.opaqueCalls == .all else {
            guard module.opaqueCalls == .none else { return false }
            throw SILError.unsupported("`\(call.label)` has \(origin.describe(call.module)) \(OpaqueCallMode.strictNote)")
        }
        let signature = try opaqueSignature(declaration, substitutions: request.substitutions, label: call.label, request: request)
        guard !request.conventions.contains(where: { $0 == .out || $0 == .inout }) else {
            throw SILError.unsupported("`\(call.label)` (\(origin.place(call.module))) returns through memory: not read")
        }
        if try !localizeOpaqueCall(request, label: call.label, result: signature.result) {
            try freeResult(target, request, typeText: signature.result, label: call.label)
        }
        Assumptions.note(Self.assumption(call, origin: origin, result: signature.result, type: request.type))
        return true
    }

    /// The text of the assumption an opaque call makes.
    static func assumption(_ call: BinaryTypes.Call, origin: ModuleOrigin, result: String, type: ValueType) -> String {
        let returns: String
        if case .enumeration(let name, _) = type, !name.hasPrefix("Optional<") {
            returns = "may return any case of \(Assumptions.typeText(result))"
        } else if type == .aggregate(name: "", fields: []) {
            returns = "returns"
        } else {
            returns = "may return any \(Assumptions.typeText(result))"
        }
        return "`\(call.label)` \(returns) and is assumed not to trap (\(origin.describe(call.module)))"
    }

    /// A fresh value of the call's result type, as a foreign result (`SILEncoder.foreignResult`): a counterexample shows
    /// what it returned (`onEnum(of:) returned .drive(…)`).
    private func freeResult(_ target: String, _ request: SummarizedCall, typeText: String, label: String) throws {
        encoder.foreignCount.made += 1
        let made = encoder.foreignResult(
            target, request.type, typeText: typeText, key: "\(encoder.foreignCount.root)#\(encoder.foreignCount.made)", label: { label },
            reached: live)
        if made.approximate { out.approximations.insert(ForeignCall.approximation) }
        env[request.id] = make(request.type, made.leaves)
    }

    /// `==` of two values of a binary enum whose cases have no payload: the same case. Two values of an open enum's
    /// unknown case may be different cases of a later version: either answer. False when the operands are not such.
    private func derivedEnumEquals(_ target: String, _ request: SummarizedCall) throws -> Bool {
        let operands = try request.names.compactMap { name -> (type: ValueType, leaves: [BV])? in
            guard let type = valueType(try lookup(name)), case .enumeration(let enumName, let cases) = type,
                module.types.binary.enums[enumName] != nil, cases.allSatisfy({ $0.payload == nil })
            else { return nil }
            return (type, try flat(name))
        }
        guard operands.count == 2, operands[0].type == operands[1].type, request.type == .scalar(1),
            case .enumeration(let name, let cases) = operands[0].type
        else { return false }
        let (a, b) = (operands[0].leaves[0], operands[1].leaves[0])
        var same = c.eq(a, b)
        if module.types.binary.enums[name]?.isOpen == true {
            let unknown = c.eq(a, c.constant(UInt64(cases.count - 1), width: a.width))
            same = c.mux(unknown, c.and(same, c.input(width: 1).bits[0]), same)
        }
        env[request.id] = .scalar(BV(bits: [same]))
        return true
    }

    /// The result type of an opaque call (`Int32`, `Skie.Shot.__Sealed`), after checking that every parameter is plain
    /// data or an Objective-C object: nothing the callee could call back through or change.
    private func opaqueSignature(_ declaration: String, substitutions: [String], label: String, request: SummarizedCall) throws -> (
        parameters: [String], result: String
    ) {
        guard let colon = declaration.range(of: " : $") else { throw SILError.unsupported("call to `\(label)`: \(declaration)") }
        var signature = Substring(declaration[colon.upperBound...])
        while signature.hasPrefix("@") {
            guard let space = signature.firstIndex(of: " ") else { break }
            if signature.hasPrefix("@convention("), let close = signature.firstIndex(of: ")") {
                signature = signature[signature.index(after: close)...].drop { $0 == " " }
            } else {
                signature = signature[signature.index(after: space)...]
            }
        }
        var generic: [String] = []
        if signature.hasPrefix("<"), let end = matchingClose(signature, open: "<", close: ">") {
            let parameters = String(signature[signature.index(after: signature.startIndex)..<end])
            generic = splitTopLevel(parameters.components(separatedBy: " where ")[0]).map { $0.trimmingCharacters(in: .whitespaces) }
            signature = signature[signature.index(after: end)...].drop { $0 == " " }
        }
        guard generic.count == substitutions.count else { throw SILError.unsupported("call to `\(label)`: generic \(declaration)") }
        for substitution in substitutions where !module.types.isForeignObject(substitution) {
            throw SILError.unsupported("call to `\(label)` with \(substitution): only Objective-C objects may stand for its generic types")
        }
        func substituted(_ text: String) -> String {
            var t = ForeignCall.strippingConventions(text)
            for (parameter, substitution) in zip(generic, substitutions) where t == parameter { t = substitution }
            return t
        }
        guard signature.hasPrefix("("), let end = matchingClose(signature, open: "(", close: ")"),
            signature[signature.index(after: end)...].hasPrefix(" -> ")
        else { throw SILError.unsupported("call to `\(label)`: \(declaration)") }
        let parameters = splitTopLevel(String(signature[signature.index(after: signature.startIndex)..<end])).map(substituted)
        let result = substituted(String(signature[signature.index(end, offsetBy: 5)...]))
        try checkInert(parameters, request, label: label)
        guard !result.contains("τ_"), !result.hasPrefix("@error") else {
            throw SILError.unsupported("call to `\(label)` that returns a \(result)")
        }
        return (parameters, result)
    }

    /// Throws unless every parameter is inert, or a literal of format arguments (`isFormatArgumentLiteral`).
    private func checkInert(_ parameters: [String], _ request: SummarizedCall, label: String) throws {
        // The arguments line up with the parameters from the end (indirect results come first).
        let offset = request.names.count - parameters.count
        for (k, parameter) in parameters.enumerated() where !isInert(parameter) {
            if offset >= 0, isFormatArgumentLiteral(parameter, request.names[offset + k]) { continue }
            throw SILError.unsupported(
                "call to `\(label)` with a \(parameter): the callee, which has no body, could call back through it or change it")
        }
    }

    /// Plain data or an Objective-C object: a value a callee can neither call back through nor change.
    private func isInert(_ text: String) -> Bool {
        if text.hasPrefix("@thick ") || text.hasPrefix("@thin ") || text.hasPrefix("@objc_metatype "), text.hasSuffix(".Type") {
            let instance = String(text.drop { $0 != " " }.dropFirst().dropLast(".Type".count))
            return module.types.binary.enums[instance] != nil || module.types.isForeignObject(instance)
                || (try? module.types.resolve(instance)).map(Self.isPlainData) == true
        }
        for refused in ["->", "τ_", "any ", "@inout", "@block", "@callee", "Builtin."] where text.contains(refused) { return false }
        if text.contains(/\bAny(Object|Hashable)?\b/) { return false }
        guard module.types.packageType(text) == nil, let type = try? module.types.resolve(text) else { return false }
        if Self.isPlainData(type) { return true }
        var wrapped = text
        while let inner = optionalWrappedText(wrapped) { wrapped = inner }
        return module.types.isForeignObject(wrapped)
    }

    /// Scalars, Strings and other opaque values, and structs, tuples and enums of them: no reference to anything.
    private static func isPlainData(_ type: ValueType) -> Bool {
        switch type {
        case .scalar: return true
        case .opaque(let name): return ["String", "Substring", "Character"].contains(name)
        case .aggregate(_, let fields): return fields.allSatisfy { isPlainData($0.type) }
        case .enumeration(_, let cases): return cases.allSatisfy { $0.payload.map(isPlainData) ?? true }
        case .array, .hashed: return false
        }
    }

    private func optionalWrappedText(_ text: String) -> String? {
        if text.hasPrefix("Optional<"), text.hasSuffix(">") { return String(text.dropFirst("Optional<".count).dropLast()) }
        if text.hasSuffix("?") { return String(text.dropLast()) }
        return nil
    }
}
