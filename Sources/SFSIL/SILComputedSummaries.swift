import Foundation
import SFBV
import SFCNF

/// A standard-library call whose effect logic computes exactly from its operands, instead of leaving results unknown:
/// the comparisons of a standard integer type reached through a generic body (plan item L7). The encoder hands over the
/// operands and records what comes back (`SILEncoder`'s `applyComputed`); the meaning is all here.
package enum ComputedSummary: Sendable, Hashable {
    /// `Equatable.==` or a `Comparable` operator of a standard integer type (`IntegerWitness`).
    case integerWitness(IntegerWitness.Operands)
    /// A call of `for-in` iteration (plan item L4, `SILIterators.swift`).
    case iterator(IteratorOperation)
    /// A floating-point call (plan item R6-3, `SILFloatSummaries.swift`).
    case float(FloatSummary)
    /// `===` of two objects (plan item R6-1, `SILForeign.swift`).
    case objectIdentity
    /// A call on a Foundation or SwiftUI value held as an opaque handle (`SILOpaqueValues.swift`).
    case opaqueValue(OpaqueValues.Call)
}

/// The operands of a computed call, as the encoder reads them.
struct ComputedCall {
    /// How reports name the call.
    let name: String
    /// One entry per argument, in order: the leaves of a value, or of what an `@in`/`@inout` address holds; empty for
    /// the `@out` result address.
    let inputs: [[BV]]
    let conventions: [ParameterConvention]
    let substitutions: [String]
    /// The types of the `@out` and `@inout` arguments, in order: what `ComputedEffect.writtenBack` must lay out.
    let writtenTypes: [ValueType]
    /// The type of the direct result.
    let resultType: ValueType
}

/// What a computed call does.
struct ComputedEffect {
    /// Each condition under which the call traps, with the standard library's message.
    var traps: [(condition: Int32, message: String)] = []
    /// The direct result's leaves.
    var result: [BV] = []
    /// The new values of the `@out` and `@inout` arguments, laid out as `ComputedCall.writtenTypes`.
    var writtenBack: [BV] = []
    /// What the effect leaves unknown (see `EncodedFunction.approximations`), such as array elements.
    var approximations: Set<String> = []
}

extension ComputedSummary {
    func encode(_ call: ComputedCall, in c: CNFBuilder, module: SILModule, fresh: @escaping (ValueType) -> [BV]) throws
        -> ComputedEffect
    {
        switch self {
        case .objectIdentity:
            return try ObjectIdentity.encode(call, in: c)
        case .iterator(let operation):
            return try operation.encode(call, in: c, module: module, fresh: fresh)
        case .float(let summary):
            return try summary.encode(call, in: c)
        case .opaqueValue(let value):
            return try encodeOpaqueValue(value, call, in: c, fresh: fresh)
        case .integerWitness(let comparison):
            let (kind, signed, width) = (comparison.kind, comparison.signed, comparison.width)
            let operands = zip(call.inputs, call.conventions).filter { $1 != .out }.map(\.0).filter { !$0.isEmpty }
            guard operands.count == 2, operands.allSatisfy({ $0.map(\.width) == [width] }), call.resultType.leafWidths == [1],
                call.writtenTypes.isEmpty
            else { throw SILError.invalid("\(call.name): operands of unexpected shape") }
            let holds = IntegerWitness.encode(kind, signed: signed, operands[0][0], operands[1][0], in: c)
            return ComputedEffect(result: [BV(bits: [holds])])
        }
    }
}

extension StdlibSummary.Entry {
    /// The summary of a witness `IntegerWitness` resolved, nil for any other symbol.
    static func integerWitness(_ symbol: String) -> Self? {
        guard let comparison = IntegerWitness.comparison(symbol) else { return nil }
        return Self(
            name: symbol.dropFirst("witness:".count).replacingOccurrences(of: ":#", with: ": "),
            summary: .computed(.integerWitness(comparison)), isGeneric: false)
    }
}
