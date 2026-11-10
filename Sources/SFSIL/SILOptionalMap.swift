// Reading guide
// `Optional.map` and `Optional.flatMap` with a closure literal of the calling function (app study round 6, L11: the most
// common shape in the app's rules, `input.value.map { … }`). Closures are opaque values everywhere else
// (`SILClosures.swift`); here the closure is known exactly: the operand of the call is a `thin_to_thick_function` or
// a `partial_apply [on_stack]` of a `function_ref` in the same function, so its body and its captured values are in
// the SIL. The standard library's `map` is `switch self { case .some(let y): return .some(try transform(y)); case
// .none: return .none }` and `flatMap` the same without the `.some` (Swift 6.4 `Optional.swift`; both are generic and
// have no serialized body logic reads), so the call is read as: when `self` is `.some(a)`, the closure's body on `a`
// and the captures (inlined, with its traps under that condition); `.none` otherwise.
//
// The closure body is a `@substituted` generic function (`(@in_guaranteed A, captures…) -> (@out B, @error_indirect
// E) for <A, E, B>`). It is read under the key `symbol#closure`, its header written at the substitution with the
// error result and the error address dropped, which is only done when `E` is `Never`: such a closure cannot throw. A
// closure that can throw, a capture passed by address (a captured `var`), or a closure that is not a literal of the
// calling function stay `unsupported`. `closureText` is shared with the closure calls of `SILClosureCalls.swift` (a
// helper that calls its closure parameter) and `SILClosureCollections.swift` (`Array.map`, `filter`, …).
// Tests: Tests/SFSILTests/SILOptionalMapTests.swift.

import Foundation
import SFSemantics

/// The two `Optional` calls read with a closure literal.
enum OptionalTransform: Sendable {
    case map, flatMap

    static let symbols: [String: OptionalTransform] = [
        "$sSq3mapyqd_0_Sgqd_0_xqd__YKXEqd__YKs5ErrorRd__Ri_d_0_r0_lF": .map,
        "$sSq7flatMapyqd_0_SgABxqd__YKXEqd__YKs5ErrorRd__Ri_d_0_r0_lF": .flatMap,
    ]
}

extension SILModule {
    /// The key a closure body is read under (see the top of this file).
    static func closureKey(_ symbol: String) -> String { symbol + "#closure" }

    /// The header and body of the closure a `closureKey` names, at its substitution and without its error; nil when
    /// `key` is not such a key. The error is dropped only when the closure cannot throw: its type is `Never`
    /// (`@error_indirect Never`, whose address `bb0` takes after the `@out` one), or it is `any Error` and the body
    /// has no `throw` (the closures of `first(where:)`, `contains(where:)`, `allSatisfy`, `compactMap`).
    func closureText(_ key: String) throws(SILError) -> (header: String, body: [String])? {
        guard key.hasSuffix("#closure") else { return nil }
        let symbol = String(key.dropLast("#closure".count))
        guard let header = header(of: symbol), let body = bodyLines(of: symbol), let colon = header.range(of: " : $") else {
            throw SILError.unsupported("no body for the closure \(symbol)")
        }
        let type = String(header[colon.upperBound...].dropLast(2))
        let signature = try Self.closureSignature(type, symbol)
        let (map, parameterText, resultText) = (signature.substitution, signature.parameters, signature.results)
        let results = splitTopLevel(resultText).map { substitutingTypeParameters(map, in: $0) }
        guard results.count == 2, let error = results.last,
            error == "@error_indirect Never" || error == "@error any Error"
        else { throw SILError.unsupported("closure \(symbol) that can throw or returns \(resultText)") }
        // The error address follows the `@out` result's, when the closure has one.
        let errorAddress = error.hasPrefix("@error_indirect ") ? (results[0].hasPrefix("@out ") ? 1 : 0) : nil
        let concrete =
            "\(header[..<colon.lowerBound]) : $@convention(thin) (\(substitutingTypeParameters(map, in: parameterText))) -> \(results[0]) {"
        var lines: [String] = []
        var entry = false
        for raw in body {
            var line = substitutingTypeParameters(map, in: stripComment(raw).trimmingCharacters(in: .whitespaces))
            if line.hasPrefix("throw ") || line.hasPrefix("throw_addr") {
                throw SILError.unsupported("closure \(symbol) that can throw")
            }
            if !entry, line == "bb0:", errorAddress == nil {
                entry = true
            } else if !entry, line.hasPrefix("bb0("), line.hasSuffix("):") {
                line = try Self.closureEntry(line, droppingErrorAt: errorAddress, symbol)
                entry = true
            }
            lines.append(line)
        }
        guard entry else { throw SILError.unsupported("closure \(symbol): no entry block") }
        return (concrete, lines)
    }

    /// The parts of a closure type: `@substituted <…> (…) -> (…) for <…>` or a plain `(…) -> (…)`.
    private struct ClosureSignature {
        var substitution: [String: String] = [:]
        var parameters: String
        var results: String
    }

    private static func closureSignature(_ type: String, _ symbol: String) throws(SILError) -> ClosureSignature {
        if let match = type.wholeMatch(of: /@convention\(thin\) @substituted <([^>]*)> \((.*)\) -> \((.*)\) for <(.*)>/) {
            let parameters = splitTopLevel(String(match.1)), arguments = splitTopLevel(String(match.4))
            guard parameters.count == arguments.count else { throw SILError.unsupported("closure \(symbol): its substitution") }
            return ClosureSignature(
                substitution: Dictionary(zip(parameters, arguments), uniquingKeysWith: { first, _ in first }),
                parameters: String(match.2), results: String(match.3))
        }
        if let match = type.wholeMatch(of: /@convention\(thin\) \((.*)\) -> \((.*)\)/) {
            return ClosureSignature(parameters: String(match.1), results: String(match.2))
        }
        throw SILError.unsupported("closure \(symbol) of an unexpected type: \(type)")
    }

    /// The closure's `bb0(…):` line without its error address (index `k`) and its `@closureCapture` markers.
    private static func closureEntry(_ line: String, droppingErrorAt k: Int?, _ symbol: String) throws(SILError) -> String {
        var arguments = splitTopLevel(String(line.dropFirst(4).dropLast(2)))
        if let k {
            guard arguments.count > k, arguments[k].hasSuffix(" : $*Never") else {
                throw SILError.unsupported("closure \(symbol): its error address")
            }
            arguments.remove(at: k)
        }
        return "bb0(" + arguments.map { $0.replacing("@closureCapture ", with: "") }.joined(separator: ", ") + "):"
    }
}

extension ValueType {
    /// The payload of `.some` for an `Optional` layout (cases `none`, `some`); nil for anything else.
    var payloadOfSome: ValueType? {
        guard case .enumeration(let name, let cases) = self, name.hasPrefix("Optional<"), cases.count == 2, cases[0].payload == nil
        else { return nil }
        return cases[1].payload
    }
}

/// True when block `id` is only the error successor of `try_apply`s whose error type is `Never`
/// (`… <A, Never, B>(…) : … @error_indirect …, normal bbN, error id`): it is never reached, and is read as a trap.
func receivesNeverError(_ id: String, _ lines: [String]) -> Bool {
    let calls = lines.filter { $0.hasPrefix("try_apply ") && $0.hasSuffix(", error \(id)") }
    let branches = lines.filter { $0.contains(id) && !$0.hasPrefix("try_apply ") }
    return !calls.isEmpty && branches.isEmpty
        && calls.allSatisfy { line in
            guard line.contains("@error_indirect "), let open = line.firstIndex(of: "<"),
                let close = matchingClose(Substring(line[open...]), open: "<", close: ">")
            else { return false }
            return splitTopLevel(String(line[line.index(after: open)..<close])).contains("Never")
        }
}
