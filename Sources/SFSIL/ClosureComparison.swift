import Foundation

/// Whether a function and everything it calls read the same in two compilations of one module: the answer of
/// `ProofCache.closureText(of:in:)` compared in both, with each function's text made once instead of once per caller.
///
/// Two closures are equal when the roots (the module's witnesses and the function) are the same and every function
/// reached from them has the same text in both: equal texts refer to the same functions, so the walk in the first
/// module also covers the second. A function whose whole closure was found equal is not walked again.
/// `prepare(_:)` renders the functions on several threads first; without it each is rendered when first needed.
package struct ClosureComparison {
    private let first: SILModule
    private let second: SILModule
    private var sameText: [String: Bool] = [:]
    private var callees: [String: [String]] = [:]
    /// Symbols whose root rendering (`isRoot: true`) succeeded in both modules with the same text; filled by `prepare`.
    private var rootsEqual: [String: Bool] = [:]
    private var equalClosures: Set<String> = []
    private var witnessesCompared = false
    private var witnessesEqual = false

    /// Compares functions of `first` with the same functions of `second`.
    package init(first: SILModule, second: SILModule) {
        self.first = first
        self.second = second
    }

    /// `closureText(of: symbol, in: first) == closureText(of: symbol, in: second)`, and `false` when `symbol` does not
    /// parse in either.
    package mutating func isUnchanged(_ symbol: String) -> Bool {
        if let equal = rootsEqual[symbol] {
            guard equal else { return false }
        } else {
            guard let a = try? ProofCache.closureNode(symbol, in: first, isRoot: true),
                let b = try? ProofCache.closureNode(symbol, in: second, isRoot: true), a.text == b.text
            else { return false }
        }
        if !witnessesCompared {
            witnessesCompared = true
            witnessesEqual = first.witnessSymbols == second.witnessSymbols && closuresEqual(from: first.witnessSymbols)
        }
        return witnessesEqual && closuresEqual(from: [symbol])
    }

    private mutating func closuresEqual(from roots: [String]) -> Bool {
        var seen: Set<String> = []
        var queue = roots
        while let current = queue.popLast() {
            guard !equalClosures.contains(current), seen.insert(current).inserted else { continue }
            guard textIsEqual(current) else { return false }
            queue += callees[current, default: []]
        }
        equalClosures.formUnion(seen)
        return true
    }

    /// Renders, on several threads, every function the closures of `symbols` and of the witnesses reach in either
    /// module, a level of callees at a time. The answers of `isUnchanged` stay the same; they are only looked up.
    package mutating func prepare(_ symbols: [String]) {
        var level = Array(Set(first.witnessSymbols + second.witnessSymbols + symbols))
        let roots = Set(symbols)
        while !level.isEmpty {
            let jobs = level
            let rendered = RenderedNodes(count: jobs.count)
            let (first, second) = (self.first, self.second)
            DispatchQueue.concurrentPerform(iterations: jobs.count) { index in
                rendered.set(index, RenderedNodes.Pair(symbol: jobs[index], first: first, second: second))
            }
            var next: Set<String> = []
            for index in jobs.indices {
                let pair = rendered.value(index)
                let symbol = jobs[index]
                if roots.contains(symbol) { rootsEqual[symbol] = pair.rootsEqual }
                sameText[symbol] = pair.textEqual
                callees[symbol] = pair.firstCallees
                next.formUnion(pair.firstCallees)
                next.formUnion(pair.secondCallees)
            }
            level = next.filter { sameText[$0] == nil }
        }
    }

    private mutating func textIsEqual(_ symbol: String) -> Bool {
        if let known = sameText[symbol] { return known }
        let a = try? ProofCache.closureNode(symbol, in: first, isRoot: false)
        let b = try? ProofCache.closureNode(symbol, in: second, isRoot: false)
        let equal = a != nil && a?.text == b?.text
        sameText[symbol] = equal
        callees[symbol] = a?.callees ?? []
        return equal
    }
}

/// The renderings of `ClosureComparison.prepare`, one per index, written by the threads of a `concurrentPerform` and
/// read after it returns.
private final class RenderedNodes: @unchecked Sendable {
    /// What `ClosureComparison` asks about one function, rendered the way it would render it.
    struct Pair {
        let rootsEqual: Bool
        let textEqual: Bool
        let firstCallees: [String]
        let secondCallees: [String]

        init(symbol: String, first: SILModule, second: SILModule) {
            // `isRoot: true` renders what `isRoot: false` renders, or throws when the function does not parse; then
            // the `isRoot: false` rendering is made instead.
            func render(_ module: SILModule) -> (node: (text: String, callees: [String])?, parses: Bool) {
                if let node = try? ProofCache.closureNode(symbol, in: module, isRoot: true) { return (node, true) }
                return (try? ProofCache.closureNode(symbol, in: module, isRoot: false), false)
            }
            let (a, b) = (render(first), render(second))
            textEqual = a.node != nil && a.node?.text == b.node?.text
            rootsEqual = a.parses && b.parses && textEqual
            firstCallees = a.node?.callees ?? []
            secondCallees = b.node?.callees ?? []
        }
    }

    private let lock = NSLock()
    private var storage: [Pair?]

    init(count: Int) { storage = Array(repeating: nil, count: count) }

    func set(_ index: Int, _ pair: Pair) {
        lock.lock()
        storage[index] = pair
        lock.unlock()
    }

    func value(_ index: Int) -> Pair {
        lock.lock()
        defer { lock.unlock() }
        guard let pair = storage[index] else { preconditionFailure("no rendering at \(index)") }
        return pair
    }
}
