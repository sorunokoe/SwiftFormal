import Foundation
import SFBV
import SFCNF
import SFSemantics

// Reading guide
// The closure-taking calls of `Array` (mapper verification, phase 4): `map`, `filter`, `compactMap`, `first(where:)`,
// `contains(where:)`, `allSatisfy` and `count(where:)`, with a closure literal (`SILClosureCalls.swift`). All are
// generic standard-library code logic does not read, so each is read here as what it does: the closure runs on each
// element in order, inlined with its traps, the searches stopping at the first hit.
//
// How many elements. Arrays are modelled by their count; the elements of a literal are known
// (`SILArrayLiterals.swift`), the others are fresh values (an approximation: a counterexample over them may not be
// real). With a known count k (a literal, or a count built of constants) the call runs the closure k times, exactly;
// `map` then makes a literal of k elements whose elements are the closure's results, so `count`, `isEmpty`, `first`
// and `a[i]` on it are exact. A count that is not known has no such unrolling: the closure runs on the first
// `CollectionBounds.iterations` elements, each under `i < n`, and the rest is the array being longer than that,
// which is never a proof (`CollectionBounds`): a scan reads such a call in passes, `exact` (being longer may
// fail, an approximation no counterexample rests on, so only a claim whose `requires` bounds the length is proved;
// with a `requires`, a second exact pass runs up to `CollectionBounds.widened` elements) and `bounded` (being longer is
// assumed away: what that proves is reported as "bounded (n ≤ 8)", never as safe). Outside a scan (no
// `CollectionBounds.current`) the call is `unsupported: … over an array of unknown length`.
//
// The results of `filter` and `compactMap` have an exact count (the number of elements kept) and unknown elements.
// The error block of these calls is never reached: their closure cannot throw (`closureText`), and the parser reads
// it as a trap (`receivesCollectionError`).
// Tests: Tests/SFSILTests/SILClosureCollectionTests.swift, Tests/SFVerifyKitTests/ClosureCollectionScanTests.swift.

/// The closure-taking `Array` calls read with a closure literal.
enum CollectionOperation: String, Sendable {
    case map, filter, compactMap
    case first = "first(where:)"
    case contains = "contains(where:)"
    case allSatisfy
    case count = "count(where:)"

    static let symbols: [String: CollectionOperation] = [
        "$sSlsE3mapySayqd__Gqd__7ElementQzqd_0_YKXEqd_0_YKs5ErrorRd_0_r0_lF": .map,
        "$ss14_ArrayProtocolPsE6filterySay7ElementQzGSbAEqd__YKXEqd__YKs5ErrorRd__lF": .filter,
        "$sSTsE10compactMapySayqd__Gqd__Sg7ElementQzKXEKlF": .compactMap,
        "$sSTsE5first5where7ElementQzSgSbADKXE_tKF": .first,
        "$sSTsE8contains5whereS2b7ElementQzKXE_tKF": .contains,
        "$sSTsE10allSatisfyyS2b7ElementQzKXEKF": .allSatisfy,
        "$sSTsE5count5whereSiSb7ElementQzqd__YKXE_tqd__YKs5ErrorRd__lF": .count,
    ]
}

/// How a scan reads a closure-taking call over an array of unknown length (see the top of `SILClosureCollections.swift`),
/// and which such calls the encodings met: bound with `CollectionBounds.$current` around the solving of one claim.
package final class CollectionBounds: @unchecked Sendable {
    @TaskLocal package static var current: CollectionBounds?

    /// How many elements of an array of unknown length are run, by default.
    package static let iterations = 8
    /// The limit of a second `exact` pass, for a claim whose `requires` may bound the length beyond `iterations`.
    package static let widened = SILEncoder.maxLiteralElements

    package enum Mode: Sendable {
        /// Being longer than `limit` may fail (see `iterations(_:_:)`): a proof holds for every length.
        case exact
        /// Being longer than `limit` is assumed away: a proof holds only up to that length.
        case bounded
    }

    package let mode: Mode
    /// How many elements of an array of unknown length are run in this pass.
    package let limit: Int
    private let lock = NSLock()
    private var texts: Set<String> = []

    package init(_ mode: Mode, limit: Int = CollectionBounds.iterations) { (self.mode, self.limit) = (mode, limit) }

    func record(_ text: String) {
        lock.lock()
        defer { lock.unlock() }
        texts.insert(text)
    }

    /// The calls met, sorted: `map over Array<Item> (n ≤ 8)`.
    package var notes: [String] {
        lock.lock()
        defer { lock.unlock() }
        return texts.sorted()
    }
}

extension FunctionRun {
    /// A closure-taking `Array` call with a closure literal (see the top of this file).
    func collectionCall(_ operation: CollectionOperation, _ request: TryApply) throws {
        guard let closureName = zip(request.arguments, request.conventions).first(where: { $0.1 == .value })?.0,
            let arrayName = request.arguments.last, request.conventions.last == .indirect,
            let arrayType = request.substitutions.first, let elementText = TypeContext.arrayElement(arrayType)
        else { throw SILError.unsupported("\(operation.rawValue) on <\(request.substitutions.joined(separator: ", "))>") }
        for substitution in request.substitutions where !module.destroysWithoutModuleCode(substitution) {
            throw SILError.unsupported(
                "\(operation.rawValue) on \(substitution), whose values may run code of this module when destroyed")
        }
        guard let closure = knownClosure(closureName) else {
            throw SILError.unsupported("\(operation.rawValue) with a closure that is not a literal of \(function.symbol)")
        }
        let n = try arrayCount(arrayName, .indirect)
        let pass = try walk(operation, closure, n, element: try module.resolve(elementText), "\(operation.rawValue) over \(arrayType)")
        let normal: [BV]
        switch operation {
        case .map:
            if pass.known {
                let count = encoder.literalCount(pass.results.count)
                encoder.recordElements(pass.results, count: count)
                normal = [count]
            } else {
                normal = [encoder.plainCount(n)]
            }
        case .filter, .compactMap, .count: normal = [pass.kept]
        case .contains: normal = [BV(bits: [pass.hit])]
        case .allSatisfy: normal = [BV(bits: [pass.all])]
        case .first:
            try writeFirst(request.arguments[0], pass)
            normal = []
        }
        let takes = cfg.index[request.normal].map { function.blocks[$0].parameters.count } ?? 0
        try edge(to: request.normal, parameters: takes == 0 ? [] : [normal], when: live)
    }

    /// What running a closure over an array's elements gave.
    struct CollectionPass {
        var known = false
        /// `map`: each result. `filter`, `compactMap`, `count(where:)`: how many were kept.
        var results: [[BV]] = []
        var kept: BV
        /// The searches: whether one matched, all matched, and the first match.
        var hit: Int32
        var all: Int32
        var first: [BV]?
    }

    /// Runs `closure` on each element of the array with count `n`, in order, stopping as `operation` does.
    private func walk(
        _ operation: CollectionOperation, _ closure: KnownClosure, _ n: BV, element: ValueType, _ what: String
    ) throws -> CollectionPass {
        let steps = try iterations(n, what)
        let elements = c.arrayLiterals[n.bits]?.elements
        var pass = CollectionPass(kept: c.constant(0, width: 64), hit: c.falseLit, all: c.trueLit)
        pass.known = encoder.knownCount(n).map { $0 <= UInt64(SILEncoder.maxLiteralElements) } ?? false
        for i in 0..<steps {
            let active = pass.known ? c.trueLit : c.ult(c.constant(UInt64(i), width: 64), n)
            let stop = operation == .allSatisfy ? -pass.all : pass.hit
            let runs = c.and(active, -stop)
            let value = nthElement(elements, i, element)
            let encoded = try callClosure(closure, value, at: nil, when: runs)
            let produced = encoded.writtenBack.isEmpty ? encoded.results : encoded.writtenBack
            switch operation {
            case .map: pass.results.append(produced)
            case .filter, .count, .compactMap:
                let keeps = operation == .compactMap ? try isSome(produced) : try truth(produced)
                pass.kept = c.add(pass.kept, BV(bits: [c.and(runs, keeps)] + Array(repeating: c.falseLit, count: 63))).sum
            case .allSatisfy: pass.all = c.and(pass.all, c.or(-runs, try truth(produced)))
            case .first, .contains:
                let found = c.and(runs, try truth(produced))
                pass.first = pass.first.map { zip(value, $0).map { c.select(found, $0, $1) } } ?? value
                pass.hit = c.or(pass.hit, found)
            }
        }
        return pass
    }

    /// The `@out` result of `first(where:)`: the first match, or `nil`.
    private func writeFirst(_ address: String, _ pass: CollectionPass) throws {
        let result = try slot(address)
        let none = encoder.enumLeaves(result.type, case: 0, payload: [])
        let some = pass.first.map { encoder.enumLeaves(result.type, case: 1, payload: $0) } ?? none
        guard some.count == none.count, some.count == result.type.leafWidths.count else {
            throw SILError.invalid("first(where:): its result at \(function.symbol)")
        }
        for (i, (s, z)) in zip(some, none).enumerated() { cells["\(result.id)#\(result.leaf + i)"] = c.select(pass.hit, s, z) }
    }

    /// How many elements to run: a known count of at most `maxLiteralElements`, else the pass's `CollectionBounds.limit`
    /// with the rest read as the current `CollectionBounds` says.
    private func iterations(_ n: BV, _ what: String) throws -> Int {
        // A longer known count (a replay at constant inputs) is read like an unknown one.
        if let k = encoder.knownCount(n), k <= UInt64(SILEncoder.maxLiteralElements) { return Int(k) }
        guard let bounds = CollectionBounds.current else {
            throw SILError.unsupported(
                "\(what): an array of unknown length (n ≤ \(CollectionBounds.iterations) is checked only by a scan)")
        }
        let bound = bounds.limit
        bounds.record("\(what) (n ≤ \(bound))")
        let beyond = c.and(live, c.ult(c.constant(UInt64(bound), width: 64), n))
        switch bounds.mode {
        case .exact:
            // Not a failure a counterexample can rest on: `honest` finds the fresh choice open at its inputs.
            out.approximations.insert("arrays longer than \(bound) elements")
            undefined(c.and(beyond, fresh(.scalar(1))[0].bits[0]))
        case .bounded: encoder.assumption = c.and(encoder.assumption ?? c.trueLit, -beyond)
        }
        return bound
    }

    private func nthElement(_ elements: [[BV]]?, _ i: Int, _ type: ValueType) -> [BV] {
        if let elements, i < elements.count, elements[i].map(\.width) == type.leafWidths { return elements[i] }
        out.approximations.insert("Array elements")
        return fresh(type)
    }

    private func truth(_ leaves: [BV]) throws -> Int32 {
        guard leaves.count == 1, leaves[0].width == 1 else {
            throw SILError.invalid("a predicate closure that does not return Bool in \(function.symbol)")
        }
        return leaves[0].bits[0]
    }

    private func isSome(_ leaves: [BV]) throws -> Int32 {
        guard let tag = leaves.first else { throw SILError.invalid("a compactMap closure without a result in \(function.symbol)") }
        return c.eq(tag, c.constant(1, width: tag.width))
    }
}

/// True when block `id` is only the error successor of calls that do not throw: `try_apply`s whose error type is `Never`
/// (`receivesNeverError`), or of the calls of `CollectionOperation` (whose closure cannot throw when read). It is never
/// reached, and is read as a trap.
func receivesUnthrownError(_ id: String, _ lines: [String]) -> Bool {
    receivesNeverError(id, lines) || receivesCollectionError(id, lines)
}

private func receivesCollectionError(_ id: String, _ lines: [String]) -> Bool {
    let calls = lines.filter { $0.hasPrefix("try_apply ") && $0.hasSuffix(", error \(id)") }
    let branches = lines.filter { $0.contains(id) && !$0.hasPrefix("try_apply ") }
    guard !calls.isEmpty, branches.isEmpty else { return false }
    var references: [String: String] = [:]
    for line in lines where line.contains(" = function_ref @") {
        guard let equals = line.range(of: " = function_ref @") else { continue }
        references[String(line[..<equals.lowerBound])] = String(line[equals.upperBound...].prefix { $0 != " " })
    }
    return calls.allSatisfy { line in
        let callee = line.dropFirst("try_apply ".count).prefix { $0 != "<" && $0 != "(" }
        return references[String(callee)].map { CollectionOperation.symbols[$0] != nil } ?? false
    }
}
