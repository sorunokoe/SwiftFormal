package import SFBV
import SFCNF
import SFSemantics

// Reading guide
// One encoding of one function (`SILEncoder.run`): the values of its SSA names, its stack cells, and the events the
// encoder reads afterwards (traps, arrivals at loop headers, returns). `run` visits the blocks in topological order of
// the graph without back edges; each block is entered from the merged state of the edges that reach it (`enter`), its
// instructions are encoded one at a time (`execute`) and its terminator records the edges it takes (`terminate`).
// A call that is inlined runs a `FunctionRun` of its own, through `SILEncoder.encodeCall`. Plan item H1: this was a
// single function of 1,200 lines with its helpers nested inside; the order in which gates are made is unchanged
// (CNFHashTests, CNFFeatureHashTests and CNFFixtureHashTests pin it byte for byte).

/// The state of one run of `SILEncoder.run` over one function.
final class FunctionRun {
    // What the run reads: the encoder (for the module-wide state and the calls it inlines) and the function.
    let encoder: SILEncoder
    let c: CNFBuilder
    let module: SILModule
    let function: SILFunction
    let cfg: CFG
    let arguments: [BV]
    /// The loop headers that are cutpoints (see `SILEncoder.run`).
    let assumed: Set<Int>
    /// The functions being inlined around this one, outermost first.
    let stack: [String]
    /// This function's frame in the encoder's error trail.
    let depth: Int

    /// The value of each SSA name encoded so far.
    var env: [String: Value] = [:]
    /// Values that are a `keypath` literal of this function (checked to capture nothing), or a cast of one.
    var literalKeyPaths: Set<String> = []
    /// The texts of this function's `string_literal` pointers, for the string-literal summary.
    var stringTexts: [String: String] = [:]
    /// Array literals under construction by count, the literal and index of each element slot, and the literals
    /// whose elements stay unknown or that were finalized (`SILArrayLiterals.swift`).
    var literals: [[Int32]: LiteralArray] = [:]
    var literalSlots: [String: (literal: LiteralArray, index: Int)] = [:]
    var unknownLiterals: Set<String> = [], finalizedLiterals: Set<String> = []
    /// The callee and captures of each closure made in this function (`SILOptionalMap.swift`).
    var closureLiterals: [String: (callee: String, captures: [String])] = [:]
    /// The edges taken so far into each block not yet encoded.
    var incoming: [Int: [Incoming]] = [:]
    /// What the encoder reads once every block is encoded.
    var out = RunOutput()

    // The block being encoded, its stack cells, and `live`: it is reached and no earlier cond_fail or callee trap has
    // stopped execution.
    var blockIndex = 0
    var cells: [String: BV] = [:]
    var live: Int32 = 0
    var block: Block { function.blocks[blockIndex] }

    init(encoder: SILEncoder, function: SILFunction, cfg: CFG, arguments: [BV], assumed: Set<Int>, stack: [String]) {
        (self.encoder, c, module) = (encoder, encoder.c, encoder.module)
        (self.function, self.cfg, self.arguments, self.assumed, self.stack) = (function, cfg, arguments, assumed, stack)
        depth = encoder.enterTrail(function.symbol)
    }

    struct ArrayObject {
        let id: String
        let width: Int
        let count: Int
        /// Constant contents of an immutable array literal; nil for a stack array (its elements live in cells).
        let table: [UInt64]?
    }

    indirect enum Address {
        case slot(id: String, leaf: Int, type: ValueType)
        case element(ArrayObject, index: BV)
        case header
        /// An element of an array under construction (`ValueType.array` does not model elements): stores are dropped.
        case sink
    }

    enum Value {
        case scalar(BV)
        case aggregate(ValueType, [BV])
        case function(String)
        case address(Address)
        case array(ArrayObject)
        /// The uniqueness flag of `begin_cow_mutation`: its value is not modelled and any use is rejected.
        case opaque
        /// The element storage of a `ValueType.array` value (see `Address.sink`).
        case sink
        /// The element storage of an array literal under construction (`SILArrayLiterals.swift`).
        case literalStorage(LiteralArray)
    }

    /// An edge into a block: when it is taken, and the parameters and cells it brings.
    struct Incoming {
        let condition: Int32
        let parameters: [[BV]]
        let cells: [String: BV]
    }
}

extension FunctionRun {
    /// See `SILEncoder.run`.
    func run(makeState: (Int, [(key: String, width: Int)]) throws -> HeaderState) throws -> RunOutput {
        for assumption in function.assumptions { Assumptions.note(assumption) }
        for blockIndex in cfg.forwardOrder {
            self.blockIndex = blockIndex
            cells = [:]
            guard let reach = try enter(makeState: makeState) else { continue }

            if case .trap = block.terminator {
                out.traps.append(TrapEvent(block: blockIndex, condition: reach, site: .unreachable(block: block.id)))
                continue
            }

            live = reach
            for instruction in block.instructions {
                encoder.moveTrail(depth, to: instruction)
                try execute(instruction)
            }
            encoder.moveTrail(depth, to: nil)
            try terminate()
        }
        encoder.leaveTrail(depth)
        if let observeValues = encoder.observeValues { for (id, value) in env { observeValues(function.symbol, id, valueType(value)) } }
        return out
    }

    /// Enters the current block: binds its parameters and sets its cells. Returns when it is reached, or nil when
    /// it is not entered.
    func enter(makeState: (Int, [(key: String, width: Int)]) throws -> HeaderState) throws -> Int32? {
        var reach: Int32
        var parameterLeaves: [[BV]]
        if blockIndex == 0 {
            reach = c.trueLit
            parameterLeaves = entryParameters()
        } else {
            if cfg.isHeader[blockIndex] && !assumed.contains(blockIndex) { return nil }
            let edges = incoming[blockIndex] ?? []
            if edges.isEmpty && !assumed.contains(blockIndex) { return nil }
            // A cutpoint is entered with a free state and counts as reached: the invariant is the assumption.
            let cutpoint = assumed.contains(blockIndex) && cfg.isHeader[blockIndex]
            reach = cutpoint ? c.trueLit : edges.dropFirst().reduce(edges.first?.condition ?? c.falseLit) { c.or($0, $1.condition) }
            if cutpoint {
                let state = try enterCutpoint(edges, makeState: makeState)
                if let arrived = state.reach { reach = arrived }
                parameterLeaves = state.parameters
            } else {
                guard !edges.isEmpty else { return nil }
                parameterLeaves = merge(edges)
            }
        }
        try bindParameters(parameterLeaves)
        return reach
    }

    /// The parameters of the entry block: the arguments, and nothing yet for the `@out` result address.
    func entryParameters() -> [[BV]] {
        var offset = 0
        var parameterLeaves: [[BV]] = []
        for (k, parameter) in block.parameters.enumerated() {
            // The `@out` result address starts uninitialized: the function writes it before returning.
            if k == 0 && function.indirectResult != nil {
                parameterLeaves.append([])
                continue
            }
            let n = parameter.type.leafWidths.count
            parameterLeaves.append(Array(arguments[offset..<(offset + n)]))
            offset += n
        }
        return parameterLeaves
    }

    /// Enters a loop header that is a cutpoint with the fresh state `makeState` gives it (the cells every edge
    /// brings, at their widths), and records that state and the condition under which an edge enters.
    func enterCutpoint(
        _ edges: [Incoming], makeState: (Int, [(key: String, width: Int)]) throws -> HeaderState
    ) throws -> HeaderState {
        var common: [(key: String, width: Int)] = []
        if let first = edges.first {
            for key in first.cells.keys.sorted() where edges.allSatisfy({ $0.cells[key]?.width == first.cells[key]!.width }) {
                common.append((key, first.cells[key]!.width))
            }
        }
        let state = try makeState(blockIndex, common)
        guard state.parameters.map({ $0.map(\.width) }) == block.parameters.map({ $0.type.leafWidths }) else {
            throw SILError.invalid("fresh state of \(block.id) does not match its parameters")
        }
        out.states[blockIndex] = state
        if !edges.isEmpty {
            out.entryConditions[blockIndex] = edges.dropFirst().reduce(edges[0].condition) { c.or($0, $1.condition) }
        }
        cells = state.cells
        return state
    }

    /// The block's parameters and cells from the edges that reach it: each selected by the condition of its edge.
    func merge(_ edges: [Incoming]) -> [[BV]] {
        var parameterLeaves: [[BV]] = []
        for (index, parameter) in block.parameters.enumerated() {
            let count = parameter.type.leafWidths.count
            var merged: [BV] = []
            for leaf in 0..<count {
                var value = edges[edges.count - 1].parameters[index][leaf]
                for edge in edges.dropLast().reversed() {
                    value = c.select(edge.condition, edge.parameters[index][leaf], value)
                }
                merged.append(value)
            }
            parameterLeaves.append(merged)
        }
        // Sorted: dictionary order differs between runs, and the order gates are made in is the CNF's numbering.
        for key in edges[0].cells.keys.sorted() where edges.allSatisfy({ $0.cells[key] != nil }) {
            var value = edges[edges.count - 1].cells[key]!
            for edge in edges.dropLast().reversed() { value = c.select(edge.condition, edge.cells[key]!, value) }
            cells[key] = value
        }
        return parameterLeaves
    }

    /// Binds the block's parameters to these leaves: an address parameter is a stack slot holding them.
    func bindParameters(_ parameterLeaves: [[BV]]) throws {
        for (k, (parameter, leaves)) in zip(block.parameters, parameterLeaves).enumerated() {
            let isOut = blockIndex == 0 && k == 0 && function.indirectResult != nil
            guard isOut || leaves.map(\.width) == parameter.type.leafWidths else {
                throw SILError.invalid("parameter width mismatch in \(block.id)")
            }
            if parameter.isAddress {
                // An address parameter is a stack slot of this function holding the caller's value.
                env[parameter.id] = .address(.slot(id: parameter.id, leaf: 0, type: parameter.type))
                for (i, leaf) in leaves.enumerated() { cells["\(parameter.id)#\(i)"] = leaf }
            } else {
                env[parameter.id] = make(parameter.type, leaves)
            }
        }
    }

    /// Encodes one instruction of the current block.
    func execute(_ instruction: Instruction) throws {
        switch instruction {
        case .ignored: break
        case .stringLiteral(let id, let text): encodeStringLiteral(id, text)
        case .globalAddress(let id, let symbol, let type): try encodeGlobalAddress(id, symbol, type)
        case .pointerToAddress(let id, let source, let type): try encodePointerToAddress(id, source, type)
        case .enumTag(let id, let operand): try encodeEnumTag(id, operand)
        case .literal(let id, let width, let value): env[id] = .scalar(c.constant(value, width: width))
        case .retype(let id, let source, let width): try encodeRetype(id, source, width)
        case .builtin(let id, let op, let names): try encodeBuiltin(id, op, names)
        case .existentialBox, .existentialAddress: try encodeExistential(instruction)
        case .boxedValueAddress(let id): env[id] = .address(.sink)
        case .floatBuiltin(let id, let op, let names): try encodeFloatBuiltin(id, op, names)
        case .makeAggregate(let id, let type, let names): try encodeMakeAggregate(id, type, names)
        case .extract(let id, let source, let field, let expected): try encodeExtract(id, source, field, expected)
        case .condFail(let id): try encodeCondFail(id)
        case .functionRef(let id, let symbol): env[id] = .function(symbol)
        case .apply(let id, let callee, let names, let type, let substitutions, let conventions):
            try encodeApply(
                callee, SummarizedCall(id: id, names: names, type: type, substitutions: substitutions, conventions: conventions))
        case .allocStack(let id, let type): env[id] = .address(.slot(id: id, leaf: 0, type: type))
        case .allocObject(let id, let type): encodeAllocObject(id, type)
        case .store(let valueID, let address): try encodeStore(valueID, address)
        case .load(let id, let address): try encodeLoad(id, address)
        case .elementAddress(let id, let base, let field, let expected): try encodeElementAddress(id, base, field, expected)
        case .alias(let id, let source): try encodeAlias(id, source)
        case .closure(let id, let type, let callee, let captures): encodeClosure(id, type, callee, captures)
        case .beginCOW(let flag, let buffer, let source): try encodeBeginCOW(flag, buffer, source)
        case .allocArray(let id, let width, let countName): try encodeAllocArray(id, width, countName)
        case .globalValue(let id, let symbol): try encodeGlobalValue(id, symbol)
        case .refTailAddress(let id, let source, let width): try encodeRefTailAddress(id, source, width)
        case .indexAddress(let id, let base, let index): try encodeIndexAddress(id, base, index)
        case .headerAddress(let id): env[id] = .address(.header)
        case .arrayStorage(let id, let source): try encodeArrayStorage(id, source)
        case .beginApply(let address, let callee, let names, let substitutions, let conventions):
            try encodeBeginApply(address, callee, names, substitutions, conventions)
        case .makeEnum(let id, let type, let caseName, let payloadID): try encodeMakeEnum(id, type, caseName, payloadID)
        case .enumPayload(let id, let source, let caseName): try encodeEnumPayload(id, source, caseName)
        case .selectEnum(let id, let source, let isAddress, let cases, let fallback):
            try encodeSelectEnum(id, source, isAddress, cases, fallback)
        case .enumPayloadAddress(let id, let base, let caseName, let checksCase):
            try encodeEnumPayloadAddress(id, base, caseName, checksCase)
        case .injectEnum(let address, let caseName): try encodeInjectEnum(address, caseName)
        case .copyAddress(let source, let destination): try encodeCopyAddress(source, destination)
        }
    }

    func lookup(_ id: String) throws -> Value {
        guard let v = env[id] else { throw SILError.invalid("\(id) has no usable value in \(function.symbol)") }
        return v
    }

    func scalar(_ id: String) throws -> BV {
        guard case .scalar(let v) = try lookup(id) else { throw SILError.invalid("\(id) is not a scalar value in \(function.symbol)") }
        return v
    }

    func flat(_ id: String) throws -> [BV] {
        guard let l = leaves(try lookup(id)) else { throw SILError.invalid("\(id) is not a value in \(function.symbol)") }
        return l
    }

    func enumValue(_ id: String) throws -> (type: ValueType, leaves: [BV]) {
        guard case .aggregate(let type, let l) = try lookup(id), case .enumeration = type else {
            throw SILError.invalid("\(id) is not an enum value in \(function.symbol)")
        }
        return (type, l)
    }

    func fresh(_ type: ValueType) -> [BV] { encoder.fresh(type) }

    func undefined(_ condition: Int32) { out.undefineds.append(TrapEvent(block: blockIndex, condition: c.and(live, condition))) }

    func slot(_ address: String) throws -> SlotReference {
        guard case .address(.slot(let id, let leaf, let type)) = try lookup(address) else {
            throw SILError.unsupported("\(address) is not the address of a tracked stack slot")
        }
        return SlotReference(id: id, leaf: leaf, type: type)
    }

    func slotValue(_ address: String) throws -> (type: ValueType, leaves: [BV]) {
        let reference = try slot(address)

        let (id, leaf, type) = (reference.id, reference.leaf, reference.type)
        var l: [BV] = []
        for i in 0..<type.leafWidths.count {
            guard let v = cells["\(id)#\(leaf + i)"] else {
                throw SILError.unsupported("load of \(address): not a tracked, initialized stack slot")
            }
            l.append(v)
        }
        return (type, l)
    }

    func unknown(_ type: ValueType) -> [BV] { fresh(type) }

    func trap(_ condition: Int32, site: TrapKind) {
        out.traps.append(TrapEvent(block: blockIndex, condition: c.and(live, condition), site: site))
        live = c.and(live, -condition)
    }

}

/// A tracked stack slot address: the slot, the first leaf it points at, and the type stored there.
struct SlotReference {
    let id: String
    let leaf: Int
    let type: ValueType
}

/// A summarized `Array` call: its name in reports and its operands.
struct ArrayCall {
    let name: String
    let request: SummarizedCall

    /// Where a trap inside the call is reported, with its message.
    func site(_ message: String) -> TrapKind { .stdlib(id: request.id, message: message) }

    func argument(_ k: Int) throws -> (name: String, convention: ParameterConvention) {
        guard request.names.indices.contains(k), request.conventions.indices.contains(k) else {
            throw SILError.invalid("\(name) without argument \(k) at \(request.id)")
        }
        return (request.names[k], request.conventions[k])
    }
}
