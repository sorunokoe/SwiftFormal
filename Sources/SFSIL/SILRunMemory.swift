import SFBV
import SFCNF
import SFSemantics

// Reading guide
// Stack slots, objects, globals and the elements of stack arrays: instructions that read or write memory.
// Part of `FunctionRun` (`SILFunctionRun.swift`).

extension FunctionRun {
    /// Encodes `Instruction.globalAddress`.
    func encodeGlobalAddress(_ id: String, _ symbol: String, _ type: ValueType) throws {
        guard encoder.initializingGlobals.contains(symbol) else {
            throw SILError.unsupported("global_addr @\(symbol) outside its initializer (only `let` globals are read)")
        }
        env[id] = .address(.slot(id: SILEncoder.globalSlot(symbol), leaf: 0, type: type))
    }

    /// Encodes `Instruction.pointerToAddress`.
    func encodePointerToAddress(_ id: String, _ source: String, _ type: ValueType) throws {
        guard case .address(.slot(let slot, 0, type)) = try lookup(source), slot.hasPrefix("global:") else {
            throw SILError.unsupported("pointer_to_address of \(source), which is not a `let` global's address")
        }
        env[id] = try lookup(source)
    }

    /// Encodes `Instruction.existentialBox`.
    func encodeExistentialBox(_ id: String, _ payload: String) throws {
        // Destroying the box destroys the boxed value: it must not run code of the read modules.
        guard module.destroysWithoutModuleCode(payload) else {
            throw SILError.unsupported("an error box holding \(payload), whose destruction may run code of this module")
        }
        let handle = ValueType.opaque(name: "existential")
        env[id] = make(handle, fresh(handle))
    }

    /// Encodes `Instruction.allocObject`.
    func encodeAllocObject(_ id: String, _ type: ValueType) {
        env[id] = .address(.slot(id: id, leaf: 0, type: type))
        for (i, leaf) in fresh(type).enumerated() { cells["\(id)#\(i)"] = leaf }
    }

    /// Encodes `Instruction.store`.
    func encodeStore(_ valueID: String, _ address: String) throws {
        guard case .address(let a) = try lookup(address) else { throw SILError.unsupported("store through \(address)") }
        switch a {
        case .header, .sink: break  // array header plumbing and unmodelled elements
        case .slot(let id, let leaf, let type):
            let v = try lookup(valueID)
            if let element = literalSlots[id] {
                guard !finalizedLiterals.contains(element.literal.slot) else {
                    throw SILError.unsupported("a store into an array literal after it was made, at \(address)")
                }
                if valueType(v) != type {
                    unknownLiterals.insert(element.literal.slot)
                    break
                }
            }
            guard valueType(v) == type, let l = leaves(v) else { throw SILError.invalid("store type mismatch into \(id)") }
            for (i, bv) in l.enumerated() { cells["\(id)#\(leaf + i)"] = bv }
        case .element(let object, let index):
            let v = try scalar(valueID)
            guard v.width == object.width else { throw SILError.invalid("store width mismatch into \(object.id)") }
            try storeElement(object, index, v, &cells, live: live, undefined: undefined)
        }
    }

    /// Encodes `Instruction.load`.
    func encodeLoad(_ id: String, _ address: String) throws {
        guard case .address(let a) = try lookup(address) else {
            throw SILError.unsupported("load of \(address): not an address")
        }
        switch a {
        case .header: throw SILError.unsupported("load from an array header")
        case .sink: throw SILError.unsupported("read of an array element through its buffer")
        case .slot:
            let (type, l) = try slotValue(address)
            env[id] = make(type, l)
        case .element(let object, let index):
            env[id] = .scalar(try loadElement(object, index, cells, undefined: undefined))
        }
    }

    /// Encodes `Instruction.elementAddress`.
    func encodeElementAddress(_ id: String, _ base: String, _ field: Int, _ expected: FieldOwner) throws {
        if case .address(.sink) = try lookup(base) {
            env[id] = .address(.sink)  // a field of an element of an array under construction
            return
        }
        guard case .address(.slot(let slot, let leaf, let type)) = try lookup(base),
            case .aggregate(_, let fields) = type, let range = type.leafRange(ofField: field),
            expected.matches(type)
        else {
            throw SILError.unsupported("element address of \(base)")
        }
        env[id] = .address(.slot(id: slot, leaf: leaf + range.lowerBound, type: fields[field].type))
    }

    /// Encodes `Instruction.enumPayloadAddress`.
    func encodeEnumPayloadAddress(_ id: String, _ base: String, _ caseName: String, _ checksCase: Bool) throws {
        let reference = try slot(base)

        let (slotID, leaf, type) = (reference.id, reference.leaf, reference.type)
        let (k, payloadType) = try type.enumCase(named: caseName)
        guard let payloadType else { throw SILError.invalid("payload address of \(caseName), which has no payload") }
        if checksCase {
            guard let tag = cells["\(slotID)#\(leaf)"] else {
                throw SILError.unsupported("enum payload address of an uninitialized stack slot at \(id)")
            }
            undefined(-c.eq(tag, c.constant(UInt64(k), width: tag.width)))
        }
        let range = type.payloadLeafRange(ofCase: k)
        env[id] = .address(.slot(id: slotID, leaf: leaf + range.lowerBound, type: payloadType))
    }

    /// Encodes `Instruction.injectEnum`.
    func encodeInjectEnum(_ address: String, _ caseName: String) throws {
        let reference = try slot(address)

        let (slotID, leaf, type) = (reference.id, reference.leaf, reference.type)
        let (k, _) = try type.enumCase(named: caseName)
        let widths = type.leafWidths
        let active = type.payloadLeafRange(ofCase: k)
        cells["\(slotID)#\(leaf)"] = c.constant(UInt64(k), width: widths[0])
        for i in 1..<widths.count where !active.contains(i) {
            cells["\(slotID)#\(leaf + i)"] = c.constant(0, width: widths[i])
        }
    }

    /// Encodes `Instruction.copyAddress`.
    func encodeCopyAddress(_ source: String, _ destination: String) throws {
        if case .address(.sink) = try lookup(destination) { return }
        let (type, l) = try slotValue(source)
        let reference = try slot(destination)

        let (slotID, leaf, destinationType) = (reference.id, reference.leaf, reference.type)
        guard type == destinationType else { throw SILError.invalid("copy_addr between different types") }
        for (i, bv) in l.enumerated() { cells["\(slotID)#\(leaf + i)"] = bv }
    }

    func elementCell(_ object: ArrayObject, _ k: Int, _ cells: [String: BV]) throws -> BV {
        if let table = object.table { return c.constant(table[k], width: object.width) }
        guard let v = cells["\(object.id)[\(k)]"] else {
            throw SILError.unsupported("read of an uninitialized element of stack array \(object.id)")
        }
        return v
    }

    func loadElement(_ object: ArrayObject, _ index: BV, _ cells: [String: BV], undefined: (Int32) -> Void) throws -> BV {
        guard index.width == 64 else { throw SILError.invalid("array index width") }
        undefined(-c.ult(index, c.constant(UInt64(object.count), width: 64)))
        if let k = c.constantValue(index) {
            return k < UInt64(object.count) ? try elementCell(object, Int(k), cells) : c.constant(0, width: object.width)
        }
        var value = try elementCell(object, object.count - 1, cells)
        for k in stride(from: object.count - 2, through: 0, by: -1) {
            value = c.select(c.eq(index, c.constant(UInt64(k), width: 64)), try elementCell(object, k, cells), value)
        }
        return value
    }

    func storeElement(
        _ object: ArrayObject, _ index: BV, _ value: BV, _ cells: inout [String: BV],
        live: Int32, undefined: (Int32) -> Void
    ) throws {
        guard object.table == nil else { throw SILError.unsupported("store into an immutable array literal") }
        guard index.width == 64 else { throw SILError.invalid("array index width") }
        undefined(-c.ult(index, c.constant(UInt64(object.count), width: 64)))
        if let k = c.constantValue(index) {
            if k < UInt64(object.count) { cells["\(object.id)[\(k)]"] = value }
            return
        }
        for k in 0..<object.count {
            let old = try elementCell(object, k, cells)
            cells["\(object.id)[\(k)]"] = c.select(c.eq(index, c.constant(UInt64(k), width: 64)), value, old)
        }
    }
}
