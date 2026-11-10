/// One way a function can trap, and the condition under which it does (plan item H2: typed, never parsed back).
package struct TrapSite: Sendable {
    package let kind: TrapKind
    package let condition: Int32
}

/// Where a trap is: what the reporter needs to name it and find its source position.
package indirect enum TrapKind: Sendable {
    /// A `cond_fail` on `operand` (for example `%11`): an overflow check, a precondition.
    case condFail(operand: String)
    /// A call that traps: `id` is the `apply` (nil when logic runs the callee for a summary, such as a `description`
    /// witness), `inner` the callee's own trap sites, conditions in the same formula.
    case call(id: String?, callee: String, inner: [TrapSite])
    /// A check inside a summarized standard-library call (`Array.subscript`), with its message.
    case stdlib(id: String, message: String)
    /// A block ending in `unreachable` (after a call to a failure function).
    case unreachable(block: String)

    /// Names the site the same way in every encoding of the function (no literals), to tell sites apart.
    package var key: String {
        switch self {
        case .condFail(let operand): "cond_fail \(operand)"
        case .call(let id, let callee, _): "call \(id ?? "-") \(callee)"
        case .stdlib(let id, let message): "stdlib \(id) \(message)"
        case .unreachable(let block): "unreachable \(block)"
        }
    }
}
