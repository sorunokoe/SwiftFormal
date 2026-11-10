import SFBV
import SFCNF
import SFSemantics

// Reading guide
// Calls (inlined, with their traps and written-back arguments), `cond_fail`, and the terminators: edges, returns,
// throws and `try_apply`.
// Part of `FunctionRun` (`SILFunctionRun.swift`).

extension FunctionRun {
    /// Encodes `Instruction.condFail`.
    func encodeCondFail(_ id: String) throws {
        let v = try scalar(id)
        guard v.width == 1 else { throw SILError.invalid("cond_fail on non-Int1 \(id)") }
        out.traps.append(TrapEvent(block: blockIndex, condition: c.and(live, v.bits[0]), site: .condFail(operand: id)))
        live = c.and(live, -v.bits[0])  // execution stops at a failed cond_fail
    }

    /// Encodes `Instruction.apply`.
    func encodeApply(_ callee: String, _ request: SummarizedCall) throws {
        let (id, names, type, substitutions, conventions) = (
            request.id, request.names, request.type, request.substitutions, request.conventions
        )
        guard case .function(let target) = try lookup(callee) else { return try applyClosureValue(callee, request) }
        // An Objective-C method or a String bridge: its result is a foreign result (`SILForeignCalls.swift`).
        if ForeignCall.answers(target) {
            guard module.opaqueCalls != .none else {
                throw SILError.unsupported(
                    "Objective-C call \(ForeignCall.memberLabel(target)) on \(ForeignCall.owner(target)) \(OpaqueCallMode.strictNote)")
            }
            let operands = try names.map { (name: $0, type: valueType(try lookup($0)), leaves: try flat($0)) }
            let result = try encoder.foreignCall(target, type, operands.map { ($0.name, $0.type) }, reached: live, in: function.symbol)
            if result.approximate { out.approximations.insert(ForeignCall.approximation) }
            env[id] = make(type, result.leaves)
            Assumptions.note(ForeignCall.assumption(target, type))
            return
        }
        // A runtime hook for debuggers before a typed `throw`: no effect on the program (plan item L6).
        if target == "swift_willThrowTyped" {
            env[id] = make(type, [])
            return
        }
        if let access = try module.globalAccess(target) {
            let value = try encoder.globalValue(access, stack: stack + [function.symbol])
            trap(value.trap, site: .call(id: id, callee: access.initializer, inner: value.trapSites))
            undefined(value.undefined)
            out.approximations.formUnion(value.approximations)
            let slot = SILEncoder.globalSlot(access.global)
            for (i, leaf) in value.leaves.enumerated() { cells["\(slot)#\(i)"] = leaf }
            env[id] = .address(.slot(id: slot, leaf: 0, type: access.type))
            return
        }
        if let entry = try module.summary(calling: target) {
            try applySummary(entry, request)
            return
        }
        if try encodeLocalization(target, request) || encodeFormat(target, request) || encodeOpaqueCall(target, request) { return }
        // Plan item L7: a generic function of the read modules is read at the call's concrete types.
        let callee = substitutions.isEmpty ? target : try module.specialize(target, substitutions)
        let arguments = try callArguments(names, conventions)
        let result = try call(callee, arguments, at: id)
        guard result.results.map(\.width) == type.leafWidths else {
            throw SILError.invalid("call result type mismatch at \(id)")
        }
        try writeBack(result.writtenBack, names: names, conventions: conventions)
        env[id] = try callResult(callee, id, type, result, names)
    }

    /// Inlines `target`, recording its traps and undefined behaviour at this point of the block.
    func call(_ target: String, _ arguments: [BV], at id: String?, when condition: Int32? = nil) throws -> EncodedFunction {
        let result = try encoder.encodeCall(target, arguments, stack: stack + [function.symbol])
        let at = condition.map { c.and(live, $0) } ?? live
        let site = TrapKind.call(id: id, callee: target, inner: result.trapSites)
        out.traps.append(TrapEvent(block: blockIndex, condition: c.and(at, result.trap), site: site))
        live = c.and(live, -c.and(at, result.trap))
        undefined(condition.map { c.and($0, result.undefined) } ?? result.undefined)
        out.approximations.formUnion(result.approximations)
        return result
    }

    /// Stores what a callee wrote through its `@out` and `@inout` arguments into this function's slots.
    func writeBack(_ values: [BV], names: [String], conventions: [ParameterConvention]) throws {
        var offset = 0
        for (name, convention) in zip(names, conventions) where convention == .out || convention == .inout {
            let reference = try slot(name)

            let (slotID, leaf, type) = (reference.id, reference.leaf, reference.type)
            let widths = type.leafWidths
            guard offset + widths.count <= values.count,
                values[offset..<(offset + widths.count)].map(\.width) == widths
            else {
                throw SILError.invalid("written-back value does not match \(name) in \(function.symbol)")
            }
            for i in 0..<widths.count { cells["\(slotID)#\(leaf + i)"] = values[offset + i] }
            offset += widths.count
        }
        guard offset == values.count else { throw SILError.invalid("written-back values left over in \(function.symbol)") }
    }

    /// What a `return` gives back; for an object, its fields and whether it is this function's class parameter.
    func returnedValue(_ id: String) throws -> ([BV], Bool) {
        guard function.returnsObject else { return (try flat(id), false) }
        guard case .address(.slot(let slot, 0, let type)) = try lookup(id), type == function.resultType else {
            throw SILError.unsupported("a returned object Scan does not track in \(function.symbol)")
        }
        let offset = function.indirectResult == nil ? 0 : 1
        let parameter = function.objectParameter.map { function.blocks[0].parameters[$0 + offset].id }
        return (try slotValue(id).leaves, slot == parameter)
    }

    /// The value of a call's result: an object is the argument the callee returned, or a new slot (L5).
    func callResult(
        _ callee: String, _ id: String, _ type: ValueType, _ result: EncodedFunction, _ names: [String]
    ) throws -> Value {
        let target = try module.function(callee)
        guard target.returnsObject else { return make(type, result.results) }
        guard !result.objectResultIsParameter else {
            guard let k = target.objectParameter else { throw SILError.invalid("\(callee) returns a parameter it has not") }
            return try lookup(names[k + (target.indirectResult == nil ? 0 : 1)])
        }
        for (i, leaf) in result.results.enumerated() { cells["\(id)#\(i)"] = leaf }
        return .address(.slot(id: id, leaf: 0, type: type))
    }

    /// `Optional.map` / `flatMap` with a closure literal (`SILOptionalMap.swift`): `(@out B?, @error_indirect Never,
    /// closure, @in_guaranteed A?)`.
    func optionalTransform(_ transform: OptionalTransform, _ request: TryApply) throws {
        guard request.substitutions.count == 3, request.substitutions[1] == "Never", request.arguments.count == 4,
            request.conventions == [.out, .out, .value, .indirect]
        else { throw SILError.unsupported("Optional.\(transform) with a closure that can throw") }
        guard let closure = closureLiterals[request.arguments[2]], case .function(let symbol) = try lookup(closure.callee) else {
            throw SILError.unsupported("Optional.\(transform) with a closure that is not a literal of \(function.symbol)")
        }
        let (optional, value) = try slotValue(request.arguments[3])
        let result = try slot(request.arguments[0])
        guard case .enumeration(_, let cases) = optional, cases.count == 2, let resultPayload = result.type.payloadOfSome
        else { throw SILError.invalid("Optional.\(transform): operands at \(function.symbol)") }
        let isSome = c.eq(value[0], c.constant(1, width: value[0].width))
        let key = SILModule.closureKey(symbol)
        let body = try module.function(key)
        var arguments = Array(value[optional.payloadLeafRange(ofCase: 1)])
        for (capture, convention) in zip(closure.captures, body.conventions.dropFirst()) {
            guard convention == .value else { throw SILError.unsupported("a closure that captures a variable (\(capture))") }
            arguments += try flat(capture)
        }
        let encoded = try call(key, arguments, at: nil, when: isSome)
        let produced = transform == .map ? resultPayload : result.type
        guard encoded.writtenBack.map(\.width) == produced.leafWidths, cases[1].payload != nil else {
            throw SILError.invalid("Optional.\(transform): the closure's result at \(function.symbol)")
        }
        let some = transform == .map ? encoder.enumLeaves(result.type, case: 1, payload: encoded.writtenBack) : encoded.writtenBack
        let none = encoder.enumLeaves(result.type, case: 0, payload: [])
        for (i, (s, n)) in zip(some, none).enumerated() { cells["\(result.id)#\(result.leaf + i)"] = c.select(isSome, s, n) }
        let normalTakesValue = cfg.index[request.normal].map { !function.blocks[$0].parameters.isEmpty } ?? false
        try edge(to: request.normal, parameters: normalTakesValue ? [[]] : [], when: live)
    }

    /// A call to a throwing function: the normal block gets its result when it does not throw, the error block
    /// its error when it does. Write-backs through `inout` are refused: on a throw they are not modelled.
    func tryApply(_ request: TryApply) throws {
        if case .function(let target) = try lookup(request.callee), let transform = OptionalTransform.symbols[target] {
            return try optionalTransform(transform, request)
        }
        if case .function(let target) = try lookup(request.callee), let operation = CollectionOperation.symbols[target] {
            return try collectionCall(operation, request)
        }
        guard case .function(let target) = try lookup(request.callee), request.substitutions.isEmpty,
            StdlibSummary.table[target] == nil
        else { throw SILError.unsupported("try_apply of \(request.callee) (generic, indirect or a standard-library call)") }
        guard request.conventions.allSatisfy({ $0 == .value || $0 == .indirect }) else {
            throw SILError.unsupported("try_apply of \(target) with inout or @out arguments")
        }
        var arguments: [BV] = []
        for (name, convention) in zip(request.arguments, request.conventions) {
            arguments += convention == .value ? try flat(name) : try slotValue(name).leaves
        }
        let result = try call(target, arguments, at: nil)
        let throwing = result.throwing ?? c.falseLit
        let normalTakesValue = cfg.index[request.normal].map { !function.blocks[$0].parameters.isEmpty } ?? false
        try edge(to: request.normal, parameters: normalTakesValue ? [result.results] : [], when: c.and(live, -throwing))
        try edge(to: request.error, parameters: [result.error], when: c.and(live, throwing))
    }

    func edge(_ e: Edge, when condition: Int32) throws {
        try edge(to: e.block, parameters: try e.arguments.map(flat), when: condition)
    }

    func edge(to block: String, parameters: [[BV]], when condition: Int32) throws {
        guard let target = cfg.index[block], function.blocks[target].parameters.count == parameters.count else {
            throw SILError.invalid("bad branch target \(block) in \(function.symbol)")
        }
        guard zip(parameters, function.blocks[target].parameters).allSatisfy({ $0.map(\.width) == $1.type.leafWidths }) else {
            throw SILError.invalid("branch argument types do not match \(block) in \(function.symbol)")
        }
        let isBack = cfg.backEdges.contains(BlockEdge(from: blockIndex, to: target))
        if cfg.isHeader[target] {
            out.arrivals.append(
                Arrival(
                    source: blockIndex, target: target, isBackEdge: isBack, condition: condition,
                    parameters: parameters, cells: cells))
        }
        if !isBack && (!cfg.isHeader[target] || assumed.contains(target)) {
            incoming[target, default: []].append(Incoming(condition: condition, parameters: parameters, cells: cells))
        }
    }

    /// Records the edges the current block's terminator takes, its return or its throw.
    func terminate() throws {
        switch block.terminator {
        case .branch(let e): try edge(e, when: live)
        case .conditional(let condition, let yes, let no):
            let v = try scalar(condition)
            guard v.width == 1 else { throw SILError.invalid("cond_br on non-Int1 \(condition)") }
            try edge(yes, when: c.and(live, v.bits[0]))
            try edge(no, when: c.and(live, -v.bits[0]))
        case .returned(let id): try encodeReturn(id)
        case .trap: break
        case .thrown(let id):
            let error = try flat(id)
            guard let errorType = function.errorType, error.map(\.width) == errorType.leafWidths else {
                throw SILError.invalid("throw of the wrong type in \(function.symbol)")
            }
            out.throwsEvents.append((live, error))
        case .tryApply(let request):
            try tryApply(request)
        case .switchEnum(let subject, let isAddress, let cases, let fallback): try switchEnum(subject, isAddress, cases, fallback)
        }
    }

    /// The leaves a call passes: values, and the contents of `inout` and `@in` addresses.
    func callArguments(_ names: [String], _ conventions: [ParameterConvention]) throws -> [BV] {
        var arguments: [BV] = []
        for (name, convention) in zip(names, conventions) {
            switch convention {
            case .value: arguments += try flat(name)
            case .inout, .indirect: arguments += try slotValue(name).leaves
            case .out: break
            }
        }
        return arguments
    }

    /// A `return`: its value, and the `@out` and `@inout` values the caller gets back.
    func encodeReturn(_ id: String) throws {
        let (l, objectIsParameter) = try returnedValue(id)
        guard l.map(\.width) == function.resultWidths else { throw SILError.invalid("return type mismatch in \(function.symbol)") }
        var writtenBack: [BV] = []
        let entryConventions = (function.indirectResult == nil ? [] : [ParameterConvention.out]) + function.conventions
        for (parameter, convention) in zip(function.blocks[0].parameters, entryConventions)
        where convention == .out || convention == .inout {
            for i in 0..<parameter.type.leafWidths.count {
                guard let v = cells["\(parameter.id)#\(i)"] else {
                    throw SILError.unsupported("\(function.symbol) may return without writing its result")
                }
                writtenBack.append(v)
            }
        }
        out.returns.append(
            ReturnEvent(
                block: blockIndex, condition: live, leaves: l, writtenBack: writtenBack, objectIsParameter: objectIsParameter,
                cells: cells))
    }

    /// A `switch_enum`: an edge per case, under its tag, with the payload for a target that takes one.
    func switchEnum(_ subject: String, _ isAddress: Bool, _ cases: [EnumTarget], _ fallback: String?) throws {
        let (type, l) = isAddress ? try slotValue(subject) : try enumValue(subject)
        let conditions = try encoder.caseConditions(tag: l[0], type: type, listed: cases, hasDefault: fallback != nil)
        for (target, condition) in zip(cases, conditions) {
            let (k, payloadType) = try type.enumCase(named: target.caseName)
            var parameters: [[BV]] = []
            if let index = cfg.index[target.target], !function.blocks[index].parameters.isEmpty {
                guard !isAddress, payloadType != nil else {
                    throw SILError.invalid("switch_enum target \(target.target) takes a parameter but gets no payload")
                }
                parameters = [Array(l[type.payloadLeafRange(ofCase: k)])]
            }
            try edge(to: target.target, parameters: parameters, when: c.and(live, condition))
        }
        if let fallback, let condition = conditions.last {
            let takesValue = cfg.index[fallback].map { !function.blocks[$0].parameters.isEmpty } ?? false
            try edge(to: fallback, parameters: takesValue && !isAddress ? [l] : [], when: c.and(live, condition))
        }
    }
}
