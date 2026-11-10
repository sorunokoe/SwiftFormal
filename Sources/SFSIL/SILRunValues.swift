import SFBV
import SFCNF
import SFSemantics

// Reading guide
// Literals, conversions, builtins, aggregates, enums and closures: instructions that make a value from values.
// Part of `FunctionRun` (`SILFunctionRun.swift`).

extension FunctionRun {
    func valueType(_ v: Value) -> ValueType? {
        switch v {
        case .scalar(let b): .scalar(b.width)
        case .aggregate(let t, _): t
        default: nil
        }
    }

    func leaves(_ v: Value) -> [BV]? {
        switch v {
        case .scalar(let b): [b]
        case .aggregate(_, let l): l
        default: nil
        }
    }

    /// `struct`, `tuple`, and a new closure (an opaque handle that nothing reads, built from no operands).
    func aggregate(_ id: String, _ type: ValueType?, _ operands: [Value]) throws(SILError) -> Value {
        if let type, type == TypeContext.closure || type == TypeContext.keyPath, operands.isEmpty {
            return .aggregate(type, [c.constant(0, width: 64)])
        }
        let types = operands.compactMap(valueType)
        guard types.count == operands.count else {
            throw SILError.invalid("aggregate operand is not a value at \(id)")
        }
        let resolved = type ?? .aggregate(name: "", fields: types.enumerated().map { .init(name: "\($0)", type: $1) })
        guard case .aggregate(_, let fields) = resolved, fields.map(\.type) == types else {
            throw SILError.invalid("aggregate operands do not match the type at \(id)")
        }
        return .aggregate(resolved, operands.flatMap { leaves($0) ?? [] })
    }

    func make(_ type: ValueType, _ leaves: [BV]) -> Value {
        if case .scalar = type { return .scalar(leaves[0]) }
        return .aggregate(type, leaves)
    }

    /// Encodes `Instruction.stringLiteral`.
    func encodeStringLiteral(_ id: String, _ text: String?) {
        if let text { stringTexts[id] = text }
    }

    /// Encodes `Instruction.enumTag`.
    func encodeEnumTag(_ id: String, _ operand: String) throws {
        let isAddress: Bool
        if case .address = try lookup(operand) { isAddress = true } else { isAddress = false }
        let (type, l) = isAddress ? try slotValue(operand) : try enumValue(operand)
        env[id] = .scalar(try encoder.runtimeEnumTag(type, l))
    }

    /// Encodes `Instruction.retype`.
    func encodeRetype(_ id: String, _ source: String, _ width: Int) throws {
        let v = try scalar(source)
        guard v.width == width else { throw SILError.invalid("retype width mismatch at \(id)") }
        env[id] = .scalar(v)
    }

    /// Encodes `Instruction.builtin`.
    func encodeBuiltin(_ id: String, _ op: S0Instance, _ names: [String]) throws {
        let args = try names.map(scalar)
        guard args.map(\.width) == op.operandWidths else {
            throw SILError.invalid("operand widths of \(op.builtinName) at \(id)")
        }
        let (values, ub) = op.encode(c, args)
        undefined(ub)
        env[id] = values.count == 2 ? .aggregate(.tuple([values[0].width, 1]), values) : .scalar(values[0])
    }

    /// Encodes `Instruction.floatBuiltin`.
    func encodeFloatBuiltin(_ id: String, _ op: S0FloatInstance, _ names: [String]) throws {
        let args = try names.map(scalar)
        guard args.map(\.width) == op.operandWidths else {
            throw SILError.invalid("operand widths of a float builtin at \(id)")
        }
        let result = op.encodeExactly(c, args)
        undefined(result.undefined)
        if !result.exact { out.approximations.insert("floating point") }
        env[id] = .scalar(result.value)
    }

    /// Encodes `Instruction.makeAggregate`.
    func encodeMakeAggregate(_ id: String, _ type: ValueType?, _ names: [String]) throws {
        env[id] = try aggregate(id, type, try names.map { try lookup($0) })
        if type == TypeContext.keyPath, names.isEmpty { literalKeyPaths.insert(id) }
    }

    /// Encodes `Instruction.extract`.
    func encodeExtract(_ id: String, _ source: String, _ field: Int, _ expected: FieldOwner) throws {
        guard case .aggregate(let type, let l) = try lookup(source), let range = type.leafRange(ofField: field),
            case .aggregate(_, let fields) = type, expected.matches(type)
        else {
            throw SILError.invalid("extract of field \(field) from \(source) does not match its type")
        }
        env[id] = make(fields[field].type, Array(l[range]))
    }

    /// Encodes `Instruction.alias`.
    func encodeAlias(_ id: String, _ source: String) throws {
        env[id] = try lookup(source)
        if literalKeyPaths.contains(source) { literalKeyPaths.insert(id) }
        closureLiterals[id] = closureLiterals[source]
    }

    /// Encodes `Instruction.closure`.
    func encodeClosure(_ id: String, _ type: ValueType, _ callee: String, _ captures: [String]) {
        env[id] = .aggregate(type, [closureLeaf(callee, captures)])
        closureLiterals[id] = (callee, captures)
    }

    /// Encodes `Instruction.makeEnum`.
    func encodeMakeEnum(_ id: String, _ type: ValueType, _ caseName: String, _ payloadID: String?) throws {
        let (k, payloadType) = try type.enumCase(named: caseName)
        var payload: [BV] = []
        if let payloadID {
            let v = try lookup(payloadID)
            guard let payloadType, valueType(v) == payloadType, let l = leaves(v) else {
                throw SILError.invalid("payload of \(caseName) does not match its type at \(id)")
            }
            payload = l
        } else if payloadType != nil {
            throw SILError.invalid("case \(caseName) needs a payload at \(id)")
        }
        env[id] = .aggregate(type, encoder.enumLeaves(type, case: k, payload: payload))
    }

    /// Encodes `Instruction.enumPayload`.
    func encodeEnumPayload(_ id: String, _ source: String, _ caseName: String) throws {
        let (type, l) = try enumValue(source)
        let (k, payloadType) = try type.enumCase(named: caseName)
        guard let payloadType else { throw SILError.invalid("unchecked_enum_data of \(caseName), which has no payload") }
        undefined(-c.eq(l[0], c.constant(UInt64(k), width: l[0].width)))
        env[id] = make(payloadType, Array(l[type.payloadLeafRange(ofCase: k)]))
    }

    /// Encodes `Instruction.selectEnum`.
    func encodeSelectEnum(_ id: String, _ source: String, _ isAddress: Bool, _ cases: [EnumTarget], _ fallback: String?) throws {
        let (type, l) = isAddress ? try slotValue(source) : try enumValue(source)
        let conditions = try encoder.caseConditions(tag: l[0], type: type, listed: cases, hasDefault: fallback != nil)
        let values = try (cases.map(\.target) + (fallback.map { [$0] } ?? [])).map { try lookup($0) }
        guard let resultType = valueType(values[0]), values.allSatisfy({ valueType($0) == resultType }) else {
            throw SILError.invalid("select_enum values of different types at \(id)")
        }
        let options = values.compactMap(leaves)
        guard options.count == values.count, var selected = options.last else {
            throw SILError.unsupported("select_enum over values without leaves at \(id)")
        }
        for (condition, value) in zip(conditions, options).dropLast().reversed() {
            selected = zip(value, selected).map { c.select(condition, $0, $1) }
        }
        env[id] = make(resultType, selected)
    }
}
