// Where the encoder was when it gave up (plan item U7). `SILError` stays a plain message; the encoder keeps, beside
// it, the chain of functions it was inlining and the instruction it was encoding in each, so a reporter can join them
// with the debug info (the parser never sees `loc`) and say where an unsupported construct is.

/// One function the encoder was inside when an error was thrown, and the instruction it was encoding there.
package struct SILTrailFrame: Equatable, Sendable {
    /// The mangled symbol of the function.
    package let function: String
    /// The result of the instruction being encoded (`%7`), or nil before the first one, at a terminator, or at an
    /// instruction without a result.
    package var value: String?

    package init(function: String, value: String? = nil) {
        self.function = function
        self.value = value
    }
}

extension SILEncoder {
    /// Opens a frame for `function` (called when `run` starts); returns its depth.
    func enterTrail(_ function: String) -> Int {
        let depth = trail.count
        trail.append(SILTrailFrame(function: function))
        return depth
    }

    /// The frame at `depth` is now at `instruction`; frames of callees that finished, or that failed and were
    /// recovered from, are dropped.
    func moveTrail(_ depth: Int, to instruction: Instruction?) {
        guard depth < trail.count else { return }
        trail.removeSubrange((depth + 1)...)
        trail[depth].value = instruction?.resultValue
    }

    /// The function at `depth` finished: its frame and those of its callees are dropped.
    func leaveTrail(_ depth: Int) {
        guard depth < trail.count else { return }
        trail.removeSubrange(depth...)
    }
}

extension Instruction {
    /// The value this instruction defines, which the debug info locates; nil when it defines none.
    var resultValue: String? {
        switch self {
        case .literal(let r, _, _), .retype(let r, _, _), .builtin(let r, _, _), .floatBuiltin(let r, _, _), .makeAggregate(let r, _, _),
            .extract(let r, _, _, _), .functionRef(let r, _), .apply(let r, _, _, _, _, _), .allocStack(let r, _),
            .load(let r, _), .elementAddress(let r, _, _, _), .alias(let r, _), .allocArray(let r, _, _),
            .globalValue(let r, _), .refTailAddress(let r, _, _), .arrayStorage(let r, _), .indexAddress(let r, _, _),
            .headerAddress(let r), .makeEnum(let r, _, _, _), .enumPayload(let r, _, _), .selectEnum(let r, _, _, _, _),
            .enumPayloadAddress(let r, _, _, _), .existentialBox(let r, _), .boxedValueAddress(let r), .existentialAddress(let r, _, _),
            .stringLiteral(let r, _),
            .allocObject(let r, _), .enumTag(let r, _), .closure(let r, _, _, _), .globalAddress(let r, _, _),
            .pointerToAddress(let r, _, _):
            r
        case .beginCOW(let flag, _, _): flag
        case .beginApply(let address, _, _, _, _): address
        case .condFail, .store, .injectEnum, .copyAddress, .ignored: nil
        }
    }
}
