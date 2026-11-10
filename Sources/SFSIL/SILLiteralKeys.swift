// Reading guide
// The keys of a dictionary literal (plan item L2). Arrays are count-only (`ValueType.array`), so what an array literal
// stores into its element storage is dropped by the encoder. A dictionary literal traps on two equal keys, which is
// decided exactly only from the keys themselves: this file finds them in the SIL of the function the literal is in
// (`_allocateUninitializedArray`, one store per element through the element storage, `_finalizeUninitializedArray`),
// and compares them. Anything else gives nil, and the duplicate trap stays unknown (`SILDictionaries.swift`).

import SFBV

/// The instructions of one function, indexed by the SSA names they define.
struct FunctionIndex {
    var defined: [String: Instruction] = [:]
    /// The block each name is defined in.
    var block: [String: Int] = [:]
    /// The values stored through each address, with the block of the store.
    var stores: [String: [(value: String, block: Int)]] = [:]
    /// The symbol behind each `function_ref`.
    var references: [String: String] = [:]

    init(_ function: SILFunction) {
        for (b, instructions) in function.blocks.map(\.instructions).enumerated() {
            for instruction in instructions {
                if let id = instruction.definedName { (defined[id], block[id]) = (instruction, b) }
                if case .store(let value, let address) = instruction { stores[address, default: []].append((value, b)) }
                if case .functionRef(let id, let symbol) = instruction { references[id] = symbol }
            }
        }
    }

    /// For the array value `array` (the result of `_finalizeUninitializedArray(%a)`, or `%a` itself), `%a` and the
    /// `_allocateUninitializedArray` call whose tuple `%a` is element 0 of.
    func allocation(of array: String) -> (array: String, allocation: String)? {
        var name = array
        if case .apply(_, let callee, let arguments, _, _, _) = defined[name],
            references[callee] == "$ss27_finalizeUninitializedArrayySayxGABnlF", arguments.count == 1
        {
            name = arguments[0]
        }
        guard case .extract(_, let tuple, 0, .tuple) = defined[name], case .apply(_, let callee, _, _, _, _) = defined[tuple],
            references[callee] == "$ss27_allocateUninitializedArrayySayxG_BptBwlF"
        else { return nil }
        return (name, tuple)
    }

    /// The address of element 0 of `array`: the `ref_tail_addr` at the end of its `arrayStorage` chain, if it has one.
    func elementBase(of array: String) -> String? {
        var storage: Set<String> = [array]
        var bases: [String] = []
        var grew = true
        while grew {
            grew = false
            for (id, instruction) in defined where !storage.contains(id) {
                guard let source = instruction.storageSource, storage.contains(source) else { continue }
                storage.insert(id)
                grew = true
                if case .refTailAddress = instruction { bases.append(id) }
            }
        }
        return bases.count == 1 ? bases[0] : nil
    }

    /// The address of each element `0..<count` from the base: the base itself, then `index_addr base, k`.
    func elementAddresses(base: String, count: UInt64) -> [String]? {
        var elements: [UInt64: String] = [0: base]
        for (id, instruction) in defined {
            guard case .indexAddress(_, base, let index) = instruction, case .literal(_, _, let k) = defined[index] else { continue }
            guard elements.updateValue(id, forKey: k) == nil else { return nil }
        }
        let addresses = (0..<count).compactMap { elements[$0] }
        return addresses.count == count ? addresses : nil
    }

    /// The address of field 0 of the tuple at `element`, when exactly one such address is taken.
    func firstField(of element: String) -> String? {
        let fields = defined.filter {
            guard case .elementAddress(_, element, 0, .tuple) = $0.value else { return false }
            return true
        }
        return fields.count == 1 ? fields.first?.key : nil
    }
}

extension SILEncoder {
    /// The elements of the array literal `array` of `count` elements (with `tuples`, the first field of each), as the
    /// values this function stored into it: `_allocateUninitializedArray`, one store per element through its element
    /// storage, then `_finalizeUninitializedArray`, all in one block. Nil when the array is not such a literal, or a
    /// stored value is not known here.
    func literalKeys(of array: String, count: BV, tuples: Bool, in call: SummaryCall) -> [[BV]]? {
        guard let n = knownCount(count), n <= 64, let function = try? module.function(call.function) else { return nil }
        let index = FunctionIndex(function)
        guard let (name, allocation) = index.allocation(of: array), let base = index.elementBase(of: name),
            let elements = index.elementAddresses(base: base, count: n)
        else { return nil }
        var keys: [[BV]] = []
        for element in elements {
            guard let address = tuples ? index.firstField(of: element) : element, let values = index.stores[address],
                values.count == 1, values[0].block == index.block[allocation], let leaves = call.value(values[0].value)
            else { return nil }
            keys.append(leaves)
        }
        return keys
    }

    /// The value stored into the stack slot `slot` by its only store in this function, nil when there is not exactly one.
    func storedValue(into slot: String, in call: SummaryCall) -> String? {
        guard let function = try? module.function(call.function), let values = FunctionIndex(function).stores[slot], values.count == 1
        else { return nil }
        return values[0].value
    }

    /// Whether two `type` values are equal by `==`: bitwise for integers and `Bool` (and optionals of those), the read
    /// modules' own `==` for their types (its traps count only when `condition`). Nil when logic cannot tell.
    func equalKeys(_ type: String, _ a: [BV], _ b: [BV], when condition: Int32, in call: SummaryCall) throws -> Int32? {
        guard a.map(\.width) == b.map(\.width) else { return nil }
        if Self.comparesBitwise(type) {
            return zip(a, b).reduce(c.trueLit) { c.and($0, c.eq($1.0, $1.1)) }
        }
        guard !StdlibSummary.isStandardType(type), StdlibSummary.optionalWrapped(type) == nil,
            TypeContext.arrayElement(type) == nil, let witness = module.witness(type: type, requirement: "#Equatable.\"==\"")
        else { return nil }
        let result = try call.call(witness, a + b, condition)
        guard result.results.count == 1, result.results[0].width == 1 else { return nil }
        return result.results[0].bits[0]
    }

    /// Integers, `Bool`, and optionals of those: `==` is equality of the leaves (an inactive payload is zero).
    static func comparesBitwise(_ type: String) -> Bool {
        if let wrapped = StdlibSummary.optionalWrapped(type) { return comparesBitwise(wrapped) }
        let t = type.hasPrefix("Swift.") ? String(type.dropFirst(6)) : type
        return t == "Bool" || StdlibSummary.integerKind(t) != nil
    }
}

extension Instruction {
    /// The SSA name this instruction defines, if any.
    var definedName: String? {
        switch self {
        case .literal(let r, _, _), .retype(let r, _, _), .builtin(let r, _, _), .floatBuiltin(let r, _, _),
            .makeAggregate(let r, _, _), .extract(let r, _, _, _), .functionRef(let r, _), .apply(let r, _, _, _, _, _),
            .allocStack(let r, _), .load(let r, _), .elementAddress(let r, _, _, _), .alias(let r, _), .allocArray(let r, _, _),
            .globalValue(let r, _), .refTailAddress(let r, _, _), .arrayStorage(let r, _), .indexAddress(let r, _, _),
            .headerAddress(let r), .existentialBox(let r, _), .boxedValueAddress(let r), .existentialAddress(let r, _, _),
            .makeEnum(let r, _, _, _),
            .enumPayload(let r, _, _), .selectEnum(let r, _, _, _, _), .enumPayloadAddress(let r, _, _, _),
            .stringLiteral(let r, _), .allocObject(let r, _), .enumTag(let r, _), .closure(let r, _, _, _), .globalAddress(let r, _, _),
            .pointerToAddress(let r, _, _):
            return r
        case .beginApply(let address, _, _, _, _): return address
        case .beginCOW(_, let buffer, _): return buffer
        case .condFail, .store, .injectEnum, .copyAddress, .ignored: return nil
        }
    }

    /// What an array's element storage is reached from: the source of an `arrayStorage`, an `alias` (the
    /// `unchecked_ref_cast` to the storage class) or a `ref_tail_addr`; nil for any other instruction.
    fileprivate var storageSource: String? {
        switch self {
        case .arrayStorage(_, let source), .alias(_, let source), .refTailAddress(_, let source, _): source
        default: nil
        }
    }
}
