// Self-test input: the shape of Sources/SFSemantics/S0.swift's builtin names. Never compiled.

package enum S0Op {
    case add, saddOverflow

    package var base: String {
        switch self {
        case .add: "add"
        case .saddOverflow: "sadd_with_overflow"
        }
    }
}
