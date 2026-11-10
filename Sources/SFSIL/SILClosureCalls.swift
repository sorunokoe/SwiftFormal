import Foundation
import SFBV
import SFCNF
import SFSemantics

// Reading guide
// Calling a closure literal (mapper verification, phase 4). A closure is an opaque handle everywhere else
// (`SILClosures.swift`); here a closure whose body and captured values are known is run.
//
// What is known. A `thin_to_thick_function` or `partial_apply` of a `function_ref` makes a closure literal. When each
// captured value is a plain value (a `let`; a captured `var` is a box, an address, and is refused), the literal gets an
// identity of its own: its one 64-bit leaf is written in named constants (`CNFBuilder.namedConstant`), and the encoder
// records the body and the captured values under those bits (`SILEncoder.knownClosures`). Every circuit over the
// leaf folds it like the constant it stands for, so the bits travel only along copies of the literal: arguments, block
// arguments without a join, aliases (`convert_function`, `convert_escape_to_noescape`). Captured values are copied
// when the closure is made, as Swift does for a `let`, so running the body later on them is running the closure.
//
// Where it is run. `apply %f(…)` through a closure value (`$@noescape @callee_guaranteed (Int) -> Int`): the body is
// inlined on the arguments and the captures, with its traps. This is a rule's helper that takes a trailing closure,
// called with a literal: `helper { $0 + k }`. The collection calls of `SILClosureCollections.swift` run a literal the
// same way. A closure value without an identity (a stored property, a parameter of the scanned function, a join of
// two closures) stays `unsupported`, as does a body that can throw.
// Tests: Tests/SFSILTests/SILClosureCallTests.swift.

/// A closure literal: the function its body is, and the leaves of each captured value (nil when one is not a value).
struct KnownClosure {
    let symbol: String
    let captures: [[BV]]?
}

extension SILEncoder {
    /// A leaf naming a new closure literal (see the top of this file).
    func closureIdentity(_ closure: KnownClosure) -> BV {
        let k = knownClosures.count + 1
        let bits = (0..<16).map { c.namedConstant((k >> $0) & 1 == 1) } + Array(repeating: c.falseLit, count: 48)
        knownClosures[bits] = closure
        return BV(bits: bits)
    }
}

extension SILModule {
    /// The function a closure literal of `symbol` runs: `symbol`, or its `closureKey` (`closureText`) for a
    /// `@substituted` body or one with an error result.
    func closureBody(_ symbol: String) -> String {
        guard let header = header(of: symbol), let colon = header.range(of: " : $") else { return symbol }
        let type = header[colon.upperBound...]
        return type.contains("@substituted <") || type.contains("@error") ? Self.closureKey(symbol) : symbol
    }
}

/// `@noescape @callee_guaranteed (Int) -> Int` -> `@convention(thin) (Int) -> Int`: a closure's type as a signature
/// `FunctionSignature` reads; nil for a generic or `@substituted` closure type.
func thickSignature(_ type: String) -> String? {
    var t = Substring(type)
    let attributes = ["@noescape ", "@callee_guaranteed ", "@Sendable ", "@escaping "]
    while let attribute = attributes.first(where: { t.hasPrefix($0) }) { t = t.dropFirst(attribute.count) }
    guard t.hasPrefix("("), !t.hasPrefix("(@substituted") else { return nil }
    return "@convention(thin) " + t
}

extension FunctionRun {
    /// The leaf of a new closure: an identity when every captured value is known, else the opaque constant 0.
    func closureLeaf(_ callee: String, _ captures: [String]) -> BV {
        guard case .function(let symbol)? = try? lookup(callee) else { return c.constant(0, width: 64) }
        let values = captures.map { capture -> [BV]? in
            switch try? lookup(capture) {
            case .scalar(let s): [s]
            case .aggregate(let type, let l): type == TypeContext.keyPath ? nil : l
            default: nil
            }
        }
        let known = values.allSatisfy { $0 != nil } ? values.compactMap { $0 } : nil
        return encoder.closureIdentity(KnownClosure(symbol: module.closureBody(symbol), captures: known))
    }

    /// The closure literal the value `name` is, if it is one.
    func knownClosure(_ name: String) -> KnownClosure? {
        guard let value = try? lookup(name), let l = leaves(value), l.count == 1 else { return nil }
        return encoder.knownClosures[l[0].bits]
    }

    /// Runs `closure` on the leaves of its arguments (laid out as its body's parameters before the captures), when
    /// `condition` holds; its traps count under it.
    func callClosure(_ closure: KnownClosure, _ arguments: [BV], at id: String?, when condition: Int32? = nil) throws
        -> EncodedFunction
    {
        let body = try module.function(closure.symbol)
        guard let captures = closure.captures else {
            throw SILError.unsupported("a closure that captures a variable or an object (\(closure.symbol))")
        }
        let captureConventions = body.conventions.suffix(captures.count)
        guard captureConventions.count == captures.count, captureConventions.allSatisfy({ $0 == .value }),
            !body.returnsObject, body.errorType == nil
        else { throw SILError.unsupported("a closure that captures a variable or an object (\(closure.symbol))") }
        return try call(closure.symbol, arguments + captures.flatMap { $0 }, at: id, when: condition)
    }

    /// `apply %f(…)` through the closure value `callee`: run when it is a literal (see the top of this file).
    func applyClosureValue(_ callee: String, _ request: SummarizedCall) throws {
        guard let closure = knownClosure(callee) else {
            throw SILError.unsupported("indirect call through a closure that is not a literal of this function (\(callee))")
        }
        guard request.substitutions.isEmpty else { throw SILError.unsupported("a generic call through a closure at \(request.id)") }
        let arguments = try callArguments(request.names, request.conventions)
        let result = try callClosure(closure, arguments, at: request.id)
        guard result.results.map(\.width) == request.type.leafWidths else {
            throw SILError.invalid("closure result type mismatch at \(request.id)")
        }
        try writeBack(result.writtenBack, names: request.names, conventions: request.conventions)
        env[request.id] = make(request.type, result.results)
    }
}
