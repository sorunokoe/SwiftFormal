import Foundation
import SFSIL

final class Results: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [FunctionReport?]
    init(count: Int) { storage = Array(repeating: nil, count: count) }
    func set(_ index: Int, _ report: FunctionReport) {
        lock.lock()
        storage[index] = report
        lock.unlock()
    }
    var values: [FunctionReport] {
        lock.lock()
        defer { lock.unlock() }
        return storage.compactMap { $0 }
    }
}

/// What every function of one compiled module is verified against (`Verifier.verify`).
struct VerifyScope {
    let module: SILModule
    /// The module's functions by symbol, to name callees in explanations.
    let functions: [String: FunctionInfo]
    /// Proof cache keys; nil when the run has no cache.
    let keys: ScanClaimKeys?
}

struct Contract {
    var requires: FunctionInfo?
    var ensures: FunctionInfo?
    /// Hand-written functions that fit the function's `_requires` / `_ensures` by name and parameters. Scan reads only
    /// the contract `@Verify` writes (`FunctionInfo.isVerifyPeer`), so these are reported and never read.
    var ignored: [FunctionInfo] = []

    /// The arguments of `f_ensures`: the parameters of `f`, then its result. In SIL a method's `self` is its last
    /// parameter, so for a method `self` moves behind the result: `(a, result, self)`. A `mutating` method's
    /// `f_ensures(a, [result], old: Self)` is a plain method whose `self` is the value after the call: `(a, result,
    /// self before, self after)`; its result is left out when it is `Void`. `writtenBack` is laid out as
    /// `EncodedFunction.writtenBack`, so `self`, the last parameter, comes back last, and an address-only result
    /// (`SILFunction.indirectResult`, such as a `UUID`) comes back first.
    static func ensuresArguments<T>(
        _ inputs: [T], _ direct: [T], writtenBack: [T], of function: SILFunction, _ info: FunctionInfo
    ) -> [T] {
        let results = function.indirectResult.map { Array(writtenBack.prefix($0.leafWidths.count)) } ?? direct
        guard info.isMethod, let selfType = function.parameterTypes.last else { return inputs + results }
        let count = selfType.leafWidths.count
        let before = Array(inputs.suffix(count))
        guard mutatesSelf(info) else { return Array(inputs.dropLast(count)) + results + before }
        return Array(inputs.dropLast(count)) + results + before + Array(writtenBack.suffix(count))
    }

    /// The SIL parameter types `f_ensures` must have, without `@guaranteed`/`@owned`; see `ensuresArguments`.
    /// Nil when `f` has an `inout` parameter other than a `mutating` method's `self`: `ensures` would see its value
    /// before the call, not after it, so such a function gets no `ensures`.
    static func ensuresParameterTypes(of info: FunctionInfo) -> [String]? {
        let others = mutatesSelf(info) ? Array(info.parameterTypes.dropLast()) : info.parameterTypes
        if others.contains(where: { $0.hasPrefix("@inout ") }) { return nil }
        guard info.isMethod, let selfType = info.parameterTypes.last else {
            return (info.parameterTypes + [info.resultType]).map(valueType)
        }
        let parameters = info.parameterTypes.dropLast().map(valueType)
        guard mutatesSelf(info) else { return parameters + [info.resultType, selfType].map(valueType) }
        let result = info.resultType == "()" ? [] : [valueType(info.resultType)]
        return parameters + result + [valueType(selfType), valueType(selfType)]
    }

    /// The SIL parameter types `f_requires` must have, without `@guaranteed`/`@owned`. A `mutating` method's
    /// `f_requires` is a plain method: it reads `self` before the call.
    static func requiresParameterTypes(of info: FunctionInfo) -> [String] {
        info.parameterTypes.enumerated().map { index, type in
            index == info.parameterTypes.count - 1 && mutatesSelf(info) ? valueType(type) : stripOwnership(type)
        }
    }

    /// A `mutating` method: its `self`, the last SIL parameter, is `@inout`.
    static func mutatesSelf(_ info: FunctionInfo) -> Bool {
        info.isMethod && info.parameterTypes.last?.hasPrefix("@inout ") == true
    }

    /// The type of a parameter as a value: `@inout S`, `@guaranteed S` and `S` are all `S`.
    private static func valueType(_ type: String) -> String {
        stripOwnership(type.hasPrefix("@inout ") ? String(type.dropFirst("@inout ".count)) : type)
    }

    /// Ownership, and passing an address-only value (a `UUID`) by address, do not change a value: `@guaranteed S`,
    /// `@owned S`, `@in_guaranteed S`, `@in S`, `@out S` and `S` are all `S`.
    static func stripOwnership(_ type: String) -> String {
        for prefix in ["@guaranteed ", "@owned ", "@in_guaranteed ", "@in ", "@out "] where type.hasPrefix(prefix) {
            return String(type.dropFirst(prefix.count))
        }
        return type
    }
}

/// Finds `f_requires(params) -> Bool` and `f_ensures(params, result) -> Bool` next to `f`, by name and parameter types.
/// Only the peers `@Verify` wrote pair (`FunctionInfo.isVerifyPeer`); a hand-written one is listed in `Contract.ignored`,
/// stays an ordinary function, and is never read as a contract.
struct SpecIndex {
    private let functions: [FunctionInfo]
    private let matched: Set<String>
    private let table: [String: Contract]
    /// Function symbol → the `_requires` / `_ensures` named after it that pair with no function (a wrong shape).
    private let unpaired: [String: [FunctionInfo]]

    init(_ functions: [FunctionInfo]) {
        self.functions = functions
        var table: [String: Contract] = [:]
        var matched: Set<String> = []
        // Functions by base name, in source order, so each lookup finds the same first match as a scan of all of them.
        var byBaseName: [String: [FunctionInfo]] = [:]
        for f in functions { byBaseName[f.baseName, default: []].append(f) }
        for f in functions where !f.baseName.hasSuffix("_requires") && !f.baseName.hasSuffix("_ensures") {
            // A computed property `x` is the function `x.getter`; its contract is `x_ensures(_ result:)`.
            let base = f.baseName.hasSuffix(".getter") ? String(f.baseName.dropLast(".getter".count)) : f.baseName
            var contract = Contract()
            let requiresTypes = Contract.requiresParameterTypes(of: f)
            let ensuresTypes = Contract.ensuresParameterTypes(of: f)
            let requires = (byBaseName[base + "_requires"] ?? []).filter {
                Self.passingForm($0.parameterTypes) == Self.passingForm(requiresTypes)
            }
            let ensures = (byBaseName[base + "_ensures"] ?? []).filter {
                ensuresTypes.map(Self.passingForm) == Self.passingForm($0.parameterTypes)
            }
            // Only the peers `@Verify` wrote are the contract; a hand-written function of the same shape is not read.
            contract.requires = requires.first(where: \.isVerifyPeer)
            contract.ensures = ensures.first(where: \.isVerifyPeer)
            contract.ignored = (requires + ensures).filter { !$0.isVerifyPeer }
            if contract.requires != nil || contract.ensures != nil || !contract.ignored.isEmpty {
                table[f.symbol] = contract
                if let r = contract.requires { matched.insert(r.symbol) }
                if let e = contract.ensures { matched.insert(e.symbol) }
            }
        }
        self.table = table
        self.matched = matched
        // A spec that pairs with no function is told to each function it is named after that lacks that half of a
        // contract, so its verdict does not read as checked against a contract it never saw (round 6, L9). Only a peer
        // `@Verify` wrote is a spec; a hand-written one is an ordinary function (`Contract.ignored`).
        var unpaired: [String: [FunctionInfo]] = [:]
        for f in functions where !f.baseName.hasSuffix("_requires") && !f.baseName.hasSuffix("_ensures") {
            let base = f.baseName.hasSuffix(".getter") ? String(f.baseName.dropLast(".getter".count)) : f.baseName
            let contract = table[f.symbol] ?? Contract()
            let halves = [(contract.requires, "_requires"), (contract.ensures, "_ensures")].filter { $0.0 == nil }
            let specs = halves.flatMap { byBaseName[base + $0.1] ?? [] }.filter { $0.isVerifyPeer && !matched.contains($0.symbol) }
            if !specs.isEmpty { unpaired[f.symbol] = specs }
        }
        self.unpaired = unpaired
    }

    /// SIL types as Swift wrote them, for pairing a spec with its function: without how a value is passed, and with
    /// tuples split into their elements. A value whose layout another module owns (`URL`, `UUID`, SwiftUI's `Color`,
    /// or a type that holds one) is passed indirectly, so a getter returns `@out Loading<Data>` while its `_ensures`
    /// takes `@in_guaranteed Loading<Data>`; a tuple result is one SIL type `(Int, @out Color?)`, and a tuple
    /// parameter is as many parameters as it has elements (app study round 6, L7 and L9: such contracts were left
    /// unpaired). The types themselves must still be the same; whether Scan can read them is decided later.
    static func passingForm(_ types: [String]) -> [String] {
        types.flatMap { passingForm($0) }
    }

    static func passingForm(_ type: String) -> [String] {
        var type = Substring(type.trimmingCharacters(in: .whitespaces))
        var stripped = true
        while stripped {
            stripped = false
            for prefix in ["@out ", "@in_guaranteed ", "@in_constant ", "@in ", "@guaranteed ", "@owned "] where type.hasPrefix(prefix) {
                type = type.dropFirst(prefix.count)
                stripped = true
            }
        }
        guard type.hasPrefix("("), type.hasSuffix(")"), let elements = tupleElements(type) else { return [String(type)] }
        return elements.flatMap { passingForm(String($0)) }
    }

    /// The elements of a tuple type `(A, B<C, D>)`, or nil when the parentheses do not enclose the whole type (a
    /// function type `(Int) -> Int`) or enclose a single type.
    private static func tupleElements(_ type: Substring) -> [Substring]? {
        var depth = 0
        var elements: [Substring] = []
        var start = type.index(after: type.startIndex)
        for index in type.indices {
            let character = type[index]
            if "(<[".contains(character) { depth += 1 }
            if ")>]".contains(character) { depth -= 1 }
            if depth == 0, index != type.index(before: type.endIndex) { return nil }
            if depth == 1, character == "," {
                elements.append(type[start..<index])
                start = type.index(after: index)
            }
        }
        let last = type[start..<type.index(before: type.endIndex)]
        if !last.trimmingCharacters(in: .whitespaces).isEmpty { elements.append(last) }
        return elements.count == 1 ? nil : elements
    }

    func isSpec(_ symbol: String) -> Bool { matched.contains(symbol) }
    func unpaired(for symbol: String) -> [FunctionInfo] { unpaired[symbol] ?? [] }

    /// A `_requires` / `_ensures` that `@Verify` wrote and that pairs with no function (its shape is one Scan cannot
    /// pair): reported as a function of its own, so the contract it holds is seen to be unchecked.
    static func isUnpairedPeer(_ info: FunctionInfo, _ specs: SpecIndex) -> Bool {
        info.isVerifyPeer && (info.baseName.hasSuffix("_requires") || info.baseName.hasSuffix("_ensures")) && !specs.isSpec(info.symbol)
    }
    func contract(for info: FunctionInfo) -> Contract { table[info.symbol] ?? Contract() }
}

/// Runs `body` on a thread with a 16 MB stack and waits for it. The encoder inlines calls recursively, and in a debug
/// build each level of `SILEncoder.run` takes about 55 KB of stack: eight levels (`maxCallDepth`) do not fit in the
/// 512 KB of a dispatch worker thread, which then crashes (`EXC_BAD_ACCESS`), so every verification runs here.
func onLargeStack(_ body: @escaping @Sendable () -> Void) {
    let done = DispatchSemaphore(value: 0)
    let thread = Thread {
        body()
        done.signal()
    }
    thread.stackSize = 16 << 20
    thread.start()
    done.wait()
}
