package import SFBV
import SFCNF
import SFSemantics

/// The meaning of one SIL function as circuits.
package struct EncodedFunction {
    /// All result leaves concatenated, leaf 0 in the low bits. For a scalar result this is the scalar itself.
    package let result: BV
    /// One entry per scalar leaf of the result (a struct or tuple result is flattened in declaration order).
    package let results: [BV]
    /// True exactly when the function traps (`cond_fail`, or a call into a standard-library failure function).
    package let trap: Int32
    /// True exactly when an S0 operation's precondition fails (division by zero, shift amount out of range)
    /// or an array element is accessed out of range.
    package let undefined: Int32
    /// The individual conditions that `trap` is the disjunction of, for locating a trap.
    package let trapSites: [TrapSite]
    /// What the function writes back through addresses, laid out as `SILFunction.writtenBackWidths`: the `@out`
    /// result, then the final value of every `@inout` parameter.
    package var writtenBack: [BV] = []
    /// Names of the summarized standard-library calls (see `StdlibSummary`) whose unknown results may feed the
    /// outputs. Empty when the encoding is exact.
    package var approximations: Set<String> = []
    /// For a function that can throw: true exactly when it throws (then `results` mean nothing), and the error
    /// (plan item L6). Nil for a function that cannot throw.
    package var throwing: Int32?
    /// The error thrown, laid out as the function's error type; meaningful only where `throwing` holds.
    package var error: [BV] = []
    /// With contract summaries (plan item H4): what the fresh results of summarized calls are assumed to satisfy; nil
    /// without summaries. See `SILEncoder.contractSummaries`.
    package var assumption: Int32?
    /// The callees whose contract stood for their code in this encoding (plan item H4).
    package var contractsUsed: Set<String> = []
    /// For a function that returns an object: true when it returns its own class parameter (an initializer returns
    /// its `self`), false when it returns an object it created (plan item L5).
    package var objectResultIsParameter = false
}

// MARK: - control flow graph

struct BlockEdge: Hashable {
    let from: Int
    let to: Int
}

/// Dominators, back edges and natural loops of one function. Loops must be reducible: after removing the edges
/// whose target dominates their source, the graph has to be acyclic.
struct CFG {
    let count: Int
    let successors: [[Int]]
    let predecessors: [[Int]]
    let immediateDominator: [Int]
    let backEdges: Set<BlockEdge>
    /// Loop headers in block order.
    let headers: [Int]
    let isHeader: [Bool]
    let loopBodies: [Int: Set<Int>]
    /// Topological order of the graph without back edges.
    let forwardOrder: [Int]
    let index: [String: Int]

    /// Block label -> position. Not `Dictionary(uniqueKeysWithValues:)`: it traps on a repeated label (plan item V2).
    private static func blockIndex(_ function: SILFunction) throws -> [String: Int] {
        var index: [String: Int] = [:]
        for (position, block) in function.blocks.enumerated() where index.updateValue(position, forKey: block.id) != nil {
            throw SILError.invalid("duplicate block \(block.id) in \(function.symbol)")
        }
        return index
    }

    init(_ function: SILFunction) throws {
        let blocks = function.blocks
        let index = try Self.blockIndex(function)
        var successors: [[Int]] = []
        for b in blocks {
            successors.append(
                try b.terminator.successorBlocks.map {
                    guard let i = index[$0] else { throw SILError.invalid("unknown block \($0) in \(function.symbol)") }
                    return i
                })
        }
        var predecessors = [[Int]](repeating: [], count: blocks.count)
        for (i, ss) in successors.enumerated() { for s in ss { predecessors[s].append(i) } }
        guard predecessors[0].isEmpty else { throw SILError.unsupported("loop through entry block in \(function.symbol)") }

        // Depth-first postorder from the entry.
        var visited = [Bool](repeating: false, count: blocks.count)
        var postorder: [Int] = []
        var stack: [(Int, Int)] = [(0, 0)]
        visited[0] = true
        while let (node, next) = stack.last {
            if next < successors[node].count {
                stack[stack.count - 1].1 += 1
                let s = successors[node][next]
                if !visited[s] { visited[s] = true; stack.append((s, 0)) }
            } else {
                postorder.append(node)
                stack.removeLast()
            }
        }
        guard postorder.count == blocks.count else { throw SILError.unsupported("unreachable blocks in \(function.symbol)") }
        var number = [Int](repeating: 0, count: blocks.count)
        for (i, n) in postorder.enumerated() { number[n] = i }

        // Cooper–Harvey–Kennedy.
        var idom = [Int?](repeating: nil, count: blocks.count)
        idom[0] = 0
        var changed = true
        while changed {
            changed = false
            for n in postorder.reversed() where n != 0 {
                var new: Int?
                for p in predecessors[n] where idom[p] != nil {
                    if let current = new {
                        var a = p, b = current
                        while a != b {
                            while number[a] < number[b] { a = idom[a]! }
                            while number[b] < number[a] { b = idom[b]! }
                        }
                        new = a
                    } else {
                        new = p
                    }
                }
                if idom[n] != new { idom[n] = new; changed = true }
            }
        }
        let dominator = idom.map { $0! }
        func dominates(_ a: Int, _ b: Int) -> Bool {
            var n = b
            while true {
                if n == a { return true }
                if n == 0 { return false }
                n = dominator[n]
            }
        }

        var back = Set<BlockEdge>()
        for (u, ss) in successors.enumerated() { for v in ss where dominates(v, u) { back.insert(BlockEdge(from: u, to: v)) } }

        var indegree = [Int](repeating: 0, count: blocks.count)
        for (u, ss) in successors.enumerated() { for v in ss where !back.contains(BlockEdge(from: u, to: v)) { indegree[v] += 1 } }
        var order: [Int] = []
        var ready = (0..<blocks.count).filter { indegree[$0] == 0 }
        while !ready.isEmpty {
            ready.sort(by: >)
            let n = ready.removeLast()
            order.append(n)
            for s in successors[n] where !back.contains(BlockEdge(from: n, to: s)) {
                indegree[s] -= 1
                if indegree[s] == 0 { ready.append(s) }
            }
        }
        guard order.count == blocks.count else {
            throw SILError.unsupported("irreducible control flow in \(function.symbol)")
        }

        let headers = Set(back.map(\.to)).sorted()
        var bodies: [Int: Set<Int>] = [:]
        for h in headers {
            var body: Set<Int> = [h]
            var work = back.filter { $0.to == h }.map(\.from)
            while let n = work.popLast() {
                if body.insert(n).inserted { work.append(contentsOf: predecessors[n]) }
            }
            bodies[h] = body
        }

        self.count = blocks.count
        self.successors = successors
        self.predecessors = predecessors
        self.immediateDominator = dominator
        self.backEdges = back
        self.headers = headers
        self.isHeader = (0..<blocks.count).map { headers.contains($0) }
        self.loopBodies = bodies
        self.forwardOrder = order
        self.index = index
    }

    func dominates(_ a: Int, _ b: Int) -> Bool {
        var n = b
        while true {
            if n == a { return true }
            if n == 0 { return false }
            n = immediateDominator[n]
        }
    }
}

// MARK: - encoder

/// The fresh state a loop header gets when it is a cutpoint: its block parameters (as leaves) and stack cells.
struct HeaderState {
    var parameters: [[BV]]
    var cells: [String: BV]
    /// When the header is reached with this state; nil: it counts as reached (an invariant proof assumes it). Bounded
    /// unrolling (`SILUnwind.swift`) passes the condition under which the previous iteration arrived.
    var reach: Int32?
}

struct TrapEvent {
    let block: Int
    let condition: Int32
    var site: TrapKind = .unreachable(block: "")
}

struct Arrival {
    let source: Int
    let target: Int
    let isBackEdge: Bool
    let condition: Int32
    let parameters: [[BV]]
    let cells: [String: BV]
}

struct ReturnEvent {
    let block: Int
    let condition: Int32
    let leaves: [BV]
    /// The `@out` result and final `@inout` values at this return (see `EncodedFunction.writtenBack`).
    var writtenBack: [BV] = []
    /// For a returned object: whether it is the function's class parameter (plan item L5).
    var objectIsParameter = false
    /// The stack slots at this return (a global's initializer leaves the global's value there, `SILGlobals.swift`).
    var cells: [String: BV] = [:]
}

struct RunOutput {
    var traps: [TrapEvent] = []
    var undefineds: [TrapEvent] = []
    var arrivals: [Arrival] = []
    var returns: [ReturnEvent] = []
    /// Each `throw`: when it is reached and the error it throws (plan item L6).
    var throwsEvents: [(condition: Int32, error: [BV])] = []
    var states: [Int: HeaderState] = [:]
    /// For each cutpoint that was entered by at least one forward edge: the condition under which one of them is taken.
    var entryConditions: [Int: Int32] = [:]
    /// See `EncodedFunction.approximations`.
    var approximations: Set<String> = []
}

/// Turns a SIL function into circuits. Control flow becomes reachability literals, block parameters become
/// multiplexers, calls to other functions in the module are inlined. Loop-free only: loops are handled by
/// `SILVerifier.proveLoopFunction`, which cuts them at their headers.
package final class SILEncoder {
    /// The module whose functions are encoded.
    package let module: SILModule
    /// Called once per function encoding with every SSA value and the layout the encoder gave it (nil for addresses,
    /// functions and other non-data values). For checking the reader's types against the compiler's (plan item L11).
    package var observeValues: ((_ function: String, _ value: String, _ type: ValueType?) -> Void)?
    /// Callees replaced by their proved contract instead of being inlined (plan item H4, `SILContractSummaries.swift`).
    package var contractSummaries: [String: ContractSummary] = [:]
    var assumption: Int32?
    /// The closure literals made so far, by the bits of their leaf (`SILClosureCalls.swift`).
    var knownClosures: [[Int32]: KnownClosure] = [:]
    var summarizedCalls: Set<String> = []
    /// The symbol of the top-level encoding and how many foreign results it made: their keys (`SILForeign.swift`).
    var foreignCount = (root: "", made: 0)
    /// The `let` globals read so far, and those whose initializer is being encoded (`SILGlobals.swift`).
    var globalValues: [String: GlobalValue] = [:]
    var initializingGlobals: Set<String> = []
    let c: CNFBuilder
    private let maxDepth: Int
    /// Where the last error was thrown: the functions being inlined, outermost first, each at its instruction (U7).
    package internal(set) var trail: [SILTrailFrame] = []

    /// An encoder of `module`'s functions into `builder`; calls are inlined up to `maxCallDepth` deep.
    package init(module: SILModule, builder: CNFBuilder, maxCallDepth: Int = 8) {
        self.module = module
        self.c = builder
        self.maxDepth = maxCallDepth
    }

    /// The circuits of `symbol` applied to `arguments`.
    package func encode(symbol: String, arguments: [BV]) throws -> EncodedFunction {
        (assumption, summarizedCalls, foreignCount) = (nil, [], (symbol, 0))
        var encoded = try encode(symbol: symbol, arguments: arguments, stack: [])
        (encoded.assumption, encoded.contractsUsed) = (assumption, summarizedCalls)
        return encoded
    }

    func encode(symbol: String, arguments: [BV], stack: [String]) throws -> EncodedFunction {
        guard !stack.contains(symbol) else { throw SILError.unsupported("recursion through \(symbol)") }
        guard stack.count < maxDepth else { throw SILError.unsupported("call depth above \(maxDepth) at \(symbol)") }
        let function = try module.function(symbol)
        guard arguments.map(\.width) == function.parameterWidths else {
            throw SILError.invalid("argument widths do not match \(symbol)")
        }
        let cfg = try CFG(function)
        guard cfg.headers.isEmpty else {
            throw SILError.unsupported(
                "loops in \(symbol) (blocks \(cfg.headers.map { function.blocks[$0].id })): verify with SILVerifier.proveLoopFunction and loop invariants"
            )
        }
        let out = try run(
            function, cfg: cfg, arguments: arguments, assumed: [],
            makeState: { _, _ in
                throw SILError.invalid("no loop headers expected")
            }, stack: stack)
        var trap = c.falseLit, undefined = c.falseLit
        for e in out.traps { trap = c.or(trap, e.condition) }
        for e in out.undefineds { undefined = c.or(undefined, e.condition) }
        var leaves = function.resultWidths.map { c.constant(0, width: $0) }
        var writtenBack = function.writtenBackWidths.map { c.constant(0, width: $0) }
        if let last = out.returns.last {
            leaves = last.leaves
            writtenBack = last.writtenBack
            for r in out.returns.dropLast().reversed() {
                leaves = zip(r.leaves, leaves).map { c.select(r.condition, $0, $1) }
                writtenBack = zip(r.writtenBack, writtenBack).map { c.select(r.condition, $0, $1) }
            }
        }
        let result = BV(bits: leaves.flatMap(\.bits))
        var encoded = EncodedFunction(
            result: result, results: leaves, trap: trap, undefined: undefined,
            trapSites: out.traps.map { TrapSite(kind: $0.site, condition: $0.condition) },
            writtenBack: writtenBack, approximations: out.approximations
        )
        encoded.objectResultIsParameter = try objectResultIsParameter(function, out)
        if let errorType = function.errorType {
            var error = errorType.leafWidths.map { c.constant(0, width: $0) }
            var throwing = c.falseLit
            for event in out.throwsEvents.reversed() {
                error = zip(event.error, error).map { c.select(event.condition, $0, $1) }
                throwing = c.or(throwing, event.condition)
            }
            (encoded.throwing, encoded.error) = (throwing, error)
        }
        return encoded
    }

    // MARK: running a function

    /// Encodes the blocks of `function` in topological order of the graph without back edges. A loop header in
    /// `assumed` is a cutpoint that is entered with a fresh state from `makeState`; any other loop header is not
    /// entered: edges that reach it are recorded as arrivals. Back edges are always recorded, never followed.
    func run(
        _ function: SILFunction, cfg: CFG, arguments: [BV], assumed: Set<Int>,
        makeState: (Int, [(key: String, width: Int)]) throws -> HeaderState, stack: [String]
    ) throws -> RunOutput {
        try FunctionRun(encoder: self, function: function, cfg: cfg, arguments: arguments, assumed: assumed, stack: stack)
            .run(makeState: makeState)
    }

    /// Leaves of an unknown but valid value of `type`: every value of the type is possible, and nothing else
    /// (an enum tag names a real case and inactive payloads are zero; an array count is below 2^48).
    func fresh(_ type: ValueType) -> [BV] {
        switch type {
        case .scalar(let w): return [c.input(width: w)]
        case .opaque: return [c.input(width: 64)]
        case .array, .hashed: return [BV(bits: c.input(width: 48).bits + Array(repeating: c.falseLit, count: 16))]
        case .aggregate(_, let fields): return fields.flatMap { fresh($0.type) }
        case .enumeration(_, let cases):
            let widths = type.leafWidths
            let raw = c.input(width: widths[0])
            let tag =
                cases.count == 1 << raw.width
                ? raw : c.select(c.ult(raw, c.constant(UInt64(cases.count), width: raw.width)), raw, c.constant(0, width: raw.width))
            var leaves = [tag] + widths.dropFirst().map { c.constant(0, width: $0) }
            for (k, enumCase) in cases.enumerated() {
                guard let payload = enumCase.payload else { continue }
                let active = c.eq(tag, c.constant(UInt64(k), width: tag.width))
                for (offset, leaf) in zip(type.payloadLeafRange(ofCase: k), fresh(payload)) {
                    leaves[offset] = BV(bits: leaf.bits.map { c.and($0, active) })
                }
            }
            return leaves
        }
    }

}

private extension S0Op {
    var isCast: Bool { self == .trunc || self == .zext || self == .sext }
}
