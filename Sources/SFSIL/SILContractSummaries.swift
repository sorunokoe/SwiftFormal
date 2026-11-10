package import SFBV

/// A callee's contract, proved earlier in the same run, that stands for the callee at its call sites (plan item H4,
/// assume-guarantee as Kani's `stub_verified`). Only for a callee whose proof covers every call: no loops (whose proof
/// is partial correctness), no recursion, nothing written back through addresses, no `throws`.
package struct ContractSummary: Sendable {
    /// `g_requires` and `g_ensures`; nil when the contract has no such half.
    package var requires: String?
    package var ensures: String?
    /// The arguments of `g_ensures` from `g`'s arguments and result leaves (a method's `self` moves behind the result).
    package var ensuresArguments: @Sendable ([BV], [BV]) -> [BV]
    /// What the callee's proof took on trust (`Assumptions`): a proof that uses the contract takes it on trust too.
    package var assumptions: [String]

    package init(
        requires: String?, ensures: String?, assumptions: [String] = [], ensuresArguments: @escaping @Sendable ([BV], [BV]) -> [BV]
    ) {
        self.requires = requires
        self.ensures = ensures
        self.assumptions = assumptions
        self.ensuresArguments = ensuresArguments
    }
}

extension SILEncoder {
    /// A call of `target` from inside `stack`: inlined, or replaced by its contract when it has a summary.
    func encodeCall(_ target: String, _ arguments: [BV], stack: [String]) throws -> EncodedFunction {
        guard let summary = contractSummaries[target] else { return try encode(symbol: target, arguments: arguments, stack: stack) }
        return try summarize(target, summary, arguments, stack: stack)
    }

    /// A call of `symbol` replaced by its contract. The callee's proof says: for valid arguments that satisfy
    /// `requires`, it does not trap and returns a result satisfying `ensures`. So
    /// * the call traps unless the arguments are valid, `requires` holds and does not trap itself (asserted at the
    ///   call: a stronger claim than the callee's real behaviour, never a weaker one);
    /// * the result is a fresh value, and `assumption` gains "the precondition fails, or `ensures` holds of it without
    ///   trapping". The real result always satisfies this, so the assumption excludes no real execution and is never
    ///   vacuous: for any arguments some fresh value satisfies it.
    /// The caller's claim must be read under `assumption` (`EncodedFunction.assumption`).
    func summarize(_ symbol: String, _ summary: ContractSummary, _ arguments: [BV], stack: [String]) throws -> EncodedFunction {
        let function = try module.function(symbol)
        guard function.writtenBackWidths.isEmpty, function.errorType == nil, arguments.map(\.width) == function.parameterWidths
        else { throw SILError.invalid("\(symbol) cannot be summarized by its contract") }
        var approximations: Set<String> = []
        var precondition = function.inputAssumption(c, arguments)
        if let requires = summary.requires {
            let r = try encode(symbol: requires, arguments: arguments, stack: stack + [symbol])
            guard r.result.width == 1 else { throw SILError.invalid("\(requires) does not return Bool") }
            approximations.formUnion(r.approximations)
            precondition = c.and(precondition, c.and(c.and(-r.trap, -r.undefined), r.result.bits[0]))
        }
        let results = function.resultWidths.map { c.input(width: $0) }
        if let ensures = summary.ensures {
            let e = try encode(symbol: ensures, arguments: summary.ensuresArguments(arguments, results), stack: stack + [symbol])
            guard e.result.width == 1 else { throw SILError.invalid("\(ensures) does not return Bool") }
            approximations.formUnion(e.approximations)
            let holds = c.and(c.and(-e.trap, -e.undefined), e.result.bits[0])
            assumption = c.and(assumption ?? c.trueLit, c.or(-precondition, holds))
        }
        summarizedCalls.insert(symbol)
        for assumption in summary.assumptions { Assumptions.note(assumption) }
        return EncodedFunction(
            result: BV(bits: results.flatMap(\.bits)), results: results, trap: -precondition, undefined: c.falseLit,
            trapSites: [TrapSite(kind: .call(id: nil, callee: summary.requires ?? symbol, inner: []), condition: -precondition)],
            approximations: approximations
        )
    }
}

extension SILFunction {
    /// No loop in this function's own blocks (callees are not looked at); false when its control flow is irreducible.
    package var isLoopFree: Bool { (try? CFG(self))?.headers.isEmpty ?? false }
}

extension SILModule {
    /// Every function that `symbols` reach through `function_ref`, transitively (witnesses are not followed).
    package func callees(of symbols: [String]) -> Set<String> {
        var seen: Set<String> = []
        var queue = symbols
        while let symbol = queue.popLast() {
            guard let function = try? function(symbol) else { continue }
            for block in function.blocks {
                for case .functionRef(_, let callee) in block.instructions where seen.insert(callee).inserted { queue.append(callee) }
            }
        }
        return seen
    }
}
