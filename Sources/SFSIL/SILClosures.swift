import Foundation

// Closures as values. Logic runs only a closure literal (`SILClosureCalls.swift`): calling any other closure is an
// indirect call, which is rejected. A closure can
// still be created, stored, copied, passed and destroyed. Destroying it releases what it captured, which can run the
// deinit of a captured object; that is safe while no deinit of the read modules calls code or can trap, and otherwise
// an assumption that names those deinits (`SILDeinits.swift`).

extension TypeContext {
    /// The layout of every closure: one handle; a literal's handle names its body and captures (`SILClosureCalls.swift`).
    static let closure = ValueType.opaque(name: "closure")

    /// A function type such as `@Sendable (String) -> [String]` or `@callee_guaranteed () -> @out τ_0_0 for <T>`: an
    /// arrow outside any brackets (`Array<() -> ()>` is an array).
    static func isFunctionType(_ t: String) -> Bool {
        // `(() -> ())`, as in `(() -> ())?`: one parenthesized type, not a tuple.
        if t.hasPrefix("("), let close = matchingClose(Substring(t), open: "(", close: ")"), close == t.index(before: t.endIndex) {
            let inner = String(t.dropFirst().dropLast())
            if splitTopLevel(inner).count == 1, isFunctionType(inner) { return true }
        }
        var depth = 0
        var previous: Character = " "
        for character in t {
            switch character {
            case "<", "(", "[": depth += 1
            case ")", "]": depth -= 1
            case ">" where previous == "-": if depth == 0 { return true }
            case ">": depth -= 1
            default: break
            }
            previous = character
        }
        return false
    }

    /// `closure` when values of the function type `t` may be modelled (see the top of this file).
    func closureType(_ t: String) throws(SILError) -> ValueType {
        guard closureDestroysWithoutModuleCode(t) else {
            throw SILError.unsupported(
                "type \(t): destroying a closure may run a deinit of this module that calls code or can trap"
                    + (t.contains("@convention(block)") ? " (Objective-C block)" : deinitRefusalNote))
        }
        return Self.closure
    }

    /// A `@noescape` closure is trivial: it is never released, so destroying it runs no deinit (its captures are borrowed).
    func closureDestroysWithoutModuleCode(_ t: String) -> Bool {
        !t.contains("@convention(block)") && (t.contains("@noescape ") || acceptsUnknownReleases())
    }
}
