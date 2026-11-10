package import SFBV

/// A summarized call as the summaries outside `SILEncoder.swift` see it (`SILDictionaries.swift`, `SILStrings.swift`):
/// its operands, and what the encoder can do at that point of the block. The encoder builds one per call
/// (`SILEncoder.run`), so the summaries need none of its block state.
struct SummaryCall {
    /// How reports name the call, for example `Dictionary.subscript`.
    let name: String
    let request: SummarizedCall
    /// The symbol of the function the call is in.
    let function: String
    /// The leaves of the value named `name` passed with `convention` (read from its stack slot when it is an address).
    let read: (_ name: String, _ convention: ParameterConvention) throws -> [BV]
    /// The type stored in the stack slot `name`.
    let slotType: (_ name: String) throws -> ValueType
    /// Stores `leaves` into the stack slot `name` (an `@out` or `@inout` argument).
    let write: (_ name: String, _ leaves: [BV]) throws -> Void
    /// The leaves of the SSA value `name`, nil when it has none in this function (yet).
    let value: (_ name: String) -> [BV]?
    /// Records a trap of the standard library at this call, under `condition`; execution stops there.
    let trap: (_ condition: Int32, _ message: String) -> Void
    /// Runs what hashing a `type` value runs (its own `hash(into:)` for a type of the read modules), when `condition`.
    /// A nil value is an unknown one.
    let hash: (_ type: String, _ value: [BV]?, _ condition: Int32) throws -> Void
    /// Runs what comparing two unknown `type` values with `==` runs, when `condition` and an unknown choice hold.
    let equate: (_ type: String, _ condition: Int32) throws -> Void
    /// Calls `symbol` of the read modules with `arguments`; its traps count only when `condition` holds.
    let call: (_ symbol: String, _ arguments: [BV], _ condition: Int32) throws -> EncodedFunction
    /// Records that a result of this call is unknown (see `EncodedFunction.approximations`).
    let approximate: (_ name: String) -> Void

    /// Argument `k`: its SSA name and convention (the `@out` address first, when there is one).
    func argument(_ k: Int) throws -> (name: String, convention: ParameterConvention) {
        guard request.names.indices.contains(k), request.conventions.indices.contains(k) else {
            throw SILError.invalid("\(name) without argument \(k) at \(request.id)")
        }
        return (request.names[k], request.conventions[k])
    }

    /// The leaves of argument `k`.
    func leaves(_ k: Int) throws -> [BV] {
        let a = try argument(k)
        guard a.convention != .out else { throw SILError.invalid("\(name): argument \(k) is a result address at \(request.id)") }
        return try read(a.name, a.convention)
    }

    /// The single 64-bit leaf of argument `k` (an `Int`, a word, or the count of a collection).
    func word(_ k: Int) throws -> BV {
        let l = try leaves(k)
        guard l.count == 1, l[0].width == 64 else { throw SILError.invalid("\(name): argument \(k) is not one word at \(request.id)") }
        return l[0]
    }

    /// Writes `leaves` into argument `k`, which must be `@out` or `@inout`.
    func set(_ k: Int, _ leaves: [BV]) throws {
        let a = try argument(k)
        guard a.convention == .out || a.convention == .inout else {
            throw SILError.invalid("\(name): argument \(k) is not written at \(request.id)")
        }
        try write(a.name, leaves)
    }

    /// The type of the `@out` or `@inout` argument `k`.
    func writtenType(_ k: Int) throws -> ValueType { try slotType(try argument(k).name) }
}
