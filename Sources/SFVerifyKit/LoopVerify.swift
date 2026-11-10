import SFBV
import SFCNF
import SFSIL

extension Verifier {
    /// Plan item L3: a function with loops, proved with the invariant `true` at every loop header (and, for `for-in`, the
    /// iterator's well-formedness, plan item L4). Values the loop
    /// changes are unknown at the header (any value), values from before the loop stay exact. A proof says: every run
    /// that ends does not trap and meets the contract (partial correctness); termination is not proved (owner
    /// decision 5). A failed proof is `undecided`, never `mayTrap`: its counterexample may start from a header state no
    /// run reaches.
    static func verifyLoops(_ report: inout FunctionReport, _ subject: RefutedFunction, options: VerifyOptions) throws {
        let (info, function, module, specs) = (subject.info, subject.function, subject.module, subject.specs)
        if specs.ensures != nil, info.isMethod || !function.conventions.allSatisfy({ $0 == .value }) {
            throw SILError.unsupported("loops in a function whose ensures takes self or inout values")
        }
        // `true` at each header, and the well-formedness of each `for-in` iterator the header carries (plan item L4), a
        // candidate the proof checks like any invariant.
        let invariants = try SILVerifier.iteratorInvariants(of: info.symbol, in: module)
        // A requires that cannot be encoded assumes nothing, and an ensures that cannot be encoded fails: both only make
        // the claim stronger, never weaker.
        let requires: (CNFBuilder, [BV]) -> Int32 = { c, inputs in
            guard let spec = specs.requires,
                let e = try? SILEncoder(module: module, builder: c).encode(symbol: spec.symbol, arguments: inputs),
                e.result.width == 1
            else { return c.trueLit }
            return c.and(e.result.bits[0], c.and(-e.trap, -e.undefined))
        }
        let ensures: (CNFBuilder, [BV], [BV]) -> Int32 = { c, inputs, results in
            guard let spec = specs.ensures else { return c.trueLit }
            guard let e = try? SILEncoder(module: module, builder: c).encode(symbol: spec.symbol, arguments: inputs + results),
                e.result.width == 1
            else { return c.falseLit }
            return c.and(e.result.bits[0], c.and(-e.trap, -e.undefined))
        }
        let result = try SILVerifier.proveLoopFunction(
            info.symbol, in: module, loopInvariants: invariants, conflictBudget: options.conflictBudget, requires: requires,
            ensures: ensures)
        if result.partialCorrectnessProved {
            report.status = report.hasContract ? .contractHolds : .safe
            report.detail = "has loops: proved for every run that ends (termination is not proved)"
            report.proofScope = FunctionReport.partialCorrectness
        } else if specs.ensures == nil,
            try SILVerifier.proveByTwoInduction(info.symbol, in: module, conflictBudget: options.conflictBudget, requires: requires)
        {
            report.status = report.hasContract ? .contractHolds : .safe
            report.detail = "has a loop: proved by 2-induction for every run that ends (termination is not proved)"
            report.proofScope = FunctionReport.partialCorrectness
        } else if options.unwind > 0,
            case .traps(let values) = try SILVerifier.unwind(
                info.symbol, in: module, times: options.unwind, conflictBudget: options.conflictBudget, requires: requires)
        {
            report.status = report.hasContract ? .contractFails : .mayTrap
            report.counterexample = unrolledCounterexample(values, info: info, function: function, bound: options.unwind)
        } else {
            report.status = .undecided
            report.category = "loops"
            report.detail =
                "has loops: not proved with what logic knows at each loop header (\(result.summary))"
                + (options.unwind > 0 ? "; no input traps within \(options.unwind) iterations" : "")
        }
    }

    /// A trap found by unrolling the loops (plan item L3): the inputs, as a call when they are plain values.
    private static func unrolledCounterexample(_ values: [UInt64], info: FunctionInfo, function: SILFunction, bound: Int)
        -> ScanCounterexample
    {
        var example = ScanCounterexample(
            inputs: [], result: nil, failure: "traps within \(bound) iterations of its loops", at: nil, replay: nil)
        let types = leafTypes(info, function)
        ValueRenderer.StandIns.$current.withValue(ValueRenderer.StandIns()) {
            example.inputs = renderInputs(values, info: info, function: function, types: types)
            example.replay = replay(values, info: info, types: types)
        }
        return example
    }
}
