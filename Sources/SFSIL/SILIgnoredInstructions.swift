// The instructions logic reads as doing nothing (plan item H1). A wrongly ignored instruction is a false proof, so
// this list is an allow-list, each entry with why it is harmless, and `SILIgnoredInstructionTests` pins it: adding an
// entry means changing that test too, in review.

/// One reviewed instruction that has no effect logic needs to model.
package struct IgnoredInstruction: Sendable, Equatable {
    package enum Match: Sendable, Equatable {
        /// The line starts with this text (the instruction name and a space).
        case prefix(String)
        /// The line is exactly this text.
        case line(String)
        /// The line contains this text.
        case contains(String)
    }

    package let match: Match
    package let reason: String

    /// Every ignored instruction.
    package static let reviewed: [IgnoredInstruction] = [
        .init(match: .prefix("debug_value "), reason: "debug info: names a value for the debugger"),
        .init(match: .line("debug_step"), reason: "debug info: a stepping point for the debugger"),
        .init(match: .prefix("dealloc_stack "), reason: "frees a stack slot; its contents are never read again"),
        .init(match: .prefix("destroy_addr "), reason: "destroys a value of a supported type: its deinit runs no code of the read modules"),
        .init(
            match: .prefix("end_access "),
            reason: "ends an access; a [dynamic] one is accepted only where it cannot conflict (`checkDynamicAccesses`)"),
        .init(
            match: .prefix("strong_release "), reason: "reference counting: no deinit of the read modules runs code, or classes are refused"
        ),
        .init(match: .prefix("fix_lifetime "), reason: "keeps a value alive; changes no value"),
        .init(match: .prefix("dealloc_ref "), reason: "frees an object after its deinit, which runs no code of the read modules"),
        .init(
            match: .prefix("dealloc_stack_ref "),
            reason: "frees a stack-promoted object after its deinit, which runs no code of the read modules"),
        .init(
            match: .prefix("retain_value "),
            reason: "reference counting of supported values: their storage belongs to the standard library, whose deinits do not trap"),
        .init(match: .prefix("release_value "), reason: "as retain_value: closures only while no deinit of the read modules runs code"),
        .init(match: .prefix("strong_retain "), reason: "reference counting: changes no value"),
        .init(match: .contains(" = builtin \"willThrow\"("), reason: "a hook for debuggers before a `throw` (plan item L6)"),
        .init(
            match: .prefix("alloc_global "),
            reason: "allocates a global's storage in its initializer; it holds no value until stored (`SILGlobals.swift`)"),
    ]

    /// Whether `line` is one of the reviewed instructions.
    package static func matches(_ line: String) -> Bool {
        reviewed.contains { entry in
            switch entry.match {
            case .prefix(let text): line.hasPrefix(text)
            case .line(let text): line == text
            case .contains(let text): line.containsText(text)
            }
        }
    }
}
