package import SFBV
import SFCNF

/// The meaning of one LLVM IR function as circuits.
package struct LLVMEncodedFunction {
    package let result: BV
    /// True exactly when the function traps (`llvm.trap`, or a call into a standard-library failure function).
    package let trap: Int32
    /// True when execution reaches immediate undefined behaviour, or poison reaches a place where it matters
    /// (a returned value, a branch condition, a division operand, an `llvm.assume`). Conservative: poison that
    /// is never used does not count, but poison that might be used does.
    package let undefined: Int32
}

/// Turns a loop-free LLVM IR function into circuits.
///
/// Every SSA value is a pair of a bit vector and a *poison* literal. Operations propagate poison, `select` and
/// `phi` multiplex it, and it becomes `undefined` where LLVM makes it matter. Control flow becomes reachability
/// literals. `live` is "reached and no trap has happened yet": undefined behaviour that sits behind a failed
/// guard (a `sdiv` after the zero check) is masked by it, exactly because the guard traps first.
/// The semantics of each instruction are written from the LLVM Language Reference, independently of the SIL encoder.
///
/// Memory is byte-addressed and little-endian, as the IR's own type definitions lay it out (`LLVMMemory.swift`). Only
/// memory the encoder can name is followed: stack slots (`alloca`) and the regions the caller hands in (a by-reference
/// argument or an `sret` result, `LLVMBridge.swift`). A pointer that comes from anywhere else is an opaque 64-bit value:
/// it can be moved, stored and passed to the reference-counting runtime, never dereferenced. Reading a byte nobody
/// wrote is refused (`unsupported`), not guessed.
package final class LLVMEncoder {
    package let module: LLVMModule
    private let c: CNFBuilder
    private let maxDepth: Int

    package init(module: LLVMModule, builder: CNFBuilder, maxCallDepth: Int = 8) {
        self.module = module
        self.c = builder
        self.maxDepth = maxCallDepth
    }

    struct Val {
        var bits: BV
        var poison: Int32
        var width: Int { bits.width }
    }

    /// An SSA value: an integer or opaque pointer (`scalar`), an aggregate, or the address of a byte in a region the
    /// encoder follows.
    indirect enum Value {
        case scalar(Val)
        case aggregate([Value])
        case address(region: Int, offset: Int)
    }

    struct ByteKey: Hashable {
        let region: Int
        let offset: Int
    }

    /// The bytes written so far, each an 8-bit value with its own poison. A byte that is absent was never written.
    typealias Memory = [ByteKey: Val]

    struct Region {
        let size: Int
        let writable: Bool
    }

    /// Every region of this encoding: stack slots of every inlined call, and those `addRegion` created.
    private(set) var regions: [Region] = []

    /// What one call of a function does.
    struct Outcome {
        /// Nil for a function that returns `void`.
        let result: Value?
        let trap: Int32
        let undefined: Int32
        /// True when the function returns (it neither traps nor stops at undefined behaviour first).
        let returned: Int32
        /// Memory when it returns.
        let memory: Memory
    }

    private struct Incoming {
        let predecessor: String
        let condition: Int32
        let memory: Memory
    }

    /// A new region of `size` bytes, nothing written yet. `writable: false` refuses stores into it.
    func addRegion(size: Int, writable: Bool) -> Int {
        regions.append(Region(size: size, writable: writable))
        return regions.count - 1
    }

    /// Encodes a function whose parameters are integers or opaque pointers, from one bit vector per parameter. Its
    /// result must be an integer or a pointer; returning poison counts as undefined behaviour.
    package func encode(symbol: String, arguments: [BV]) throws -> LLVMEncodedFunction {
        let function = try module.function(symbol)
        guard arguments.map(\.width) == function.parameterWidths else {
            throw LLVMError.invalid("argument widths do not match \(symbol)")
        }
        guard isValueType(function.returnType) else {
            throw LLVMError.unsupported("result type \(function.returnType.description) of \(symbol): not one value")
        }
        let outcome = try encode(
            symbol: symbol, arguments: arguments.map { .scalar(Val(bits: $0, poison: c.falseLit)) }, memory: [:], stack: [])
        guard case .scalar(let v)? = outcome.result else {
            throw LLVMError.unsupported("\(symbol) returns an address this reader follows")
        }
        return LLVMEncodedFunction(
            result: v.bits, trap: outcome.trap, undefined: c.or(outcome.undefined, c.and(outcome.returned, v.poison)))
    }

    private func mask(_ width: Int) -> UInt64 { width == 64 ? ~0 : (1 << UInt64(width)) - 1 }

    // MARK: values

    /// The value of `type` that is poison everywhere (`undef` and `poison` operands).
    private func poisonValue(_ type: LType, depth: Int = 0) throws -> Value {
        guard depth < 32 else { throw LLVMError.unsupported("aggregate nesting too deep") }
        switch try module.resolved(type) {
        case .int(let n) where n >= 1 && n <= 64: return .scalar(Val(bits: c.constant(0, width: n), poison: c.trueLit))
        case .ptr: return .scalar(Val(bits: c.constant(0, width: 64), poison: c.trueLit))
        case .tuple(let fields), .packed(let fields): return .aggregate(try fields.map { try poisonValue($0, depth: depth + 1) })
        case .array(let n, let element) where n <= 256:
            return .aggregate(try (0..<n).map { _ in try poisonValue(element, depth: depth + 1) })
        case let t: throw LLVMError.unsupported("value of type \(t.description)")
        }
    }

    /// The value of `type` with every bit zero (`zeroinitializer`).
    private func zeroValue(_ type: LType) throws -> Value {
        func clear(_ v: Value) -> Value {
            switch v {
            case .scalar(let s): .scalar(Val(bits: c.constant(0, width: s.width), poison: c.falseLit))
            case .aggregate(let elements): .aggregate(elements.map(clear))
            case .address: v
            }
        }
        return clear(try poisonValue(type))
    }

    /// Chooses `a` where `condition` holds, `b` elsewhere. Two different addresses cannot be chosen between.
    func merge(_ condition: Int32, _ a: Value, _ b: Value) throws -> Value {
        switch (a, b) {
        case (.scalar(let x), .scalar(let y)) where x.width == y.width:
            return .scalar(Val(bits: c.select(condition, x.bits, y.bits), poison: c.mux(condition, x.poison, y.poison)))
        case (.aggregate(let xs), .aggregate(let ys)) where xs.count == ys.count:
            return .aggregate(try zip(xs, ys).map { try merge(condition, $0, $1) })
        case (.address(let r1, let o1), .address(let r2, let o2)):
            if condition == c.trueLit { return a }
            if condition == c.falseLit { return b }
            guard r1 == r2, o1 == o2 else { throw LLVMError.unsupported("a pointer that points to different places on different paths") }
            return a
        default:
            throw LLVMError.invalid("merging values of different shapes")
        }
    }

    /// The memory where `condition` holds from `a`, elsewhere from `b`; a byte written in only one of them is dropped.
    private func merge(_ condition: Int32, _ a: Memory, _ b: Memory) -> Memory {
        if condition == c.trueLit { return a }
        if condition == c.falseLit { return b }
        var out: Memory = [:]
        for (key, x) in a {
            guard let y = b[key] else { continue }
            out[key] = Val(bits: c.select(condition, x.bits, y.bits), poison: c.mux(condition, x.poison, y.poison))
        }
        return out
    }

    /// Bytes of a stored value, least significant first.
    private func bytes(of value: Val, type: LType) throws -> [Val] {
        let n = try module.storeSize(type)
        guard value.width == (n == 1 && type == .int(1) ? 1 : n * 8) else { throw LLVMError.invalid("store of a value of the wrong width") }
        if type == .int(1) {
            return [Val(bits: c.zeroExtend(value.bits, to: 8), poison: value.poison)]
        }
        return (0..<n).map { k in Val(bits: BV(bits: Array(value.bits.bits[(k * 8)..<(k * 8 + 8)])), poison: value.poison) }
    }

    /// The value of `type` made of `bytes`, least significant first. An `i1` is bit 0 of its byte; other bits set make it poison.
    private func value(from bytes: [Val], type: LType) -> Val {
        let poison = bytes.dropFirst().reduce(bytes[0].poison) { c.or($0, $1.poison) }
        if type == .int(1) {
            let high = bytes[0].bits.bits.dropFirst().reduce(c.falseLit) { c.or($0, $1) }
            return Val(bits: BV(bits: [bytes[0].bits.bits[0]]), poison: c.or(poison, high))
        }
        return Val(bits: BV(bits: bytes.flatMap(\.bits.bits)), poison: poison)
    }

    /// The region and the in-bounds byte range `[offset, offset + size)` an access through `address` touches.
    private func access(_ address: Value?, size: Int, writing: Bool, in symbol: String) throws -> (region: Int, offset: Int) {
        guard case .address(let region, let offset)? = address, regions.indices.contains(region) else {
            throw LLVMError.unsupported("memory access through a pointer this reader does not follow in \(symbol)")
        }
        guard offset >= 0, size >= 0, offset + size <= regions[region].size else {
            throw LLVMError.unsupported("memory access outside its region in \(symbol)")
        }
        if writing, !regions[region].writable { throw LLVMError.unsupported("store into a read-only argument in \(symbol)") }
        return (region, offset)
    }

    /// The value of a `ptr` operand: an opaque 64-bit value, or an address the encoder follows.
    private func pointer(_ operand: Operand, _ env: [String: Value], in symbol: String) throws -> Value {
        switch operand {
        case .local(let name):
            switch env[name] {
            case .scalar(let v)? where v.width == 64: return .scalar(v)
            case .address(let r, let o)?: return .address(region: r, offset: o)
            default: throw LLVMError.invalid("%\(name) is not a pointer in \(symbol)")
            }
        case .null, .zero: return .scalar(Val(bits: c.constant(0, width: 64), poison: c.falseLit))
        case .poison: return .scalar(Val(bits: c.constant(0, width: 64), poison: c.trueLit))
        case .global(let name): throw LLVMError.unsupported("global @\(name) in \(symbol)")
        case .constant: throw LLVMError.invalid("integer used as a pointer in \(symbol)")
        }
    }

    /// The value of an aggregate operand: a local, `undef`/`poison` or `zeroinitializer`.
    private func aggregate(_ operand: Operand, _ type: LType, _ env: [String: Value], in symbol: String) throws -> Value {
        switch operand {
        case .local(let name):
            guard case .aggregate? = env[name], let v = env[name] else {
                throw LLVMError.invalid("%\(name) is not an aggregate in \(symbol)")
            }
            return v
        case .poison: return try poisonValue(type)
        case .zero: return try zeroValue(type)
        default: throw LLVMError.unsupported("aggregate constant in \(symbol)")
        }
    }

    /// One `ret` reached: when, what, and the memory then.
    private struct Return {
        let condition: Int32
        let value: Value?
        let memory: Memory
    }

    // MARK: functions

    func encode(symbol: String, arguments: [Value], memory initial: Memory, stack: [String]) throws -> Outcome {
        guard !stack.contains(symbol) else { throw LLVMError.unsupported("recursion through \(symbol)") }
        guard stack.count < maxDepth else { throw LLVMError.unsupported("call depth above \(maxDepth) at \(symbol)") }
        let function = try module.function(symbol)
        guard arguments.count == function.parameters.count else { throw LLVMError.invalid("argument count does not match \(symbol)") }
        let order = try topologicalOrder(function)
        // Labels are unique here: `topologicalOrder` rejects a repeated one.
        let blockIndex = Dictionary(function.blocks.enumerated().map { ($1.id, $0) }, uniquingKeysWith: { first, _ in first })

        var env: [String: Value] = [:]
        var incoming: [String: [Incoming]] = [:]
        var trap = c.falseLit
        var undefined = c.falseLit
        var returns: [Return] = []
        for (parameter, value) in zip(function.parameters, arguments) {
            switch (parameter.type, value) {
            case (.int(let n), .scalar(let v)) where v.width == n: break
            case (.ptr, .scalar(let v)) where v.width == 64: break
            case (.ptr, .address): break
            default: throw LLVMError.invalid("argument %\(parameter.name) of \(symbol) does not match its type")
            }
            env[parameter.name] = value
        }

        func scalar(_ operand: Operand, width: Int) throws -> Val {
            switch operand {
            case .local(let name):
                guard case .scalar(let v)? = env[name] else { throw LLVMError.unsupported("%\(name) is not a scalar value in \(symbol)") }
                guard v.width == width else { throw LLVMError.invalid("%\(name) has width \(v.width), expected \(width) in \(symbol)") }
                return v
            case .constant(let x):
                return Val(bits: c.constant(x & mask(width), width: width), poison: c.falseLit)
            case .poison:
                return Val(bits: c.constant(0, width: width), poison: c.trueLit)
            case .zero:
                return Val(bits: c.constant(0, width: width), poison: c.falseLit)
            case .global, .null:
                throw LLVMError.unsupported("pointer value used as an integer in \(symbol)")
            }
        }

        func value(_ operand: Operand, _ type: LType) throws -> Value {
            switch try module.resolved(type) {
            case .int(let n) where n >= 1 && n <= 64: return .scalar(try scalar(operand, width: n))
            case .ptr: return try pointer(operand, env, in: symbol)
            case .tuple, .packed, .array: return try aggregate(operand, type, env, in: symbol)
            case let t: throw LLVMError.unsupported("value of type \(t.description) in \(symbol)")
            }
        }

        for id in order {
            let block = function.blocks[id]
            var memory: Memory
            let reach: Int32
            if id == 0 {
                reach = c.trueLit
                memory = initial
                guard block.phis.isEmpty else { throw LLVMError.invalid("phi in the entry block of \(symbol)") }
            } else {
                let edges = incoming[block.id] ?? []
                guard let first = edges.first, let last = edges.last else {
                    throw LLVMError.invalid("block \(block.id) has no predecessor")
                }
                reach = edges.dropFirst().reduce(first.condition) { c.or($0, $1.condition) }
                for phi in block.phis {
                    var chosen: [Value] = []
                    for edge in edges {
                        guard let entry = phi.entries.first(where: { $0.block == edge.predecessor }) else {
                            throw LLVMError.invalid("phi %\(phi.result) has no entry for predecessor \(edge.predecessor)")
                        }
                        chosen.append(try value(entry.operand, phi.type))
                    }
                    var merged = chosen[chosen.count - 1]
                    for k in stride(from: edges.count - 2, through: 0, by: -1) {
                        merged = try merge(edges[k].condition, chosen[k], merged)
                    }
                    env[phi.result] = merged
                }
                memory = last.memory
                for edge in edges.dropLast().reversed() { memory = merge(edge.condition, edge.memory, memory) }
            }

            // A block that calls a failure function is message plumbing followed by a trap; the plumbing
            // (closure calls and their `extractvalue`s) cannot change the outcome and is not modelled.
            let isFailureBlock = block.instructions.contains { if case .failure = $0 { true } else { false } }

            var live = reach
            instructions: for instruction in block.instructions {
                if isFailureBlock {
                    if case .extractValue = instruction { continue }
                    if case .insertValue = instruction { continue }
                    if case .call(_, let callee, _, _, _) = instruction, !callee.hasPrefix("llvm.") { continue }
                }
                switch instruction {
                case .nop: break
                case .failure:
                    trap = c.or(trap, live)
                    live = c.falseLit
                    break instructions
                case .binary(let result, let op, let flags, let width, let a, let b):
                    let (v, ub) = try binary(op, flags, try scalar(a, width: width), try scalar(b, width: width))
                    undefined = c.or(undefined, c.and(live, ub))
                    env[result] = .scalar(v)
                case .icmp(let result, let predicate, let flags, let width, let a, let b):
                    env[result] = .scalar(compare(predicate, flags, try scalar(a, width: width), try scalar(b, width: width)))
                case .select(let result, let condition, let type, let a, let b):
                    let cond = try scalar(condition, width: 1)
                    let chosen = try merge(cond.bits.bits[0], try value(a, type), try value(b, type))
                    switch chosen {
                    case .scalar(var v):
                        v.poison = c.or(v.poison, cond.poison)
                        env[result] = .scalar(v)
                    default:
                        // An address: poison in the condition would make it poison; refuse rather than track that.
                        guard cond.poison == c.falseLit else {
                            throw LLVMError.unsupported("select of addresses on a poison condition in \(symbol)")
                        }
                        env[result] = chosen
                    }
                case .cast(let result, let kind, let flags, let from, let operand, let to):
                    env[result] = .scalar(try cast(kind, flags, try scalar(operand, width: from), to: to))
                case .pointerCast(let result, let toPointer, let operand):
                    // A pointer here is its 64-bit value; only one the encoder follows (an address) cannot become an integer.
                    guard case .scalar(let v) = try value(operand, toPointer ? .int(64) : .ptr) else {
                        throw LLVMError.unsupported("ptrtoint of an address this reader follows in \(symbol)")
                    }
                    env[result] = .scalar(v)
                case .freeze(let result, let width, let operand):
                    let v = try scalar(operand, width: width)
                    // A frozen poison is an arbitrary but fixed value: fresh unconstrained bits, so a proof must hold for every choice.
                    env[result] = .scalar(Val(bits: c.select(v.poison, c.input(width: width), v.bits), poison: c.falseLit))
                case .extractValue(let result, let aggregate, let source, let indices):
                    var v = try value(source, aggregate)
                    for index in indices {
                        guard case .aggregate(let elements) = v, elements.indices.contains(index) else {
                            throw LLVMError.invalid("extractvalue index \(index) in \(symbol)")
                        }
                        v = elements[index]
                    }
                    env[result] = v
                case .insertValue(let result, let aggregate, let base, let elementType, let operand, let indices):
                    let element = try value(operand, elementType)
                    func insert(_ into: Value, _ path: ArraySlice<Int>) throws -> Value {
                        guard let index = path.first else { return element }
                        guard case .aggregate(var elements) = into, elements.indices.contains(index) else {
                            throw LLVMError.invalid("insertvalue index \(index) in \(symbol)")
                        }
                        elements[index] = try insert(elements[index], path.dropFirst())
                        return .aggregate(elements)
                    }
                    env[result] = try insert(try value(base, aggregate), indices[...])
                case .call(let result, let callee, let arguments, let returns, let range):
                    var produced: Value?
                    if callee.hasPrefix("llvm.memset") || callee.hasPrefix("llvm.memcpy") || callee.hasPrefix("llvm.memmove")
                        || callee.hasPrefix("llvm.lifetime.")
                    {
                        memory = try memoryIntrinsic(callee, arguments, memory, value: value, in: symbol)
                        break
                    }
                    if callee.hasPrefix("llvm.") {
                        switch try intrinsic(callee, arguments, returns, scalar: scalar) {
                        case .trap:
                            trap = c.or(trap, live)
                            live = c.falseLit
                            break instructions
                        case .assume(let v):
                            undefined = c.or(undefined, c.and(live, c.or(v.poison, -v.bits.bits[0])))
                        case .value(let v):
                            produced = v
                        }
                    } else if let effect = RuntimeCall(callee) {
                        produced = try effect.result(of: try arguments.map { try value($0.operand, $0.type) }, returns: returns, in: symbol)
                    } else {
                        let values = try arguments.map { try value($0.operand, $0.type) }
                        let target = try encode(symbol: callee, arguments: values, memory: memory, stack: stack + [symbol])
                        guard returns == (try module.function(callee).returnType) else {
                            throw LLVMError.invalid("call result type mismatch for \(callee)")
                        }
                        trap = c.or(trap, c.and(live, target.trap))
                        live = c.and(live, -target.trap)
                        undefined = c.or(undefined, c.and(live, target.undefined))
                        // Where the callee traps nothing after it matters, so its memory on return is the memory.
                        memory = target.memory
                        produced = target.result
                    }
                    if let range, case .scalar(var v)? = produced {
                        v.poison = c.or(v.poison, outsideRange(v.bits, range))
                        produced = .scalar(v)
                    }
                    if let result {
                        guard let produced else { throw LLVMError.invalid("\(callee) returns no value but is used in \(symbol)") }
                        env[result] = produced
                    }
                case .alloca(let result, let type):
                    let size = try module.layout(of: type).allocSize
                    env[result] = .address(region: addRegion(size: size, writable: true), offset: 0)
                case .elementAddress(let result, let base, let source, let indices):
                    guard case .address(let region, var offset)? = try? value(base, .ptr) else {
                        throw LLVMError.unsupported("getelementptr on a pointer this reader does not follow in \(symbol)")
                    }
                    guard let first = indices.first, first > -(1 << 20), first < 1 << 20 else {
                        throw LLVMError.unsupported("getelementptr index in \(symbol)")
                    }
                    offset += Int(first) * (try module.layout(of: source).allocSize)
                    var type = source
                    for index in indices.dropFirst() {
                        let step = try module.element(index, of: type)
                        offset += step.offset
                        type = step.type
                    }
                    env[result] = .address(region: region, offset: offset)
                case .store(let type, let operand, let address):
                    let stored = try value(operand, type)
                    guard case .scalar(let v) = stored else {
                        // An address stored in memory (Swift keeps `self`'s address in a debugger slot) is not followed:
                        // its bytes become unreadable, so a later load of them is refused, never misread.
                        let place = try access(try value(address, .ptr), size: 8, writing: true, in: symbol)
                        for k in 0..<8 { memory[ByteKey(region: place.region, offset: place.offset + k)] = nil }
                        break
                    }
                    let written = try self.bytes(of: v, type: type)
                    let place = try access(try value(address, .ptr), size: written.count, writing: true, in: symbol)
                    for (k, byte) in written.enumerated() { memory[ByteKey(region: place.region, offset: place.offset + k)] = byte }
                case .load(let result, let type, let address):
                    let size = try module.storeSize(type)
                    let place = try access(try value(address, .ptr), size: size, writing: false, in: symbol)
                    var bytes: [Val] = []
                    for k in 0..<size {
                        guard let byte = memory[ByteKey(region: place.region, offset: place.offset + k)] else {
                            throw LLVMError.unsupported("load of memory that was not written in \(symbol)")
                        }
                        bytes.append(byte)
                    }
                    env[result] = .scalar(self.value(from: bytes, type: type))
                }
            }

            func edge(to target: String, when condition: Int32) throws {
                guard blockIndex[target] != nil else { throw LLVMError.invalid("unknown block \(target) in \(symbol)") }
                incoming[target, default: []].append(Incoming(predecessor: block.id, condition: condition, memory: memory))
            }
            switch block.terminator {
            case .branch(let target): try edge(to: target, when: live)
            case .conditional(let condition, let yes, let no):
                let v = try scalar(condition, width: 1)
                undefined = c.or(undefined, c.and(live, v.poison))  // branching on poison is undefined behaviour
                try edge(to: yes, when: c.and(live, v.bits.bits[0]))
                try edge(to: no, when: c.and(live, -v.bits.bits[0]))
            case .switchInteger(let width, let operand, let otherwise, let cases):
                let v = try scalar(operand, width: width)
                undefined = c.or(undefined, c.and(live, v.poison))  // switching on poison is undefined behaviour
                guard Set(cases.map(\.value)).count == cases.count else { throw LLVMError.invalid("duplicate switch case in \(symbol)") }
                var matched = c.falseLit
                for (k, target) in cases {
                    let hit = c.eq(v.bits, c.constant(k & mask(width), width: width))
                    matched = c.or(matched, hit)
                    try edge(to: target, when: c.and(live, hit))
                }
                try edge(to: otherwise, when: c.and(live, -matched))
            case .returned(let type, let operand):
                guard type == function.returnType else { throw LLVMError.invalid("return type mismatch in \(symbol)") }
                var v = try value(operand, type)
                if let range = function.resultRange, case .scalar(var s) = v {
                    s.poison = c.or(s.poison, outsideRange(s.bits, range))
                    v = .scalar(s)
                }
                returns.append(Return(condition: live, value: v, memory: memory))
            case .returnedVoid:
                guard function.returnType == .void else { throw LLVMError.invalid("return type mismatch in \(symbol)") }
                returns.append(Return(condition: live, value: nil, memory: memory))
            case .unreachable:
                undefined = c.or(undefined, live)  // reaching `unreachable` is undefined behaviour
            }
        }

        guard let last = returns.last else {
            // Never returns: every path traps or is undefined behaviour.
            let result: Value? = function.returnType == .void ? nil : try poisonValue(function.returnType)
            return Outcome(result: result, trap: trap, undefined: undefined, returned: c.falseLit, memory: initial)
        }
        var result = last.value
        var memory = last.memory
        var returned = last.condition
        for r in returns.dropLast().reversed() {
            if let a = r.value, let b = result { result = try merge(r.condition, a, b) }
            memory = merge(r.condition, r.memory, memory)
            returned = c.or(returned, r.condition)
        }
        return Outcome(result: result, trap: trap, undefined: undefined, returned: returned, memory: memory)
    }

    // MARK: memory intrinsics

    private func memoryIntrinsic(
        _ callee: String, _ arguments: [Argument], _ memory: Memory, value: (Operand, LType) throws -> Value, in symbol: String
    ) throws -> Memory {
        var memory = memory
        func constant(_ k: Int) throws -> Int {
            guard k < arguments.count, case .int = arguments[k].type, case .constant(let v) = arguments[k].operand, v < 1 << 20 else {
                throw LLVMError.unsupported("\(callee) with a length that is not a small constant in \(symbol)")
            }
            return Int(v)
        }
        if callee.hasPrefix("llvm.lifetime.") {
            // The pointer is the last argument (older IR puts the size first). A slot's contents are undefined both
            // after its lifetime ends and when a new one starts.
            guard let pointer = arguments.last, pointer.type == .ptr,
                case .address(let region, _) = try value(pointer.operand, .ptr), regions.indices.contains(region)
            else {
                throw LLVMError.unsupported("\(callee) on something other than a stack slot in \(symbol)")
            }
            memory = memory.filter { $0.key.region != region }
            return memory
        }
        guard arguments.count == 4, arguments[3].type == .int(1), case .constant(0) = arguments[3].operand else {
            throw LLVMError.unsupported("volatile or malformed \(callee) in \(symbol)")
        }
        let length = try constant(2)
        let destination = try access(try value(arguments[0].operand, .ptr), size: length, writing: true, in: symbol)
        if callee.hasPrefix("llvm.memset") {
            guard arguments[1].type == .int(8), case .scalar(let byte) = try value(arguments[1].operand, .int(8)) else {
                throw LLVMError.invalid("memset value in \(symbol)")
            }
            for k in 0..<length { memory[ByteKey(region: destination.region, offset: destination.offset + k)] = byte }
            return memory
        }
        let source = try access(try value(arguments[1].operand, .ptr), size: length, writing: false, in: symbol)
        let copied = (0..<length).map { memory[ByteKey(region: source.region, offset: source.offset + $0)] }
        for (k, byte) in copied.enumerated() { memory[ByteKey(region: destination.region, offset: destination.offset + k)] = byte }
        return memory
    }

    // MARK: instructions

    private func select(_ condition: Int32, _ a: Val, _ b: Val) -> Val {
        Val(bits: c.select(condition, a.bits, b.bits), poison: c.mux(condition, a.poison, b.poison))
    }

    private func bit(_ b: Int32) -> BV { BV(bits: [b]) }

    /// Poison when `x` is outside the wrapped interval `[lo, hi)`: `x - lo` must be below `hi - lo`, modulo 2^n.
    private func outsideRange(_ x: BV, _ range: RangeAttribute) -> Int32 {
        let n = x.width
        let offset = c.sub(x, c.constant(range.lo, width: n)).difference
        return -c.ult(offset, c.constant((range.hi &- range.lo) & mask(n), width: n))
    }

    /// The value, and the condition under which the instruction is immediate undefined behaviour.
    private func binary(_ op: BinaryOp, _ flags: Set<String>, _ x: Val, _ y: Val) throws -> (Val, Int32) {
        let (a, b) = (x.bits, y.bits)
        let n = a.width
        var poison = c.or(x.poison, y.poison)
        var ub = c.falseLit
        func poisonIf(_ flag: String, _ condition: @autoclosure () -> Int32) {
            if flags.contains(flag) { poison = c.or(poison, condition()) }
        }
        let zero = c.constant(0, width: n)
        let bits: BV
        switch op {
        case .add:
            bits = c.addSigned(a, b)
            poisonIf("nuw", c.unsignedAddOverflows(a, b))
            poisonIf("nsw", c.signedAddOverflows(a, b))
        case .sub:
            bits = c.subSigned(a, b)
            poisonIf("nuw", c.unsignedSubOverflows(a, b))
            poisonIf("nsw", c.signedSubOverflows(a, b))
        case .mul:
            bits = c.mul(a, b)
            poisonIf("nuw", c.unsignedMulOverflows(a, b))
            poisonIf("nsw", c.signedMulOverflows(a, b))
        case .udiv, .urem, .sdiv, .srem:
            let signed = op == .sdiv || op == .srem
            var bad = c.eq(b, zero)
            if signed {
                let minimum = c.eq(a, c.constant(1 << UInt64(n - 1), width: n))
                bad = c.or(bad, c.and(minimum, c.eq(b, c.constant(mask(n), width: n))))
            }
            // A poison divisor might be zero, so it is undefined behaviour; a poison dividend only poisons the result.
            ub = c.or(bad, y.poison)
            let (q, r) = signed ? c.signedDivide(a, b) : c.unsignedDivide(a, b)
            bits = (op == .udiv || op == .sdiv) ? q : r
            if op == .udiv || op == .sdiv { poisonIf("exact", -c.eq(r, zero)) }
        case .shl:
            poison = c.or(poison, c.shiftAmountOutOfRange(a, b))
            bits = c.shiftLeft(a, by: b)
            poisonIf("nuw", -c.eq(c.logicalShiftRight(bits, by: b), a))
            poisonIf("nsw", -c.eq(c.arithmeticShiftRight(bits, by: b), a))
        case .lshr, .ashr:
            poison = c.or(poison, c.shiftAmountOutOfRange(a, b))
            bits = op == .lshr ? c.logicalShiftRight(a, by: b) : c.arithmeticShiftRight(a, by: b)
            poisonIf("exact", -c.eq(c.shiftLeft(bits, by: b), a))
        case .and:
            bits = BV(bits: zip(a.bits, b.bits).map { c.and($0, $1) })
        case .or:
            bits = BV(bits: zip(a.bits, b.bits).map { c.or($0, $1) })
            poisonIf("disjoint", -c.eq(BV(bits: zip(a.bits, b.bits).map { c.and($0, $1) }), zero))
        case .xor:
            bits = BV(bits: zip(a.bits, b.bits).map { c.xor($0, $1) })
        }
        return (Val(bits: bits, poison: poison), ub)
    }

    private func compare(_ predicate: Predicate, _ flags: Set<String>, _ x: Val, _ y: Val) -> Val {
        let (a, b) = (x.bits, y.bits)
        var poison = c.or(x.poison, y.poison)
        if flags.contains("samesign") { poison = c.or(poison, c.xor(a.bits[a.width - 1], b.bits[b.width - 1])) }
        let r: Int32
        switch predicate {
        case .eq: r = c.eq(a, b)
        case .ne: r = -c.eq(a, b)
        case .ult: r = c.ult(a, b)
        case .ule: r = c.ule(a, b)
        case .ugt: r = c.ult(b, a)
        case .uge: r = c.ule(b, a)
        case .slt: r = c.slt(a, b)
        case .sle: r = c.sle(a, b)
        case .sgt: r = c.slt(b, a)
        case .sge: r = c.sle(b, a)
        }
        return Val(bits: bit(r), poison: poison)
    }

    private func cast(_ kind: CastKind, _ flags: Set<String>, _ x: Val, to: Int) throws -> Val {
        let from = x.width
        var poison = x.poison
        let bits: BV
        switch kind {
        case .zext:
            guard to > from else { throw LLVMError.invalid("zext to a width that is not larger") }
            bits = c.zeroExtend(x.bits, to: to)
            if flags.contains("nneg") { poison = c.or(poison, x.bits.bits[from - 1]) }
        case .sext:
            guard to > from else { throw LLVMError.invalid("sext to a width that is not larger") }
            bits = c.signExtend(x.bits, to: to)
        case .trunc:
            guard to < from else { throw LLVMError.invalid("trunc to a width that is not smaller") }
            bits = c.truncate(x.bits, to: to)
            if flags.contains("nuw") { poison = c.or(poison, -c.eq(c.zeroExtend(bits, to: from), x.bits)) }
            if flags.contains("nsw") { poison = c.or(poison, -c.eq(c.signExtend(bits, to: from), x.bits)) }
        }
        return Val(bits: bits, poison: poison)
    }

    // MARK: intrinsics

    private enum IntrinsicOutcome {
        case value(Value)
        case assume(Val)
        case trap
    }

    private func intrinsic(
        _ name: String, _ arguments: [Argument], _ returns: LType,
        scalar: (Operand, Int) throws -> Val
    ) throws -> IntrinsicOutcome {
        var base = String(name.dropFirst("llvm.".count))
        if let dot = base.lastIndex(of: "."), Int(base[base.index(after: dot)...].dropFirst()) != nil,
            base[base.index(after: dot)...].hasPrefix("i")
        {
            base = String(base[..<dot])
        }
        func int(_ k: Int) throws -> Val {
            guard k < arguments.count, case .int(let n) = arguments[k].type else { throw LLVMError.unsupported("argument \(k) of \(name)") }
            return try scalar(arguments[k].operand, n)
        }
        func flag(_ k: Int) throws -> Int32 {
            guard k < arguments.count, case .int(1) = arguments[k].type, case .constant(let v) = arguments[k].operand else {
                throw LLVMError.unsupported("argument \(k) of \(name) must be a constant i1")
            }
            return v == 1 ? c.trueLit : c.falseLit
        }
        func result(_ bits: BV, poison: Int32) throws -> IntrinsicOutcome {
            guard returns == .int(bits.width) else { throw LLVMError.invalid("\(name) returns \(returns.description)") }
            return .value(.scalar(Val(bits: bits, poison: poison)))
        }
        switch base {
        case "trap":
            return .trap
        case "assume":
            return .assume(try int(0))
        case "expect":
            let a = try int(0)
            return try result(a.bits, poison: a.poison)
        case "sadd.with.overflow", "uadd.with.overflow", "ssub.with.overflow", "usub.with.overflow", "smul.with.overflow",
            "umul.with.overflow":
            let (a, b) = (try int(0), try int(1))
            guard returns == .tuple([.int(a.width), .int(1)]) else { throw LLVMError.invalid("\(name) result type") }
            let poison = c.or(a.poison, b.poison)
            let value: BV, overflow: Int32
            switch base.prefix(4) {
            case "sadd": value = c.addSigned(a.bits, b.bits); overflow = c.signedAddOverflows(a.bits, b.bits)
            case "uadd": value = c.add(a.bits, b.bits).sum; overflow = c.unsignedAddOverflows(a.bits, b.bits)
            case "ssub": value = c.subSigned(a.bits, b.bits); overflow = c.signedSubOverflows(a.bits, b.bits)
            case "usub": value = c.sub(a.bits, b.bits).difference; overflow = c.unsignedSubOverflows(a.bits, b.bits)
            case "smul": value = c.mul(a.bits, b.bits); overflow = c.signedMulOverflows(a.bits, b.bits)
            default: value = c.mul(a.bits, b.bits); overflow = c.unsignedMulOverflows(a.bits, b.bits)
            }
            return .value(.aggregate([.scalar(Val(bits: value, poison: poison)), .scalar(Val(bits: bit(overflow), poison: poison))]))
        case "smin", "smax", "umin", "umax":
            let (a, b) = (try int(0), try int(1))
            let less: Int32 = base.hasPrefix("s") ? c.slt(a.bits, b.bits) : c.ult(a.bits, b.bits)
            let pick = base.hasSuffix("min") ? c.select(less, a.bits, b.bits) : c.select(less, b.bits, a.bits)
            return try result(pick, poison: c.or(a.poison, b.poison))
        case "abs":
            let a = try int(0)
            let n = a.width
            let negative = a.bits.bits[n - 1]
            let value = c.select(negative, c.negate(a.bits), a.bits)
            let atMinimum = c.eq(a.bits, c.constant(1 << UInt64(n - 1), width: n))
            let bad = try flag(1) == c.trueLit ? atMinimum : c.falseLit
            return try result(value, poison: c.or(a.poison, bad))
        case "ctpop":
            let a = try int(0)
            let n = a.width
            var sum = c.constant(0, width: n)
            for b in a.bits.bits { sum = c.add(sum, c.zeroExtend(bit(b), to: n)).sum }
            return try result(sum, poison: a.poison)
        case "ctlz", "cttz":
            let a = try int(0)
            let n = a.width
            var count = c.constant(UInt64(n), width: n)
            let positions = base == "ctlz" ? Array(0..<n) : Array((0..<n).reversed())
            for i in positions {
                let value = base == "ctlz" ? n - 1 - i : i
                count = c.select(a.bits.bits[i], c.constant(UInt64(value), width: n), count)
            }
            let zeroPoison = try flag(1) == c.trueLit ? c.eq(a.bits, c.constant(0, width: n)) : c.falseLit
            return try result(count, poison: c.or(a.poison, zeroPoison))
        case "bswap":
            let a = try int(0)
            guard a.width % 16 == 0 else { throw LLVMError.invalid("bswap of width \(a.width)") }
            let bytes = a.width / 8
            var out: [Int32] = []
            for byte in 0..<bytes { out += a.bits.bits[(bytes - 1 - byte) * 8..<(bytes - byte) * 8] }
            return try result(BV(bits: out), poison: a.poison)
        case "bitreverse":
            let a = try int(0)
            return try result(BV(bits: a.bits.bits.reversed()), poison: a.poison)
        default:
            throw LLVMError.unsupported("intrinsic \(name)")
        }
    }

    /// Indices of reachable blocks, predecessors first. Rejects cycles. Blocks that cannot be reached from the
    /// entry never execute and are ignored.
    private func topologicalOrder(_ function: LLVMFunction) throws -> [Int] {
        // Not `Dictionary(uniqueKeysWithValues:)`: it traps on a repeated label before any check could throw.
        var index: [String: Int] = [:]
        for (position, block) in function.blocks.enumerated() where index.updateValue(position, forKey: block.id) != nil {
            throw LLVMError.invalid("duplicate block \(block.id) in \(function.symbol)")
        }
        func successors(_ b: Block) throws -> [Int] {
            let names: [String]
            switch b.terminator {
            case .branch(let t): names = [t]
            case .conditional(_, let y, let n): names = [y, n]
            case .switchInteger(_, _, let otherwise, let cases): names = [otherwise] + cases.map(\.target)
            default: names = []
            }
            return try names.map { name in
                guard let i = index[name] else { throw LLVMError.invalid("unknown block \(name) in \(function.symbol)") }
                return i
            }
        }
        var reachable: Set<Int> = [0]
        var stack = [0]
        while let i = stack.popLast() {
            for s in try successors(function.blocks[i]) where reachable.insert(s).inserted { stack.append(s) }
        }
        var indegree = [Int: Int]()
        for i in reachable { for s in try successors(function.blocks[i]) { indegree[s, default: 0] += 1 } }
        guard indegree[0, default: 0] == 0 else { throw LLVMError.unsupported("loop through the entry block in \(function.symbol)") }
        var order: [Int] = []
        var ready = [0]
        while let i = ready.popLast() {
            order.append(i)
            for s in try successors(function.blocks[i]) {
                let left = indegree[s, default: 0] - 1
                indegree[s] = left
                if left == 0 { ready.append(s) }
            }
        }
        guard order.count == reachable.count else { throw LLVMError.unsupported("loop (back edge) in \(function.symbol)") }
        return order
    }
}

/// The Swift runtime's reference-counting entry points. They change reference counts, which no value logic checks
/// depends on; a `retain` returns its argument (its declaration says `returned`). Trusted, as Scan trusts it: that
/// a release here runs no code of the checked modules (Scan refuses types whose `deinit` could).
private enum RuntimeCall {
    case retain, release

    init?(_ callee: String) {
        switch callee {
        case "swift_retain", "swift_bridgeObjectRetain", "swift_unknownObjectRetain": self = .retain
        case "swift_release", "swift_bridgeObjectRelease", "swift_unknownObjectRelease": self = .release
        default: return nil
        }
    }

    func result(of arguments: [LLVMEncoder.Value], returns: LType, in symbol: String) throws -> LLVMEncoder.Value? {
        guard arguments.count == 1, case .scalar(let object) = arguments[0], object.width == 64 else {
            throw LLVMError.unsupported("reference counting of something other than an object pointer in \(symbol)")
        }
        switch (self, returns) {
        case (.retain, .ptr): return .scalar(object)
        case (.release, .void): return nil
        default: throw LLVMError.invalid("reference-counting call with an unexpected result type in \(symbol)")
        }
    }
}
