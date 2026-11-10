package import SFBV
import SFCNF
import SFProve

/// What bounded unrolling found (plan item L3, bounded model checking as CBMC's `--unwind`).
package enum UnwindResult: Equatable {
    /// Inputs on which the function traps (or hits undefined behaviour) within the bound: a real execution.
    case traps([UInt64])
    /// No trap within the bound. Not a proof: a longer run may still trap.
    case noneWithin
    /// The solver gave up, or the trap rests on a summarized call whose result logic does not know.
    case unknown
}

extension SILVerifier {
    /// Follows `symbol` through at most `times` visits to its loop headers (for one loop: `times` iterations; nested
    /// loops share the count) and looks for an input that traps.
    ///
    /// A run is deterministic, so at each step it is at one loop header at most. Step 0 runs the function from its
    /// entry, every header unreached, and records where it first arrives. Each later step enters every header with the
    /// state the step before arrived with, under the condition that it arrived there; the code before the first loop
    /// runs again, but its arrivals are dropped (the run left it in step 0), so at most one arrival holds. Each step
    /// follows the run to its next header visit, and a trap found in any step is a trap of that run. Its traps outside
    /// the loops are found again in every step, which changes nothing. A path that reaches a header both from the
    /// entry code and from a loop is followed from the entry only: unrolling may miss runs, never invent one.
    package static func unwind(
        _ symbol: String, in module: SILModule, times: Int, conflictBudget: Int = 1_000_000,
        requires: (CNFBuilder, [BV]) -> Int32 = { c, _ in c.trueLit }
    ) throws -> UnwindResult {
        let function = try module.function(symbol)
        var approximate = false
        let verdict = try SFProve.prove(inputWidths: function.parameterWidths, conflictBudget: conflictBudget) { c, arguments in
            let made = try unwindClaim(symbol, in: module, times: times, builder: c, arguments: arguments)
            approximate = approximate || made.approximate
            return c.or(-c.and(function.inputAssumption(c, arguments), requires(c, arguments)), made.noTrap)
        }
        switch verdict {
        case .proved: return .noneWithin
        case .counterexample(let values): return approximate ? .unknown : .traps(values)
        case .unknown: return .unknown
        }
    }
}

extension SILVerifier {
    /// Proves that `symbol`, a function with one loop, cannot trap, by 2-induction (plan item L3; Donaldson, Haller,
    /// Kroening, Rümmer, SAS 2011). It helps where the header knows too little for an invariant of `true`, such as an
    /// optimized loop whose exit test the compiler moved to the end (`-O` LoopRotate).
    ///
    /// - Base: unrolling the first two header visits finds no trap (`unwind`, which follows every run from the entry
    ///   when there is one loop).
    /// - Step: from any header state whose iteration does not trap and comes back to the header, the next iteration
    ///   does not trap either, including the code after the loop that it may reach.
    ///
    /// Then every iteration of every run is safe: the third follows two safe ones, and so on. Like the invariant proof,
    /// it says nothing about termination. Only for one loop and no `ensures` (the base does not check returns).
    package static func proveByTwoInduction(
        _ symbol: String, in module: SILModule, conflictBudget: Int = 1_000_000,
        requires: (CNFBuilder, [BV]) -> Int32 = { c, _ in c.trueLit }
    ) throws -> Bool {
        let plan = try LoopPlan(symbol: symbol, module: module)
        guard plan.cfg.headers.count == 1, let header = plan.cfg.headers.first else { return false }
        guard try unwind(symbol, in: module, times: 2, conflictBudget: conflictBudget, requires: requires) == .noneWithin else {
            return false
        }
        let function = plan.function
        let loop = plan.segment(from: header)
        let shape = try plan.shape(of: header)
        let arguments = function.parameterWidths.count
        let verdict = try SFProve.prove(inputWidths: function.parameterWidths + shape.widths, conflictBudget: conflictBudget) { c, inputs in
            let encoder = SILEncoder(module: module, builder: c)
            let args = Array(inputs[..<arguments])
            func iteration(_ state: HeaderState) throws -> RunOutput {
                try encoder.run(
                    function, cfg: plan.cfg, arguments: args, assumed: [header], makeState: { _, _ in state }, stack: [])
            }
            let first = try iteration(plan.headerState(Array(inputs[arguments...]), header: header))
            var safe = c.trueLit
            for event in first.traps + first.undefineds where loop.contains(event.block) { safe = c.and(safe, -event.condition) }
            var back: (arrived: Int32, variables: [BV])?
            for arrival in first.arrivals.reversed() where arrival.isBackEdge && loop.contains(arrival.source) {
                let variables = try LoopPlan.flatten(arrival.parameters, arrival.cells, shape: shape, name: plan.name(header))
                back =
                    back.map {
                        (c.or(arrival.condition, $0.arrived), zip(variables, $0.variables).map { c.select(arrival.condition, $0, $1) })
                    }
                    ?? (arrival.condition, variables)
            }
            guard let back else { return c.trueLit }  // the loop never comes back: the base covers every run
            var next = plan.headerState(back.variables, header: header)
            next.reach = back.arrived
            let second = try iteration(next)
            var claim = c.trueLit
            for event in second.traps + second.undefineds where loop.contains(event.block) { claim = c.and(claim, -event.condition) }
            let assumption = c.and(c.and(function.inputAssumption(c, args), requires(c, args)), c.and(safe, back.arrived))
            return c.or(-assumption, claim)
        }
        return verdict == .proved
    }
}

extension LoopPlan {
    /// The state shape of loop header `header`.
    func shape(of header: Int) throws -> LoopShape {
        guard let shape = shapes[header] else { throw SILError.invalid("no state shape for loop header \(name(header))") }
        return shape
    }
}

extension SILVerifier {
    /// The formula `unwind` proves, built into `c` for `arguments`: "no trap within `times` header visits", and whether
    /// it relied on summarized calls. Separate so that its CNF can be hashed (plan item H0).
    package static func unwindClaim(
        _ symbol: String, in module: SILModule, times: Int, builder c: CNFBuilder, arguments: [BV]
    ) throws -> (noTrap: Int32, approximate: Bool) {
        let plan = try LoopPlan(symbol: symbol, module: module)
        let entryCode = plan.segment(from: 0)
        let encoder = SILEncoder(module: module, builder: c)
        var approximate = false
        var states: [Int: (reach: Int32, variables: [BV])] = [:]
        var trapped = c.falseLit
        for step in 0...max(times, 0) {
            let current = states
            let out = try encoder.run(
                plan.function, cfg: plan.cfg, arguments: arguments, assumed: Set(plan.cfg.headers),
                makeState: { header, _ in
                    let entered = try current[header] ?? (c.falseLit, plan.shape(of: header).widths.map { c.constant(0, width: $0) })
                    var state = plan.headerState(entered.variables, header: header)
                    state.reach = entered.reach
                    return state
                }, stack: [])
            approximate = approximate || !out.approximations.isEmpty
            for event in out.traps + out.undefineds { trapped = c.or(trapped, event.condition) }
            var next: [Int: (reach: Int32, variables: [BV])] = [:]
            for arrival in out.arrivals.reversed() where step == 0 || !entryCode.contains(arrival.source) {
                let variables = try LoopPlan.flatten(
                    arrival.parameters, arrival.cells, shape: try plan.shape(of: arrival.target), name: plan.name(arrival.target))
                guard let later = next[arrival.target] else {
                    next[arrival.target] = (arrival.condition, variables)
                    continue
                }
                next[arrival.target] = (
                    c.or(arrival.condition, later.reach), zip(variables, later.variables).map { c.select(arrival.condition, $0, $1) }
                )
            }
            states = next
        }
        return (-trapped, approximate)
    }
}
