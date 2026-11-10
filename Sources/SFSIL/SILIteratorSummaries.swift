import Foundation
import SFBV
import SFCNF

// The summaries of `for-in` iteration (plan item L4); the types they work on are in `SILIterators.swift`.

// MARK: - summaries

extension IteratorOperation {
    /// The standard-library type names the summaries take for granted. A read module that declares one of them could
    /// make `Range<Int>` mean its own type, whose conformance runs its own code: then nothing is summarized.
    static let standardNames = [
        "Array", "Range", "ClosedRange", "IndexingIterator", "StrideTo", "StrideToIterator", "StrideThrough",
        "StrideThroughIterator", "EnumeratedSequence",
    ]

    func encode(_ call: ComputedCall, in c: CNFBuilder, module: SILModule, fresh: @escaping (ValueType) -> [BV]) throws
        -> ComputedEffect
    {
        guard call.substitutions.count == 1, let iterated = Iterated(call.substitutions[0]) else {
            throw SILError.unsupported("\(call.name) on <\(call.substitutions.joined(separator: ", "))>")
        }
        if let name = Self.standardNames.first(where: module.declaresType) {
            throw SILError.unsupported("\(call.name): a read module declares a type named \(name)")
        }
        var model = IteratorModel(call: call, c: c, fresh: fresh)
        let done: Bool
        switch iterated {
        case .range, .closedRange: done = try model.overRange(self, iterated)
        case .array: done = try model.overArray(self)
        case .integer(let type): done = type == "Int" ? try model.overInt(self) : false
        }
        guard done else { throw SILError.unsupported("\(call.name) on <\(call.substitutions[0])>") }
        return model.effect
    }
}

/// The meaning of each `IteratorOperation`, written after the standard library's code. Stated per function: which
/// checks are `_precondition` (kept in the shipped release library, so traps here) and which are `_debugPrecondition`
/// (compiled out of it, so not traps).
private struct IteratorModel {
    let call: ComputedCall
    let c: CNFBuilder
    let fresh: (ValueType) -> [BV]
    var effect = ComputedEffect()
    /// Execution has not trapped yet: later traps are conditioned on it, as in the encoder.
    var live: Int32

    init(call: ComputedCall, c: CNFBuilder, fresh: @escaping (ValueType) -> [BV]) {
        self.call = call
        self.c = c
        self.fresh = fresh
        self.live = c.trueLit
    }

    /// `makeIterator()` or `next()` of a range's `IndexingIterator`; false for any other call over a range.
    mutating func overRange(_ operation: IteratorOperation, _ iterated: Iterated) throws -> Bool {
        switch (operation, iterated) {
        case (.makeIndexingIterator, _): try makeIndexingIterator(iterated)
        case (.indexingNext, .range(let b)): try rangeNext(signed: StdlibSummary.integerKind(b) == .signed)
        case (.indexingNext, .closedRange(let b)): try closedRangeNext(signed: StdlibSummary.integerKind(b) == .signed)
        default: return false
        }
        return true
    }

    /// A call over an `Array<X>`; false for one that is not summarized.
    mutating func overArray(_ operation: IteratorOperation) throws -> Bool {
        switch operation {
        case .makeIndexingIterator: try makeIndexingIterator(.array(element: ""))
        case .indexingNext: try arrayNext()
        case .enumerated: try enumerated()
        case .makeEnumeratedIterator: try makeEnumeratedIterator()
        case .enumeratedNext: try enumeratedNext()
        case .indices: try indices()
        default: return false
        }
        return true
    }

    /// A `stride` call over `Int`; false for any other call.
    mutating func overInt(_ operation: IteratorOperation) throws -> Bool {
        switch operation {
        case .stride: try stride()
        case .makeStrideIterator(let through): try makeStrideIterator(through: through)
        case .strideNext(let through): try strideNext(through: through)
        default: return false
        }
        return true
    }

    mutating func trap(_ condition: Int32, _ message: String) {
        effect.traps.append((c.and(live, condition), message))
        live = c.and(live, -condition)
    }

    func constant(_ value: UInt64, _ width: Int) -> BV { c.constant(value, width: width) }

    /// The leaves of argument `k` (a value, or what an `@in`/`@inout` address holds), checked against `widths`.
    func input(_ k: Int, _ widths: [Int]) throws -> [BV] {
        guard call.inputs.indices.contains(k), call.inputs[k].map(\.width) == widths else {
            throw SILError.invalid("\(call.name): argument \(k) is not \(widths)")
        }
        return call.inputs[k]
    }

    /// The type written back through the `@out` (index 0) or `@inout` (index 1) argument.
    func written(_ k: Int) throws -> ValueType {
        guard call.writtenTypes.indices.contains(k) else { throw SILError.invalid("\(call.name): no written argument \(k)") }
        return call.writtenTypes[k]
    }

    /// Sets the values written back, checked against the written types.
    mutating func write(_ values: [[BV]]) throws {
        guard values.count == call.writtenTypes.count,
            zip(values, call.writtenTypes).allSatisfy({ $0.map(\.width) == $1.leafWidths }), call.resultType.leafWidths.isEmpty
        else { throw SILError.invalid("\(call.name): results of unexpected shape") }
        effect.writtenBack = values.flatMap { $0 }
    }

    /// The leaves of an Optional of `type` that is `.some(payload)` when `isSome`, else `.none` (payload leaves zero).
    func optional(_ type: ValueType, isSome: Int32, payload: [BV]) throws -> [BV] {
        guard case .enumeration(_, let cases) = type, cases.count == 2, cases[0].payload == nil,
            cases[1].payload?.leafWidths == payload.map(\.width)
        else { throw SILError.invalid("\(call.name): result is not an Optional of the element") }
        return [BV(bits: [isSome])] + payload.map { BV(bits: $0.bits.map { c.and($0, isSome) }) }
    }

    func select(_ condition: Int32, _ a: [BV], _ b: [BV]) -> [BV] { zip(a, b).map { c.select(condition, $0, $1) } }

    func less(_ a: BV, _ b: BV, signed: Bool) -> Int32 { signed ? c.slt(a, b) : c.ult(a, b) }

    /// `x.advanced(by: 1)` of a standard integer (`BinaryInteger.advanced(by:)`, `Integers.swift`): checked
    /// arithmetic, so it traps exactly at the type's maximum.
    mutating func successor(_ x: BV, signed: Bool, when condition: Int32) -> BV {
        let maximum = signed ? (UInt64(1) << UInt64(x.width - 1)) - 1 : (x.width == 64 ? ~0 : (UInt64(1) << UInt64(x.width)) - 1)
        trap(c.and(condition, c.eq(x, constant(maximum, x.width))), "arithmetic overflow")
        return c.add(x, constant(1, x.width)).sum
    }

    /// `IndexingIterator(_elements: self)`: `_position = startIndex`, which is `lowerBound` for `Range`,
    /// `.inRange(lowerBound)` for `ClosedRange` and `0` for `Array`. No checks.
    mutating func makeIndexingIterator(_ iterated: Iterated) throws {
        let type = try written(0)
        guard case .aggregate(_, let fields) = type, fields.count == 2 else { throw SILError.invalid("\(call.name): iterator type") }
        let collection = try input(1, fields[0].type.leafWidths)
        let position: [BV]
        switch iterated {
        case .range: position = [collection[0]]
        case .closedRange: position = [BV(bits: [c.trueLit]), collection[0]]
        default: position = [constant(0, 64)]
        }
        try write([collection + position])
    }

    /// `IndexingIterator<Range<B>>.next()` (`Collection.swift`): `nil` at `_position == endIndex`; otherwise the element
    /// is `_elements[_position]`, whose `_debugPrecondition(contains)` is compiled out (`Range.swift`), then
    /// `formIndex(after:)` calls `index(after:)`, which builds `startIndex..<endIndex` (`_precondition(lowerBound <=
    /// upperBound)`), runs `_failEarlyRangeCheck` (`_precondition(lowerBound <= i && i < upperBound)`) and returns
    /// `i.advanced(by: 1)`.
    mutating func rangeNext(signed: Bool) throws {
        let iterator = try written(1)
        let state = try input(1, iterator.leafWidths)
        guard state.count == 3 else { throw SILError.invalid("\(call.name): Range iterator state") }
        let (lower, upper, position) = (state[0], state[1], state[2])
        let more = -c.eq(position, upper)
        trap(c.and(more, less(upper, lower, signed: signed)), "Range requires lowerBound <= upperBound")
        let inBounds = c.and(-less(position, lower, signed: signed), less(position, upper, signed: signed))
        trap(c.and(more, -inBounds), "Index out of bounds")
        let next = successor(position, signed: signed, when: more)
        let element = try optional(try written(0), isSome: more, payload: [position])
        try write([element, [lower, upper, c.select(more, next, position)]])
    }

    /// `IndexingIterator<ClosedRange<B>>.next()`: `nil` at `.pastEnd`; otherwise `subscript(.inRange(x))` is `x`, and
    /// `index(after: .inRange(x))` is `.pastEnd` when `x == upperBound`, else `.inRange(x.advanced(by: 1))`
    /// (`ClosedRange.swift`). The last element never overflows: the end is a separate case.
    mutating func closedRangeNext(signed: Bool) throws {
        let iterator = try written(1)
        let state = try input(1, iterator.leafWidths)
        guard state.count == 4 else { throw SILError.invalid("\(call.name): ClosedRange iterator state") }
        let (lower, upper, inRange, x) = (state[0], state[1], state[2].bits[0], state[3])
        let atUpper = c.eq(x, upper)
        let next = successor(x, signed: signed, when: c.and(inRange, -atUpper))
        let stillInRange = c.and(inRange, -atUpper)
        let position = [BV(bits: [stillInRange]), select(stillInRange, [next], [constant(0, x.width)])[0]]
        let element = try optional(try written(0), isSome: inRange, payload: [x])
        try write([element, [lower, upper] + select(inRange, position, [state[2], x])])
    }

    /// `IndexingIterator<Array<X>>.next()`: `nil` at `_position == count`; otherwise `self[_position]`
    /// (`_checkValidSubscript`: `_precondition(index >= 0 && index < count, "Index out of range")`), an unknown element,
    /// and `formIndex(after:)`, which is `i += 1` (`Array.swift`).
    mutating func arrayNext() throws {
        let step = try arrayStep(state: try input(1, try written(1).leafWidths))
        let result = try optional(try written(0), isSome: step.more, payload: step.element)
        try write([result, [call.inputs[1][0], step.position]])
    }

    /// What one `next()` of an array's iterator does: whether it gave an element, the new position, the element.
    struct ArrayStep {
        let more: Int32
        let position: BV
        let element: [BV]
    }

    /// One `next()` of an array's `IndexingIterator` with state `[count, position]`: whether it gave an element, the new
    /// position, and the (unknown) element. Elements are approximate.
    mutating func arrayStep(state: [BV], enumerated: Bool = false) throws -> ArrayStep {
        guard state.count == 2, state.allSatisfy({ $0.width == 64 }) else { throw SILError.invalid("\(call.name): Array iterator state") }
        let (count, position) = (state[0], state[1])
        let more = -c.eq(position, count)
        trap(c.and(more, -c.ult(position, count)), "Index out of range")
        let next = successor(position, signed: true, when: more)
        guard case .enumeration(_, let cases) = try written(0), let payload = cases.last?.payload else {
            throw SILError.invalid("\(call.name): result is not an Optional")
        }
        var elementType = payload
        if enumerated {
            // `(offset: Int, element: X)`.
            guard case .aggregate(let name, let fields) = payload, name.isEmpty, fields.count == 2, fields[0].type == .scalar(64) else {
                throw SILError.invalid("\(call.name): result is not an Optional of (offset, element)")
            }
            elementType = fields[1].type
        }
        effect.approximations.insert("Array elements")
        return ArrayStep(more: more, position: c.select(more, next, position), element: fresh(elementType))
    }

    /// `stride(from:to:by:)` / `stride(from:through:by:)`: `StrideTo(_start:end:stride:)`, whose initializer makes
    /// `_precondition(stride != 0, "Stride size must not be zero")` (`Stride.swift`).
    mutating func stride() throws {
        let start = try input(1, [64]), end = try input(2, [64]), step = try input(3, [64])
        trap(c.eq(step[0], constant(0, 64)), "Stride size must not be zero")
        try write([start + end + step])
    }

    /// `StrideTo.makeIterator()`: `_current = (0, _start)` (and `_didReturnEnd = false` for `StrideThrough`).
    mutating func makeStrideIterator(through: Bool) throws {
        let sequence = try input(1, [64, 64, 64])
        let current = [BV(bits: [c.trueLit]), constant(0, 64), sequence[0]]
        try write([sequence + current + (through ? [constant(0, 1)] : [])])
    }

    /// `StrideToIterator.next()` / `StrideThroughIterator.next()` of `Int` (`Stride.swift`). `result = _current.value`;
    /// past the end (`_stride > 0 ? result >= _end : result <= _end`) it returns `nil`, except that `StrideThrough`
    /// returns `_end` itself once (when `result == _end && !_didReturnEnd && _current.index != .min`). Otherwise
    /// `_current = _step(…)`: for a signed fixed-width integer (`@_alwaysEmitIntoClient`, the witness in the 6.4
    /// library), `value.addingReportingOverflow(stride)`, and on overflow `(index: .min, value: stride < 0 ? .min :
    /// .max)` instead of a trap. No check traps.
    mutating func strideNext(through: Bool) throws {
        let iterator = try written(1)
        let state = try input(1, iterator.leafWidths)
        guard state.count == (through ? 7 : 6) else { throw SILError.invalid("\(call.name): stride iterator state") }
        let (end, step, hasIndex, index, value) = (state[1], state[2], state[3].bits[0], state[4], state[5])
        let zero = constant(0, 64), minimum = constant(1 << 63, 64), maximum = constant((1 << 63) - 1, 64)
        let ascending = c.slt(zero, step)
        let past = c.mux(ascending, c.sle(end, value), c.sle(value, end))
        let sum = c.add(value, step).sum
        let overflow = c.signedAddOverflows(value, step)
        let stepped = [
            BV(bits: [overflow]), c.select(overflow, minimum, zero), c.select(overflow, c.select(ascending, maximum, minimum), sum),
        ]
        let current = select(past, [state[3], index, value], stepped)
        var gives = -past
        var tail: [BV] = []
        if through {
            let didReturnEnd = state[6].bits[0]
            let indexIsMin = c.and(hasIndex, c.eq(index, minimum))
            let returnsEnd = c.and(past, c.and(c.eq(value, end), c.and(-didReturnEnd, -indexIsMin)))
            gives = c.or(gives, returnsEnd)
            tail = [BV(bits: [c.or(didReturnEnd, returnsEnd)])]
        }
        let result = try optional(try written(0), isSome: gives, payload: [value])
        try write([result, Array(state[0..<3]) + current + tail])
    }

    /// `Sequence.enumerated()`: `EnumeratedSequence(_base: self)`.
    mutating func enumerated() throws {
        try write([try input(1, [64])])
    }

    /// `EnumeratedSequence.makeIterator()`: `Iterator(_base: _base.makeIterator())`, `_count = 0`.
    mutating func makeEnumeratedIterator() throws {
        let count = try input(1, [64])
        try write([count + [constant(0, 64), constant(0, 64)]])
    }

    /// `EnumeratedSequence.Iterator.next()`: `guard let b = _base.next() else { return nil }`, then the result
    /// `(offset: _count, element: b)` and `_count += 1` (checked).
    mutating func enumeratedNext() throws {
        let state = try input(1, try written(1).leafWidths)
        guard state.count == 3 else { throw SILError.invalid("\(call.name): enumerated iterator state") }
        let step = try arrayStep(state: [state[0], state[1]], enumerated: true)
        let offset = state[2]
        let next = successor(offset, signed: true, when: step.more)
        let result = try optional(try written(0), isSome: step.more, payload: [offset] + step.element)
        try write([result, [state[0], step.position, c.select(step.more, next, offset)]])
    }

    /// `RandomAccessCollection<>.indices`: `startIndex..<endIndex`, which is `0..<count` and checks `0 <= count`.
    mutating func indices() throws {
        let count = try input(1, [64])[0]
        trap(c.slt(count, constant(0, 64)), "Range requires lowerBound <= upperBound")
        // The bound is an `Int`: it must not carry an array literal's identity (`SILArrayLiterals.swift`).
        try write([[constant(0, 64), BV(bits: count.bits.map { c.and($0, c.trueLit) })]])
    }
}
