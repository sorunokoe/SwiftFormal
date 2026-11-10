import SFBV
import SFCNF
import SFSemantics

// Reading guide
// Arrays: their buffers and literals as instructions, and the summarized `Array` calls (counts exact, elements
// unknown unless a literal is known).
// Part of `FunctionRun` (`SILFunctionRun.swift`).

extension FunctionRun {
    /// Encodes `Instruction.beginCOW`.
    func encodeBeginCOW(_ flag: String, _ buffer: String, _ source: String) throws {
        guard case .array = try lookup(source) else { throw SILError.unsupported("begin_cow_mutation of \(source)") }
        env[buffer] = try lookup(source)
        env[flag] = .opaque
    }

    /// Encodes `Instruction.allocArray`.
    func encodeAllocArray(_ id: String, _ width: Int, _ countName: String) throws {
        guard let n = c.constantValue(try scalar(countName)), n >= 1, n <= 256 else {
            throw SILError.unsupported(
                "stack array whose length is not a constant in 1...256 (symbolic-length arrays are not modelled)")
        }
        env[id] = .array(ArrayObject(id: id, width: width, count: Int(n), table: nil))
    }

    /// Encodes `Instruction.globalValue`.
    func encodeGlobalValue(_ id: String, _ symbol: String) throws {
        let table = try module.globalTable(symbol)
        guard !table.values.isEmpty else { throw SILError.unsupported("empty array literal") }
        env[id] = .array(ArrayObject(id: symbol, width: table.elementWidth, count: table.values.count, table: table.values))
    }

    /// Encodes `Instruction.refTailAddress`.
    func encodeRefTailAddress(_ id: String, _ source: String, _ width: Int?) throws {
        if case .literalStorage(let literal) = try lookup(source) {
            literalSlots[literal.elementSlot(0)] = (literal, 0)
            env[id] = .address(.slot(id: literal.elementSlot(0), leaf: 0, type: literal.element))
            return
        }
        if case .sink = try lookup(source) {
            env[id] = .address(.sink)
            return
        }
        guard case .array(let object) = try lookup(source), object.width == width else {
            throw SILError.unsupported("ref_tail_addr of \(source)")
        }
        env[id] = .address(.element(object, index: c.constant(0, width: 64)))
    }

    /// Encodes `Instruction.indexAddress`.
    func encodeIndexAddress(_ id: String, _ base: String, _ index: String) throws {
        if case .address(.slot(let slot, 0, _)) = try lookup(base), let (literal, start) = literalSlots[slot] {
            guard let offset = c.constantValue(try scalar(index)), start + Int(offset) < literal.count else {
                unknownLiterals.insert(literal.slot)
                env[id] = .address(.sink)
                return
            }
            let k = start + Int(offset)
            literalSlots[literal.elementSlot(k)] = (literal, k)
            env[id] = .address(.slot(id: literal.elementSlot(k), leaf: 0, type: literal.element))
            return
        }
        if case .address(.sink) = try lookup(base) {
            env[id] = .address(.sink)
            return
        }
        guard case .address(.element(let object, let start)) = try lookup(base) else {
            throw SILError.unsupported("index_addr from \(base)")
        }
        let offset = try scalar(index)
        guard offset.width == 64 else { throw SILError.invalid("index_addr offset width at \(id)") }
        env[id] = .address(.element(object, index: c.add(start, offset).sum))
    }

    /// Encodes `Instruction.arrayStorage`.
    func encodeArrayStorage(_ id: String, _ source: String) throws {
        switch try lookup(source) {
        case .sink: env[id] = .sink
        case .literalStorage(let literal): env[id] = .literalStorage(literal)
        case .aggregate(.array, let count): env[id] = literals[count[0].bits].map { .literalStorage($0) } ?? .sink
        default: throw SILError.unsupported("array buffer of \(source), which is not an array value")
        }
    }

    /// Encodes `Instruction.beginApply`.
    func encodeBeginApply(
        _ address: String, _ callee: String, _ names: [String], _ substitutions: [String], _ conventions: [ParameterConvention]
    ) throws {
        // Only `Array.subscript.modify`: checks the index, then yields an unknown element whose new value is dropped.
        guard case .function(let target) = try lookup(callee), target == StdlibSummary.arraySubscriptModify,
            conventions == [.value, .inout], substitutions.count == 1
        else {
            throw SILError.unsupported("coroutine call (begin_apply) through \(callee)")
        }
        guard module.destroysWithoutModuleCode(substitutions[0]) else {
            throw SILError.unsupported(
                "Array.subscript on \(substitutions[0]), whose values may run code of this module when destroyed")
        }
        guard let index = leaves(try lookup(names[0])), index.count == 1, index[0].width == 64 else {
            throw SILError.invalid("Array.subscript index at \(address)")
        }
        let n = try arrayCount(names[1], .inout)
        encoder.recordElements(nil, count: n)  // the element may change: forget them all (`SILArrayLiterals.swift`)
        trap(-c.ult(index[0], n), site: .stdlib(id: address, message: "Index out of range"))
        let element = try module.resolve(substitutions[0])
        env[address] = .address(.slot(id: address, leaf: 0, type: element))
        for (i, leaf) in fresh(element).enumerated() { cells["\(address)#\(i)"] = leaf }
        out.approximations.insert("Array.subscript")
    }

    func arrayCount(_ name: String, _ convention: ParameterConvention) throws -> BV {
        let (type, l): (ValueType?, [BV]?)
        if convention == .value {
            let v = try lookup(name)
            (type, l) = (valueType(v), leaves(v))
        } else {
            let read = try slotValue(name)
            (type, l) = (read.type, read.leaves)
        }
        guard case .array = type, let count = l?.first else {
            throw SILError.invalid("\(name) is not an array in \(function.symbol)")
        }
        return count
    }

    func arrayArgument(_ call: ArrayCall, _ k: Int) throws -> BV {
        let a = try call.argument(k)
        return try arrayCount(a.name, a.convention)
    }

    func intArgument(_ call: ArrayCall, _ k: Int) throws -> BV {
        let a = try call.argument(k)
        guard a.convention == .value, let l = leaves(try lookup(a.name)), l.count == 1, l[0].width == 64 else {
            throw SILError.invalid("\(call.name): argument \(k) is not a 64-bit integer at \(call.request.id)")
        }
        return l[0]
    }

    /// Writes `count` back to the `@inout` array argument `k`.
    func setArrayCount(_ call: ArrayCall, _ k: Int, _ value: BV) throws {
        let a = try call.argument(k)
        let reference = try slot(a.name)
        guard a.convention == .inout, case .array = reference.type else {
            throw SILError.invalid("\(call.name): argument \(k) is not an inout array at \(call.request.id)")
        }
        cells["\(reference.id)#\(reference.leaf)"] = value
    }

    /// Writes a value into the `@out` result address (argument 0).
    func setOutResult(_ call: ArrayCall, _ make: (ValueType) throws -> [BV]) throws {
        let a = try call.argument(0)
        guard a.convention == .out else { throw SILError.invalid("\(call.name) without its result address") }
        let reference = try slot(a.name)
        for (i, leaf) in try make(reference.type).enumerated() { cells["\(reference.id)#\(reference.leaf + i)"] = leaf }
    }

    /// An Optional that is `nil` when `isNone`, otherwise holds `payload` (fresh unless given).
    func optionalLeaves(_ call: ArrayCall, _ type: ValueType, isNone: Int32, payload: [BV]? = nil) throws -> [BV] {
        guard case .enumeration(_, let cases) = type, cases.count == 2, cases[0].payload == nil, let wrapped = cases[1].payload,
            payload.map({ $0.map(\.width) }) ?? wrapped.leafWidths == wrapped.leafWidths
        else {
            throw SILError.invalid("\(call.name): result is not a matching Optional at \(call.request.id)")
        }
        let inner = payload ?? fresh(wrapped)
        return [BV(bits: [-isNone])] + inner.map { leaf in BV(bits: leaf.bits.map { c.and($0, -isNone) }) }
    }

    /// Returns the result, if the call has one, and whether it is approximate.
    func readArray(_ operation: StdlibSummary.ArrayRead, _ call: ArrayCall) throws -> ([BV]?, Bool) {
        let zero = c.constant(0, width: 64)
        switch operation {
        case .count: return ([encoder.plainCount(try arrayArgument(call, 0))], false)
        case .startIndex: return ([zero], false)
        case .isEmpty: return ([BV(bits: [c.eq(try arrayArgument(call, 0), zero)])], false)
        case .subscriptGet:
            let n = try arrayArgument(call, 2)
            let index = try intArgument(call, 1)
            trap(-c.ult(index, n), site: call.site("Index out of range"))
            var exact = true
            try setOutResult(call) {
                if let element = encoder.literalElement(n, at: index, widths: $0.leafWidths) { return element }
                exact = false
                return fresh($0)
            }
            if exact { return (nil, false) }
        case .first, .last:
            let n = try arrayArgument(call, 1)
            let index = operation == .first ? zero : c.sub(n, c.constant(1, width: 64)).difference
            var exact = true
            try setOutResult(call) {
                if case .enumeration(_, let cases) = $0, cases.count == 2, let wrapped = cases[1].payload,
                    let element = encoder.literalElement(n, at: index, widths: wrapped.leafWidths)
                {
                    return try optionalLeaves(call, $0, isNone: c.eq(n, zero), payload: element)
                }
                exact = false
                return try optionalLeaves(call, $0, isNone: c.eq(n, zero))
            }
            if exact { return (nil, false) }
        case .indices: try setOutResult(call) { _ in [zero, encoder.plainCount(try arrayArgument(call, 1))] }; return (nil, false)
        }
        return (nil, true)
    }

    /// A count an array operation computes. No array holds 2^48 elements or more (every element takes at least a
    /// byte, and no allocation of 2^48 bytes succeeds; TRUST.md), so reaching that count is the allocation
    /// failing: a trap. The same bound is assumed of every array input (`ValueType.validity`).
    func newCount(_ n: BV, _ call: ArrayCall) -> BV {
        trap(-c.ult(n, c.constant(1 << 48, width: 64)), site: call.site("array too large: allocation fails"))
        return n
    }

    func makeArray(_ operation: StdlibSummary.ArrayMake, _ call: ArrayCall) throws -> [BV] {
        switch operation {
        case .concatenate: return [newCount(c.add(try arrayArgument(call, 0), try arrayArgument(call, 1)).sum, call)]
        case .allocate:
            guard let l = leaves(try lookup(try call.argument(0).name)), l.count == 1, l[0].width == 64 else {
                throw SILError.invalid("\(call.name): length is not a word at \(call.request.id)")
            }
            guard let n = c.constantValue(l[0]), n >= 1, n <= SILEncoder.maxLiteralElements,
                call.request.substitutions.count == 1, let element = try? module.resolve(call.request.substitutions[0]),
                element != .opaque(name: "StaticString")  // its values are failure-message plumbing, not read
            else { return [encoder.plainCount(l[0]), c.input(width: 64)] }
            let count = encoder.literalCount(Int(n))
            literals[count.bits] = LiteralArray(slot: "\(call.request.id)@literal", count: Int(n), element: element)
            return [count, c.input(width: 64)]
        case .finalize:
            let count = try arrayArgument(call, 0)
            if let literal = literals.removeValue(forKey: count.bits) {
                finalizedLiterals.insert(literal.slot)
                let known = unknownLiterals.contains(literal.slot) ? nil : SILEncoder.storedElements(literal, cells)
                encoder.recordElements(known, count: count)
            }
            return [count]
        case .empty: return [c.constant(0, width: 64)]
        case .repeating:
            let n = try intArgument(call, 1)
            trap(c.slt(n, c.constant(0, width: 64)), site: call.site("Can't construct Array with count < 0"))
            return [newCount(encoder.plainCount(n), call)]
        case .defaultFalse: return [c.constant(0, width: 1)]
        }
    }

    /// Returns whether the call's `@out` result is approximate.
    func mutateArray(_ operation: StdlibSummary.ArrayMutation, _ call: ArrayCall) throws -> Bool {
        let one = c.constant(1, width: 64), zero = c.constant(0, width: 64)
        switch operation {
        case .append: try setArrayCount(call, 1, newCount(c.add(try arrayArgument(call, 1), one).sum, call))
        case .appendArray:
            try setArrayCount(call, 0, newCount(c.add(try arrayArgument(call, 0), try arrayArgument(call, 1)).sum, call))
        case .removeAll: try setArrayCount(call, 1, zero)
        case .insert:
            let n = try arrayArgument(call, 2)
            trap(-c.ule(try intArgument(call, 1), n), site: call.site("Array index is out of range"))
            try setArrayCount(call, 2, newCount(c.add(n, one).sum, call))
        case .removeAt:
            let n = try arrayArgument(call, 2)
            trap(-c.ult(try intArgument(call, 1), n), site: call.site("Index out of range"))
            try setArrayCount(call, 2, c.sub(n, one).difference)
            try setOutResult(call) { fresh($0) }
            return true
        case .removeLast:
            let n = try arrayArgument(call, 1)
            trap(c.eq(n, zero), site: call.site("Can't remove last element from an empty collection"))
            try setArrayCount(call, 1, c.sub(n, one).difference)
            try setOutResult(call) { fresh($0) }
            return true
        case .popLast:
            let n = try arrayArgument(call, 1)
            let isEmpty = c.eq(n, zero)
            try setArrayCount(call, 1, c.select(isEmpty, n, c.sub(n, one).difference))
            try setOutResult(call) { try optionalLeaves(call, $0, isNone: isEmpty) }
            return true
        }
        return false
    }

    /// Results are unknown unless an array is empty; a module element type's `==` runs on unknown elements.
    func searchArray(_ operation: StdlibSummary.ArraySearch, _ call: ArrayCall) throws -> [BV]? {
        let zero = c.constant(0, width: 64)
        switch operation {
        case .equals:
            let (a, b) = (try arrayArgument(call, 0), try arrayArgument(call, 1))
            let sameCount = c.eq(a, b)
            if let element = call.request.substitutions.first {
                try equate(element, when: c.and(sameCount, -c.eq(a, zero)), site: call.request.id)
            }
            // Different counts: false. Both empty: true. Otherwise unknown.
            return [BV(bits: [c.and(sameCount, c.or(c.eq(a, zero), c.input(width: 1).bits[0]))])]
        case .contains:
            let nonEmpty = -c.eq(try arrayArgument(call, 1), zero)
            try equate(try sequenceElement(call.request.substitutions), when: nonEmpty, site: call.request.id)
            return [BV(bits: [c.and(nonEmpty, c.input(width: 1).bits[0])])]
        case .firstIndex:
            let n = try arrayArgument(call, 2)
            try equate(try sequenceElement(call.request.substitutions), when: -c.eq(n, zero), site: call.request.id)
            let index = c.input(width: 64)
            let found = c.and(-c.eq(n, zero), c.input(width: 1).bits[0])
            try setOutResult(call) {
                try optionalLeaves(call, $0, isNone: -found, payload: [c.select(c.ult(index, n), index, zero)])
            }
            return nil
        }
    }

    /// A call into `Array` (see `StdlibSummary.ArrayOperation`). Counts are exact; elements are unknown.
    func applyArray(_ operation: StdlibSummary.ArrayOperation, _ entry: StdlibSummary.Entry, _ request: SummarizedCall) throws {
        for substitution in request.substitutions
        where !module.destroysWithoutModuleCode(substitution) && !holdsCheckedFormatArguments(operation, substitution, request) {
            throw SILError.unsupported("\(entry.name) on \(substitution), whose values may run code of this module when destroyed")
        }
        let call = ArrayCall(name: entry.name, request: request)
        let (result, approximate): ([BV]?, Bool)
        switch operation {
        case .read(let read): (result, approximate) = try readArray(read, call)
        case .make(let make): (result, approximate) = (try makeArray(make, call), false)
        case .mutate(let mutation): (result, approximate) = (nil, try mutateArray(mutation, call))
        case .search(let search): (result, approximate) = (try searchArray(search, call), true)
        }
        guard (result ?? []).map(\.width) == request.type.leafWidths else {
            throw SILError.invalid("\(entry.name): result type at \(request.id)")
        }
        env[request.id] = make(request.type, result ?? [])
        if approximate { out.approximations.insert(entry.name) }
    }

    /// `X` for the substitution `Array<X>` of a generic `Sequence`/`Collection` call.
    func sequenceElement(_ substitutions: [String]) throws -> String {
        guard substitutions.count == 1, let element = TypeContext.arrayElement(substitutions[0]) else {
            throw SILError.unsupported("call on <\(substitutions.joined(separator: ", "))>, which is not an array")
        }
        return element
    }
}
