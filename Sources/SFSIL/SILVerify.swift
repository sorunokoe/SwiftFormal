import Foundation
package import SFBV
import SFCNF
package import SFProve

/// The compiler optimization level a function is compiled at. Public because `CompileOptions` in `SFVerifyKit` exposes it.
public enum Optimization: String, Sendable {
    case none = "-Onone"
    case speed = "-O"
}

/// Compiles Swift source to canonical SIL with the installed `swiftc`. The compiler does all the work of
/// type checking, overload resolution, generic specialization and operator lowering.
package enum SILCompiler {
    package static func emit(
        source: String, module: String = "Fixture", optimization: Optimization, extraArguments: [String] = []
    ) throws -> String {
        let directory = NSTemporaryDirectory() + "sf-sil-\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: directory) }
        let input = directory + "/\(module).swift"
        try source.write(toFile: input, atomically: true, encoding: .utf8)

        let output = directory + "/\(module).sil"
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/xcrun")
        process.arguments =
            [
                "swiftc", "-frontend", "-emit-sil", optimization.rawValue, "-parse-as-library",
                "-module-name", module, "-sdk", try sdkPath(), input, "-o", output,
            ] + extraArguments
        // The SIL goes to a file, so only diagnostics travel through the pipe and it cannot fill up and block.
        let err = Pipe()
        process.standardError = err
        try process.run()
        let errData = err.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw SILError.compilerFailed(String(decoding: errData, as: UTF8.self))
        }
        return try String(contentsOfFile: output, encoding: .utf8)
    }

    private static func sdkPath() throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/xcrun")
        process.arguments = ["--show-sdk-path"]
        let pipe = Pipe()
        process.standardOutput = pipe
        try process.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    package static func module(
        source: String, name: String = "Fixture", optimization: Optimization, extraArguments: [String] = []
    ) throws -> SILModule {
        try SILModule(text: try emit(source: source, module: name, optimization: optimization, extraArguments: extraArguments))
    }
}

package enum SILVerifier {
    /// Proves `requires(inputs) ⇒ ¬trap ∧ ¬undefined ∧ ensures(inputs, result)` for every input,
    /// or returns inputs that violate it. The proof is accepted only after the independent RUP checker agrees.
    ///
    /// - Parameter inputSignedBits: optional per-parameter range declaration (see `prove`). The caller must
    ///   make `requires` consistent with it; a declared range is an assumption, not a check.
    package static func prove(
        _ symbol: String,
        in module: SILModule,
        inputSignedBits: [Int?]? = nil,
        conflictBudget: Int = 1_000_000,
        refining: Bool = false,
        requires: (CNFBuilder, [BV]) -> Int32 = { c, _ in c.trueLit },
        ensures: (CNFBuilder, [BV], BV) -> Int32 = { c, _, _ in c.trueLit }
    ) throws -> ProofVerdict {
        let function = try module.function(symbol)
        return try run(
            widths: function.parameterWidths, inputSignedBits: inputSignedBits,
            conflictBudget: conflictBudget, refining: refining
        ) { c, inputs, approximate in
            let encoded = try SILEncoder(module: module, builder: c).encode(symbol: symbol, arguments: inputs)
            approximate = approximate || !encoded.approximations.isEmpty
            let safe = c.and(-encoded.trap, -encoded.undefined)
            let good = c.and(safe, ensures(c, inputs, encoded.result))
            return c.or(-c.and(function.inputAssumption(c, inputs), requires(c, inputs)), good)
        }
    }

    /// Proves `claim`. When the encoding used a standard-library summary (`approximate` set by the claim), a
    /// counterexample may rest on a result the real call never returns. It is kept only if, on those inputs, the
    /// claim fails for *every* result the summarized calls could give; otherwise the verdict is `.unknown`.
    private static func run(
        widths: [Int], inputSignedBits: [Int?]?, conflictBudget: Int, refining: Bool,
        claim: (CNFBuilder, [BV], inout Bool) throws -> Int32
    ) throws -> ProofVerdict {
        var approximate = false
        let verdict = try proveMaybeRefining(
            inputWidths: widths, inputSignedBits: inputSignedBits, conflictBudget: conflictBudget,
            refining: refining
        ) { c, inputs in try claim(c, inputs, &approximate) }
        guard case .counterexample(let values) = verdict, approximate else { return verdict }
        var ignored = false
        let fixed = try proveMaybeRefining(inputWidths: [], conflictBudget: conflictBudget, refining: false) { c, _ in
            -(try claim(c, zip(widths, values).map { c.constant($1, width: $0) }, &ignored))
        }
        return fixed == .proved ? verdict : .unknown
    }

    /// Like `prove`, for functions whose result is a struct or tuple of scalars. `ensures` receives the inputs
    /// (one per flattened parameter leaf, declaration order) and the result leaves (declaration order, nested
    /// structs flattened depth-first). For a scalar result `results` has one element.
    package static func proveAggregate(
        _ symbol: String,
        in module: SILModule,
        inputSignedBits: [Int?]? = nil,
        conflictBudget: Int = 1_000_000,
        refining: Bool = false,
        requires: (CNFBuilder, [BV]) -> Int32 = { c, _ in c.trueLit },
        ensures: (CNFBuilder, [BV], [BV]) -> Int32 = { c, _, _ in c.trueLit }
    ) throws -> ProofVerdict {
        let function = try module.function(symbol)
        return try run(
            widths: function.parameterWidths, inputSignedBits: inputSignedBits,
            conflictBudget: conflictBudget, refining: refining
        ) { c, inputs, approximate in
            let encoded = try SILEncoder(module: module, builder: c).encode(symbol: symbol, arguments: inputs)
            approximate = approximate || !encoded.approximations.isEmpty
            let safe = c.and(-encoded.trap, -encoded.undefined)
            let good = c.and(safe, ensures(c, inputs, encoded.results))
            return c.or(-c.and(function.inputAssumption(c, inputs), requires(c, inputs)), good)
        }
    }

    /// Proves that two compilations of the same function agree: they trap on the same inputs, hit undefined
    /// behaviour on the same inputs, and return the same value otherwise.
    package static func proveEquivalent(
        _ symbolA: String, in a: SILModule,
        _ symbolB: String, in b: SILModule,
        conflictBudget: Int = 1_000_000,
        refining: Bool = false
    ) throws -> ProofVerdict {
        let fa = try a.function(symbolA), fb = try b.function(symbolB)
        guard fa.parameterWidths == fb.parameterWidths, fa.resultWidth == fb.resultWidth else {
            throw SILError.invalid("signatures differ")
        }
        return try run(
            widths: fa.parameterWidths, inputSignedBits: nil, conflictBudget: conflictBudget, refining: refining
        ) { c, inputs, approximate in
            let ea = try SILEncoder(module: a, builder: c).encode(symbol: symbolA, arguments: inputs)
            let eb = try SILEncoder(module: b, builder: c).encode(symbol: symbolB, arguments: inputs)
            approximate = approximate || !ea.approximations.isEmpty || !eb.approximations.isEmpty
            let sameTrap = -c.xor(ea.trap, eb.trap)
            let sameUndefined = -c.xor(ea.undefined, eb.undefined)
            let bothOK = c.and(-ea.trap, -ea.undefined)
            let sameValue = c.or(-bothOK, c.eq(ea.result, eb.result))
            // Only real values are compared: an enum input with an impossible tag has no defined meaning.
            return c.or(-fa.inputAssumption(c, inputs), c.and(c.and(sameTrap, sameUndefined), sameValue))
        }
    }
}

// MARK: - loops: cutpoints with checked invariants

/// One variable of a loop header's state, in the order `LoopState.variables` lists them.
package struct LoopVariable: Sendable, Equatable {
    /// The SIL name of the header block parameter (`%7`; `%7.1` for leaf 1 of an aggregate parameter) or the
    /// stack cell (`%3#0`).
    package let name: String
    package let type: String
    package let width: Int
    /// A tracked `alloc_stack` slot rather than a block parameter. At -Onone most state lives in block parameters
    /// and these cells are mostly dead.
    package let isStackCell: Bool
}

package struct LoopInfo: Sendable, Equatable {
    /// The header block, such as `bb3`.
    package let header: String
    /// The state that is live at the header: header block parameters (leaves, declaration order), then stack cells
    /// sorted by name. Function arguments are not listed: they are `LoopState.arguments`.
    package let variables: [LoopVariable]
    /// Headers of the loops that contain this loop, outermost first.
    package let enclosing: [String]
    package let isInnermost: Bool
}

/// What an invariant (or variant) may talk about: the function arguments, the loop's own header state, and the header
/// state of each enclosing loop at the start of its current iteration.
package struct LoopState {
    package let arguments: [BV]
    package let variables: [BV]
    /// Keyed by header block name; one entry for every loop that contains this one.
    package let enclosing: [String: [BV]]
}

package struct LoopInvariant {
    package let header: String
    package let holds: (CNFBuilder, LoopState) -> Int32
    package init(header: String, holds: @escaping (CNFBuilder, LoopState) -> Int32) {
        self.header = header
        self.holds = holds
    }
}

/// An optional unsigned ranking function for termination. Only innermost loops can have one.
package struct LoopVariant {
    package let header: String
    package let rank: (CNFBuilder, LoopState) -> BV
    package init(header: String, rank: @escaping (CNFBuilder, LoopState) -> BV) {
        self.header = header
        self.rank = rank
    }
}

package enum LoopObligationKind: Int, Sendable, Comparable {
    /// A loop-free path from the entry to a return (or to a trap) that crosses no loop.
    case entry
    /// The state on arrival at a loop header from outside the loop satisfies the invariant.
    case initialization
    /// One iteration from any invariant state re-establishes the invariant (traps and undefined behaviour excluded).
    case step
    /// From any invariant state, every way out of the loop reaches the return with `ensures`, without trap.
    case exit
    case termination

    package static func < (a: Self, b: Self) -> Bool { a.rawValue < b.rawValue }

    package var label: String {
        switch self {
        case .entry: "ENTRY"
        case .initialization: "INIT"
        case .step: "STEP"
        case .exit: "EXIT"
        case .termination: "TERMINATION"
        }
    }
}

package struct LoopCounterexample: Sendable, Equatable {
    package let arguments: [UInt64]
    /// For each header whose state was a free variable in the failing obligation (the loop itself and its enclosing
    /// loops), the values in `LoopInfo.variables` order.
    package let states: [String: [UInt64]]
}

package struct LoopObligation: Sendable {
    package let kind: LoopObligationKind
    /// The header the obligation is about (nil for `.entry`).
    package let header: String?
    /// The loop-free circuit that was checked: "entry", or the header whose state was assumed.
    package let origin: String
    package let verdict: ProofVerdict
    package let counterexample: LoopCounterexample?

    package var name: String { header.map { "\(kind.label)(\($0))" } ?? kind.label }
}

package struct LoopProofResult: Sendable {
    package let loops: [LoopInfo]
    package let obligations: [LoopObligation]
    /// Every INIT/STEP/EXIT/ENTRY obligation was proved: if the function terminates it satisfies `ensures` and neither
    /// traps nor hits undefined behaviour. This says nothing about termination.
    package let partialCorrectnessProved: Bool
    /// Every loop has a variant and every TERMINATION obligation was proved. Only meaningful together with
    /// `partialCorrectnessProved`.
    package let terminationProved: Bool
    package var failures: [LoopObligation] { obligations.filter { $0.verdict != .proved } }
    package var provedTotalCorrectness: Bool { partialCorrectnessProved && terminationProved }

    package var summary: String {
        let state: String
        if !partialCorrectnessProved {
            state =
                "NOT proved: "
                + failures.filter { $0.kind != .termination }.map { "\($0.name)\($0.verdict == .unknown ? " (unknown)" : "")" }.joined(
                    separator: ", ")
        } else if terminationProved {
            state = "total correctness proved (partial correctness and termination)"
        } else {
            state = "partial correctness proved; termination not proved"
        }
        return "\(obligations.count) obligations; \(state)"
    }
}

struct LoopKey: Hashable, Comparable {
    let kind: LoopObligationKind
    let header: Int
    static func < (a: Self, b: Self) -> Bool { (a.kind, a.header) < (b.kind, b.header) }
}

struct LoopShape {
    let params: [[Int]]
    let cells: [(key: String, width: Int)]
    var widths: [Int] { params.flatMap { $0 } + cells.map(\.width) }
}

/// The loop structure of a function and the shape of each header state, found by encoding the function once with
/// every header assumed.
struct LoopPlan {
    let function: SILFunction
    let cfg: CFG
    let shapes: [Int: LoopShape]
    let enclosing: [Int: [Int]]

    init(symbol: String, module: SILModule) throws {
        let function = try module.function(symbol)
        let cfg = try CFG(function)
        self.function = function
        self.cfg = cfg
        var found: [Int: LoopShape] = [:]
        let scratch = CNFBuilder()
        let arguments = function.parameterWidths.map { scratch.input(width: $0) }
        let out = try SILEncoder(module: module, builder: scratch).run(
            function, cfg: cfg, arguments: arguments, assumed: Set(cfg.headers),
            makeState: { header, common in
                let params = function.blocks[header].parameters.map { $0.type.leafWidths.map { scratch.input(width: $0) } }
                var cells: [String: BV] = [:]
                for (key, width) in common { cells[key] = scratch.input(width: width) }
                found[header] = LoopShape(params: params.map { $0.map(\.width) }, cells: common)
                return HeaderState(parameters: params, cells: cells)
            }, stack: [])
        self.shapes = found
        for header in cfg.headers where found[header] == nil {
            throw SILError.unsupported("loop header \(function.blocks[header].id) is not reached")
        }
        var enclosing: [Int: [Int]] = [:]
        for h in cfg.headers { enclosing[h] = cfg.headers.filter { $0 != h && cfg.loopBodies[$0]!.contains(h) } }
        self.enclosing = enclosing
        for a in out.arrivals {
            _ = try Self.flatten(a.parameters, a.cells, shape: found[a.target]!, name: function.blocks[a.target].id)
        }
    }

    /// The headers whose state is a free variable when `origin` is checked: the loop itself, the loops around it, and
    /// the loops that run before it on every path (their exit values feed the loop). A loop that may run before
    /// `origin` without dominating it would make the values reaching `origin` depend on a path the circuit lacks,
    /// so that shape is rejected.
    func assumedHeaders(for origin: Int) throws -> [Int] {
        var set: Set<Int> = [origin]
        for h in cfg.headers where h != origin && cfg.dominates(h, origin) { set.insert(h) }
        for h in Array(set) { set.formUnion(enclosing[h]!) }
        for h in cfg.headers where !set.contains(h) && forwardReaches(h, origin) {
            throw SILError.unsupported(
                "loop \(name(h)) may run before loop \(name(origin)) without dominating it (conditionally executed loop before another loop)"
            )
        }
        return set.sorted()
    }

    private func forwardReaches(_ from: Int, _ to: Int) -> Bool {
        var seen: Set<Int> = [from]
        var work = [from]
        while let n = work.popLast() {
            for m in cfg.successors[n] where !cfg.backEdges.contains(BlockEdge(from: n, to: m)) && seen.insert(m).inserted {
                if m == to { return true }
                work.append(m)
            }
        }
        return false
    }

    static func flatten(_ params: [[BV]], _ cells: [String: BV], shape: LoopShape, name: String) throws -> [BV] {
        var flat = params.flatMap { $0 }
        guard flat.map(\.width) == shape.params.flatMap({ $0 }) else { throw SILError.invalid("state shape mismatch at \(name)") }
        for (key, width) in shape.cells {
            guard let v = cells[key], v.width == width else {
                throw SILError.unsupported("stack cell \(key) is not tracked on every path to loop header \(name)")
            }
            flat.append(v)
        }
        return flat
    }

    func headerState(_ variables: [BV], header: Int) -> HeaderState {
        let shape = shapes[header]!
        var offset = 0
        var params: [[BV]] = []
        for widths in shape.params {
            params.append(Array(variables[offset..<(offset + widths.count)]))
            offset += widths.count
        }
        var cells: [String: BV] = [:]
        for (i, cell) in shape.cells.enumerated() { cells[cell.key] = variables[offset + i] }
        return HeaderState(parameters: params, cells: cells)
    }

    func name(_ header: Int) -> String { function.blocks[header].id }

    func info() -> [LoopInfo] {
        cfg.headers.map { h in
            var variables: [LoopVariable] = []
            for (parameter, widths) in zip(function.blocks[h].parameters, shapes[h]!.params) {
                for (k, w) in widths.enumerated() {
                    variables.append(
                        LoopVariable(
                            name: widths.count == 1 ? parameter.id : "\(parameter.id).\(k)",
                            type: widths.count == 1 ? parameter.type.description : "\(parameter.type.description) leaf \(k)",
                            width: w, isStackCell: false))
                }
            }
            for cell in shapes[h]!.cells {
                variables.append(LoopVariable(name: cell.key, type: "stack cell", width: cell.width, isStackCell: true))
            }
            let innermost = !cfg.headers.contains { $0 != h && cfg.loopBodies[h]!.contains($0) }
            return LoopInfo(header: name(h), variables: variables, enclosing: enclosing[h]!.map(name), isInnermost: innermost)
        }
    }

    /// The blocks a circuit is responsible for: everything reachable from the start without crossing a back edge or
    /// entering another loop header.
    func segment(from start: Int) -> Set<Int> {
        var seen: Set<Int> = [start]
        var work = [start]
        while let b = work.popLast() {
            for t in cfg.successors[b] where !cfg.backEdges.contains(BlockEdge(from: b, to: t)) && !cfg.isHeader[t] {
                if seen.insert(t).inserted { work.append(t) }
            }
        }
        return seen
    }

    /// For each block of the segment, the obligations that a trap or undefined behaviour in it falsifies: every
    /// obligation reachable from it (arrivals at headers, returns). A block that only leads to a trap belongs to `exit`.
    func keys(in segment: Set<Int>, origin: Int?) -> [Int: Set<LoopKey>] {
        let final = LoopKey(kind: origin == nil ? .entry : .exit, header: origin ?? 0)
        var keysOf: [Int: Set<LoopKey>] = [:]
        for b in cfg.forwardOrder.reversed() where segment.contains(b) {
            var ks = Set<LoopKey>()
            let terminator = function.blocks[b].terminator
            if case .returned = terminator { ks.insert(final) }
            for name in terminator.successorBlocks {
                let t = cfg.index[name]!
                if cfg.backEdges.contains(BlockEdge(from: b, to: t)) {
                    ks.insert(LoopKey(kind: .step, header: t))
                } else if cfg.isHeader[t] {
                    ks.insert(LoopKey(kind: .initialization, header: t))
                } else {
                    ks.formUnion(keysOf[t] ?? [])
                }
            }
            keysOf[b] = ks.isEmpty ? [final] : ks
        }
        return keysOf
    }
}

extension SILVerifier {
    /// Lists the loops of a function with the state each header carries, so that invariants can be written.
    /// Throws `SILError.unsupported` for irreducible control flow or (with loops) constructs the encoder does not model.
    package static func loops(of symbol: String, in module: SILModule) throws -> [LoopInfo] {
        try CFG(module.function(symbol)).headers.isEmpty ? [] : LoopPlan(symbol: symbol, module: module).info()
    }

    /// Verifies a function with reducible loops by cutting every loop at its header and checking, for each loop,
    /// loop-free obligations with `SFProve.prove` (each answer is RUP-checked like any other proof):
    ///
    /// * INIT(h): on every path that arrives at header `h` from outside its loop, the invariant holds and nothing
    ///   trapped before.
    /// * STEP(h): from *any* state satisfying `h`'s invariant (and `requires`), one pass through the body either
    ///   re-establishes the invariant at the back edge or ends in a return/other loop, without a trap or undefined
    ///   behaviour.
    /// * EXIT(h): from any such state, every path that leaves the loop reaches the return with `ensures`, without trap.
    /// * ENTRY: paths from the entry to a return that cross no loop.
    /// * TERMINATION(h), only for loops with a `LoopVariant`: the unsigned rank strictly decreases on every back edge.
    ///
    /// Invariants are only ever assumed (never believed unchecked): each one is established by INIT/STEP, so a wrong
    /// invariant fails with a counterexample that names the obligation. Without variants the result states
    /// `partialCorrectnessProved` only: termination is not proved.
    ///
    /// `ensures` receives the arguments and the result leaves (one element for a scalar result).
    /// Every loop needs an invariant; an invariant or variant for a block that is not a loop header is an error.
    package static func proveLoopFunction(
        _ symbol: String,
        in module: SILModule,
        loopInvariants: [LoopInvariant],
        variants: [LoopVariant] = [],
        conflictBudget: Int = 1_000_000,
        requires: (CNFBuilder, [BV]) -> Int32 = { c, _ in c.trueLit },
        ensures: (CNFBuilder, [BV], [BV]) -> Int32 = { c, _, _ in c.trueLit }
    ) throws -> LoopProofResult {
        let plan = try LoopPlan(symbol: symbol, module: module)
        let function = plan.function, cfg = plan.cfg
        let infos = plan.info()

        func header(_ name: String, _ what: String) throws -> Int {
            guard let i = cfg.index[name], cfg.isHeader[i] else {
                throw SILError.invalid("\(what) names \(name), which is not a loop header of \(symbol) (loops: \(infos.map(\.header)))")
            }
            return i
        }
        var invariants: [Int: (CNFBuilder, LoopState) -> Int32] = [:]
        for inv in loopInvariants {
            let h = try header(inv.header, "invariant")
            guard invariants[h] == nil else { throw SILError.invalid("two invariants for \(inv.header)") }
            invariants[h] = inv.holds
        }
        for h in cfg.headers where invariants[h] == nil {
            throw SILError.invalid("no invariant for loop \(plan.name(h)) of \(symbol) (loops: \(infos.map(\.header)))")
        }
        var ranks: [Int: (CNFBuilder, LoopState) -> BV] = [:]
        for v in variants {
            let h = try header(v.header, "variant")
            guard infos[cfg.headers.firstIndex(of: h)!].isInnermost else {
                throw SILError.unsupported("variant for \(v.header): only innermost loops can have a ranking function")
            }
            guard ranks[h] == nil else { throw SILError.invalid("two variants for \(v.header)") }
            ranks[h] = v.rank
        }

        let argumentWidths = function.parameterWidths

        func check(origin: Int?, key: LoopKey, segment: Set<Int>, keysOf: [Int: Set<LoopKey>]) throws -> LoopObligation {
            let assumed = try origin.map(plan.assumedHeaders) ?? []
            let widths = argumentWidths + assumed.flatMap { plan.shapes[$0]!.widths }
            var approximate = false
            var verdict = try SFProve.prove(inputWidths: widths, conflictBudget: conflictBudget) { c, inputs in
                let arguments = Array(inputs[0..<argumentWidths.count])
                var states: [Int: [BV]] = [:]
                var offset = argumentWidths.count
                for g in assumed {
                    let n = plan.shapes[g]!.widths.count
                    states[g] = Array(inputs[offset..<(offset + n)])
                    offset += n
                }
                func loopState(_ h: Int, _ variables: [BV]) throws -> LoopState {
                    var outer: [String: [BV]] = [:]
                    for g in plan.enclosing[h]! {
                        guard let s = states[g] else {
                            throw SILError.unsupported("state of enclosing loop \(plan.name(g)) is not available at \(plan.name(h))")
                        }
                        outer[plan.name(g)] = s
                    }
                    return LoopState(arguments: arguments, variables: variables, enclosing: outer)
                }
                let out = try SILEncoder(module: module, builder: c).run(
                    function, cfg: cfg, arguments: arguments, assumed: Set(assumed),
                    makeState: { h, _ in
                        guard let s = states[h] else { throw SILError.invalid("no state for \(plan.name(h))") }
                        return plan.headerState(s, header: h)
                    }, stack: [])
                approximate = approximate || !out.approximations.isEmpty

                var assumption = c.and(function.inputAssumption(c, arguments), requires(c, arguments))
                for g in assumed {
                    assumption = c.and(assumption, invariants[g]!(c, try loopState(g, states[g]!)))
                    // Every real visit of a header follows a forward edge whose condition does not depend on the header's own state.
                    if let entered = out.entryConditions[g] { assumption = c.and(assumption, entered) }
                }

                var claim = c.trueLit
                if key.kind == .termination {
                    let rank = ranks[key.header]!
                    let current = rank(c, try loopState(key.header, states[key.header]!))
                    for a in out.arrivals where a.isBackEdge && a.target == key.header && segment.contains(a.source) {
                        let vars = try LoopPlan.flatten(a.parameters, a.cells, shape: plan.shapes[a.target]!, name: plan.name(a.target))
                        let next = rank(c, try loopState(a.target, vars))
                        guard next.width == current.width else {
                            throw SILError.invalid("variant of \(plan.name(key.header)) has inconsistent widths")
                        }
                        claim = c.and(claim, c.or(-a.condition, c.ult(next, current)))
                    }
                } else {
                    for e in out.traps + out.undefineds where segment.contains(e.block) && keysOf[e.block]!.contains(key) {
                        claim = c.and(claim, -e.condition)
                    }
                    for a in out.arrivals where segment.contains(a.source) {
                        guard LoopKey(kind: a.isBackEdge ? .step : .initialization, header: a.target) == key else { continue }
                        let vars = try LoopPlan.flatten(a.parameters, a.cells, shape: plan.shapes[a.target]!, name: plan.name(a.target))
                        claim = c.and(claim, c.or(-a.condition, invariants[a.target]!(c, try loopState(a.target, vars))))
                    }
                    if key.kind == (origin == nil ? .entry : .exit) {
                        for r in out.returns where segment.contains(r.block) {
                            claim = c.and(claim, c.or(-r.condition, ensures(c, arguments, r.leaves)))
                        }
                    }
                }
                return c.or(-assumption, claim)
            }
            if case .counterexample = verdict, approximate { verdict = .unknown }
            var counterexample: LoopCounterexample?
            if case .counterexample(let values) = verdict {
                var states: [String: [UInt64]] = [:]
                var offset = argumentWidths.count
                for g in assumed {
                    let n = plan.shapes[g]!.widths.count
                    states[plan.name(g)] = Array(values[offset..<(offset + n)])
                    offset += n
                }
                counterexample = LoopCounterexample(arguments: Array(values[0..<argumentWidths.count]), states: states)
            }
            return LoopObligation(
                kind: key.kind, header: key.kind == .entry ? nil : plan.name(key.header),
                origin: origin.map(plan.name) ?? "entry", verdict: verdict, counterexample: counterexample)
        }

        var obligations: [LoopObligation] = []
        let origins: [Int?] = [nil] + cfg.headers.map { Optional($0) }
        for origin in origins {
            let segment = plan.segment(from: origin ?? 0)
            let keysOf = plan.keys(in: segment, origin: origin)
            for key in Set(keysOf.values.joined()).sorted() {
                obligations.append(try check(origin: origin, key: key, segment: segment, keysOf: keysOf))
            }
        }
        for h in ranks.keys.sorted() {
            let segment = plan.segment(from: h)
            obligations.append(try check(origin: h, key: LoopKey(kind: .termination, header: h), segment: segment, keysOf: [:]))
        }

        let partial = obligations.allSatisfy { $0.kind == .termination || $0.verdict == .proved }
        let terminated =
            !cfg.headers.isEmpty
            && cfg.headers.allSatisfy { h in
                ranks[h] != nil && obligations.contains { $0.kind == .termination && $0.header == plan.name(h) && $0.verdict == .proved }
            }
        return LoopProofResult(loops: infos, obligations: obligations, partialCorrectnessProved: partial, terminationProved: terminated)
    }
}
