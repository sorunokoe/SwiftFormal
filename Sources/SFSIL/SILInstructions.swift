// The closed set of instructions and terminators the reader produces, and `SILFunction` (plan item H1). Every
// instruction the encoder sees is one of `Instruction`'s cases; there is no default case anywhere it is matched.

import Foundation
package import SFSemantics

/// A constant, immutable array literal that the optimizer placed in a `sil_global [let]`.
struct GlobalTable: Sendable {
    let elementWidth: Int
    let values: [UInt64]
}

struct Edge {
    let block: String
    let arguments: [String]
}

struct BlockParameter {
    let id: String
    let type: ValueType
    /// `%0 : $*T`: the address of a `T` (an `@inout` or `@in_guaranteed` parameter of the entry block).
    var isAddress = false
}

/// How a function receives one parameter.
package enum ParameterConvention: Sendable, Equatable {
    /// By value (`@owned`, `@guaranteed` or trivial).
    case value
    /// `@inout`: an address the callee may read and write; the final value goes back to the caller.
    case `inout`
    /// `@in_guaranteed` / `@in`: an address the callee only reads.
    case indirect
    /// The address an `@out` result is written to (only as the first argument of an `apply`).
    case out
}

enum Instruction {
    case literal(result: String, width: Int, value: UInt64)
    /// `struct $Int32 (%x)` and `struct_extract %x, #Int32._value`: same bits, different type.
    case retype(result: String, source: String, width: Int)
    case builtin(result: String, op: S0Instance, arguments: [String])
    /// A floating-point builtin (`fadd_FPIEEE64`, `fcmp_olt_FPIEEE64`, ...), see `S0FloatInstance`.
    case floatBuiltin(result: String, op: S0FloatInstance, arguments: [String])
    /// `struct $P (...)` and `tuple (...)`.
    case makeAggregate(result: String, type: ValueType?, operands: [String])
    /// `struct_extract` and `tuple_extract` of field `field`.
    case extract(result: String, source: String, field: Int, expected: FieldOwner)
    case condFail(String)
    case functionRef(result: String, symbol: String)
    case apply(
        result: String, callee: String, arguments: [String], type: ValueType, substitutions: [String],
        conventions: [ParameterConvention])
    case allocStack(result: String, type: ValueType)
    /// `alloc_ref` of an eligible class (plan item L5): a new object, its fields unknown until initialized.
    case allocObject(result: String, type: ValueType)
    case store(value: String, address: String)
    case load(result: String, address: String)
    /// `struct_element_addr` / `tuple_element_addr`.
    case elementAddress(result: String, base: String, field: Int, expected: FieldOwner)
    /// `begin_access [static]`, `upcast`, `end_cow_mutation`, `begin_dealloc_ref`: same object, same address.
    case alias(result: String, source: String)
    /// `(%flag, %buffer) = begin_cow_mutation [native] %source`.
    case beginCOW(flag: String, buffer: String, source: String)
    case allocArray(result: String, width: Int, count: String)
    case globalValue(result: String, symbol: String)
    /// `ref_tail_addr`: `width` is nil for elements that are not scalars (only an array under construction has them).
    case refTailAddress(result: String, source: String, width: Int?)
    /// `struct_extract` along `Array._buffer`, `_ArrayBuffer._storage`, `_BridgeStorage.rawValue`: the element storage
    /// of an array. Elements are not modelled: stores into it are dropped, loads from it are rejected.
    case arrayStorage(result: String, source: String)
    /// `(%address, %token) = begin_apply %f<T>(...)`: a coroutine that yields an address (`Array.subscript.modify`).
    case beginApply(
        address: String, callee: String, arguments: [String], substitutions: [String], conventions: [ParameterConvention])
    case indexAddress(result: String, base: String, index: String)
    /// Address of the array header (`countAndCapacity`); only stores of header plumbing are accepted.
    case headerAddress(result: String)
    /// `alloc_existential_box $any Error, $E`: an error box holding an `E` (plan item L6). The box is an existential
    /// handle; what is stored in it is not read.
    case existentialBox(result: String, payload: String)
    /// `project_existential_box $E in %box`: the address of the boxed value; stores to it are dropped.
    case boxedValueAddress(result: String)
    /// `init_existential_addr %base, $T`: the address of the `T` value inside the existential at `%base`. Only the
    /// elements of an array literal of `any CVarArg` are read (`SILFormat.swift`); stores to it are dropped.
    case existentialAddress(result: String, base: String, payload: String)
    /// `enum $E, #E.c!enumelt[, %payload]`.
    case makeEnum(result: String, type: ValueType, caseName: String, payload: String?)
    /// `unchecked_enum_data %e, #E.c!enumelt`: the payload of case `c`; undefined if `%e` is in another case.
    case enumPayload(result: String, source: String, caseName: String)
    /// `select_enum[_addr] %e, case #E.a!enumelt: %v, ..., default %w : $T`.
    case selectEnum(result: String, source: String, isAddress: Bool, cases: [EnumTarget], default: String?)
    /// `init_enum_data_addr` (`checksCase` false), `unchecked_take_enum_data_addr` and
    /// `unchecked_inplace_enum_data_addr` (`checksCase` true: undefined unless the enum is in case `c`).
    case enumPayloadAddress(result: String, base: String, caseName: String, checksCase: Bool)
    /// `inject_enum_addr %a, #E.c!enumelt`: makes the enum at `%a` case `c` (its payload was stored before).
    case injectEnum(address: String, caseName: String)
    /// `copy_addr [take] %source to [init] %destination`.
    case copyAddress(source: String, destination: String)
    /// `string_literal utf8 "…"`: the decoded text, nil for another encoding or an unknown escape. The value is a
    /// pointer that only `String(_builtinStringLiteral:…)` may read; any other use is rejected as before.
    case stringLiteral(result: String, text: String?)
    /// `builtin "getEnumTag"<E>(%e)`: the case index of the enum at `%e` (an address or a value), as `Builtin.Int32`.
    case enumTag(result: String, operand: String)
    /// `thin_to_thick_function %f to …` and `partial_apply … %f(%captures…)`: a closure handle; the callee and the
    /// captures are kept for `Optional.map` (`SILOptionalMap.swift`) and read nowhere else.
    case closure(result: String, type: ValueType, callee: String, captures: [String])
    /// `global_addr @G : $*T`: the address of the global `G`, read only inside its initializer (`SILGlobals.swift`).
    case globalAddress(result: String, symbol: String, type: ValueType)
    /// `pointer_to_address %p to [strict] $*T`: only of the address a `let` global's addressor returned.
    case pointerToAddress(result: String, source: String, type: ValueType)
    case ignored
}

/// One `case #E.c!enumelt: target` of a `switch_enum` (target is a block) or `select_enum` (target is a value).
struct EnumTarget {
    let caseName: String
    let target: String
}

enum Terminator {
    case branch(Edge)
    case conditional(String, Edge, Edge)
    case returned(String)
    /// A block that ends in `unreachable` after calling a standard-library failure function.
    case trap
    /// `switch_enum[_addr] %e, case #E.a!enumelt: bb1, ..., default bbN`. A payload case passes its payload to a
    /// target block that takes one parameter.
    case switchEnum(subject: String, isAddress: Bool, cases: [EnumTarget], default: String?)
    /// `throw %e`: the function exits with an error (plan item L6).
    case thrown(String)
    /// `try_apply %f(...) : $T, normal bbN, error bbM`: a call to a throwing function; the normal block gets the
    /// result, the error block the error.
    case tryApply(TryApply)

    /// Successor block names, in order (a block may appear more than once).
    var successorBlocks: [String] {
        switch self {
        case .branch(let e): [e.block]
        case .conditional(_, let y, let n): [y.block, n.block]
        case .switchEnum(_, _, let cases, let fallback): cases.map(\.target) + (fallback.map { [$0] } ?? [])
        case .tryApply(let call): [call.normal, call.error]
        case .returned, .trap, .thrown: []
        }
    }
}

/// The call of a `try_apply` terminator.
struct TryApply {
    let callee: String
    let arguments: [String]
    let substitutions: [String]
    let conventions: [ParameterConvention]
    let normal: String
    let error: String
}

struct Block {
    let id: String
    let parameters: [BlockParameter]
    let instructions: [Instruction]
    let terminator: Terminator
}

package struct SILFunction {
    package let symbol: String
    /// One entry per scalar leaf of the parameters, in declaration order (structs and tuples are flattened).
    package let parameterWidths: [Int]
    /// Total result width in bits: the scalar's width, or the sum over all leaves of a struct/tuple result.
    package let resultWidth: Int
    /// One entry per scalar leaf of the result; leaf 0 occupies the low bits of the concatenated `result`.
    package let resultWidths: [Int]
    /// The type of each parameter, the `@out` result address excluded.
    package let parameterTypes: [ValueType]
    /// The direct result type; `()` when the result is returned through `indirectResult`.
    package let resultType: ValueType
    /// One entry per parameter. Address parameters are flattened like values; `@inout` ones also come back.
    package var conventions: [ParameterConvention] = []
    /// The type of an `@out` result: the function writes it through an extra first entry-block address and
    /// returns `()`. It comes back first in `EncodedFunction.writtenBack`.
    package var indirectResult: ValueType?
    /// What the function throws, when it can throw (`throw`, plan item L6).
    package var errorType: ValueType?
    /// The index of the class parameter, passed like `inout` (plan item L5, `SILClasses.swift`).
    package var objectParameter: Int?
    /// Whether the result is a reference to an object (plan item L5).
    package var returnsObject = false
    /// What reading the function's types took on trust (`DeinitAssumption`); noted each time it is run.
    package var assumptions: [String] = []
    let blocks: [Block]

    /// Widths of what the function writes back through addresses: the `@out` result, then each `@inout` parameter.
    package var writtenBackWidths: [Int] {
        (indirectResult?.leafWidths ?? []) + zip(parameterTypes, conventions).flatMap { $1 == .inout ? $0.leafWidths : [] }
    }
}
