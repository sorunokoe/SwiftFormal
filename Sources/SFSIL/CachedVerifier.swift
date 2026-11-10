import Foundation
package import SFBV
import SFCNF
package import SFProve
import SFSemantics

// A proof cache for the SIL frontend, keyed so that a cached verdict can only be reused when everything that could change
// the verdict is unchanged. Rule used throughout: if in doubt, put it in the key.
//
// What a hit means. A cached `.proved` says: "the same circuit input (the parsed bodies of the function and all its
// transitive callees), under the same compiler, SDK, optimization level, encoder semantics, S0 table behaviour, claim, input
// assumptions and budget class, was proved and the proof was accepted by the RUP checker". It does not re-run anything.
// `.recheck` mode never trusts a stored proof. Counterexamples are never trusted: each is replayed through the encoder
// circuit and dropped if it no longer fails the claim.

// MARK: - the verifier

package struct CachedResult: Sendable, Equatable {
    package enum Source: Sendable, Equatable {
        /// No usable cache entry: the verdict was computed.
        case computed
        /// Returned from the cache without proving (a replayed counterexample, or a trusted proof).
        case cacheHit
        /// `Trust.recheck`: computed anyway. `agreedWithCache` is nil when there was no entry, otherwise whether
        /// the stored verdict had the same kind (proved or counterexample). `false` is an alarm.
        case rechecked(agreedWithCache: Bool?)
    }

    package let verdict: ProofVerdict
    package let source: Source
    package let key: String
    /// True when a cached counterexample failed its replay, was deleted, and the verdict was recomputed.
    package let droppedStaleCounterexample: Bool
}

package struct CachedVerifier: Sendable {
    package let cache: ProofCache
    package let trust: ProofCache.Trust
    private let toolchainOverride: CompilerToolchain?

    /// - Parameter toolchain: for tests and for callers that know better than `xcrun`; default is the installed toolchain.
    package init(cache: ProofCache, trust: ProofCache.Trust = .cachedProof, toolchain: CompilerToolchain? = nil) {
        self.cache = cache
        self.trust = trust
        self.toolchainOverride = toolchain
    }

    private func toolchain() throws -> CompilerToolchain { try toolchainOverride ?? .installed() }

    /// Same as `SILVerifier.prove`, behind the cache. `optimization` must be the level `module` was compiled at: it is part of the key.
    ///
    /// `claimID` names the `requires`/`ensures` pair. **Closures cannot be hashed, so `claimID` must change whenever the claim changes.**
    /// A stale `claimID` is partly caught by a behavioural probe of the closures (part of the key), and a cached counterexample is
    /// always replayed against the closures actually passed, so a stale ID can cost a wrong cached *proof* but never a wrong counterexample.
    /// Use `Trust.recheck` when in doubt.
    package func prove(
        symbol: String,
        in module: SILModule,
        claimID: String,
        optimization: Optimization,
        inputSignedBits: [Int?]? = nil,
        conflictBudget: Int = 1_000_000,
        requires: (CNFBuilder, [BV]) -> Int32 = { c, _ in c.trueLit },
        ensures: (CNFBuilder, [BV], BV) -> Int32 = { c, _, _ in c.trueLit }
    ) throws -> CachedResult {
        let fingerprint = CompilerFingerprint(toolchain: try toolchain(), optimization: optimization)
        let key = try ProofCache.key(
            symbol: symbol, in: module, claimID: claimID, fingerprint: fingerprint,
            inputSignedBits: inputSignedBits, conflictBudget: conflictBudget, requires: requires, ensures: ensures)
        let stored = cache.lookup(key: key, fingerprint: fingerprint)
        var dropped = false
        if trust == .cachedProof, let entry = stored {
            if entry.verdict == .proved {
                cache.count { $0.hits += 1 }
                return CachedResult(verdict: .proved, source: .cacheHit, key: key, droppedStaleCounterexample: false)
            }
            if let values = entry.counterexampleValues, values.count == entry.counterexample?.count,
                Self.counterexampleStillFails(
                    values, symbol: symbol, module: module, inputSignedBits: inputSignedBits,
                    conflictBudget: conflictBudget, requires: requires, ensures: ensures)
            {
                cache.count { $0.hits += 1 }
                return CachedResult(verdict: .counterexample(values), source: .cacheHit, key: key, droppedStaleCounterexample: false)
            }
            cache.remove(key: key)
            cache.count { $0.droppedCounterexamples += 1 }
            dropped = true
        }
        let verdict = try SILVerifier.prove(
            symbol, in: module, inputSignedBits: inputSignedBits, conflictBudget: conflictBudget,
            requires: requires, ensures: ensures)
        cache.count { $0.misses += 1 }
        try cache.store(verdict: verdict, key: key, fingerprint: fingerprint, symbol: symbol, claimID: claimID)
        return CachedResult(
            verdict: verdict, source: Self.source(trust: trust, stored: stored, verdict: verdict), key: key,
            droppedStaleCounterexample: dropped)
    }

    /// Same as `SILVerifier.proveEquivalent`, behind the cache. `claimID` is only a label for the stored entry; the key is
    /// determined by the two functions and the fingerprint.
    package func proveEquivalent(
        _ symbolA: String, in a: SILModule, optimization optimizationA: Optimization,
        _ symbolB: String, in b: SILModule, optimization optimizationB: Optimization,
        conflictBudget: Int = 1_000_000
    ) throws -> CachedResult {
        let fingerprint = CompilerFingerprint(toolchain: try toolchain(), optimizations: (optimizationA, optimizationB))
        let key = try ProofCache.equivalenceKey(symbolA, in: a, symbolB, in: b, fingerprint: fingerprint, conflictBudget: conflictBudget)
        let stored = cache.lookup(key: key, fingerprint: fingerprint)
        var dropped = false
        if trust == .cachedProof, let entry = stored {
            if entry.verdict == .proved {
                cache.count { $0.hits += 1 }
                return CachedResult(verdict: .proved, source: .cacheHit, key: key, droppedStaleCounterexample: false)
            }
            if let values = entry.counterexampleValues, values.count == entry.counterexample?.count,
                Self.equivalenceCounterexampleStillDiffers(values, symbolA, a, symbolB, b)
            {
                cache.count { $0.hits += 1 }
                return CachedResult(verdict: .counterexample(values), source: .cacheHit, key: key, droppedStaleCounterexample: false)
            }
            cache.remove(key: key)
            cache.count { $0.droppedCounterexamples += 1 }
            dropped = true
        }
        let verdict = try SILVerifier.proveEquivalent(symbolA, in: a, symbolB, in: b, conflictBudget: conflictBudget)
        cache.count { $0.misses += 1 }
        try cache.store(verdict: verdict, key: key, fingerprint: fingerprint, symbol: "\(symbolA) ~ \(symbolB)", claimID: "equivalence")
        return CachedResult(
            verdict: verdict, source: Self.source(trust: trust, stored: stored, verdict: verdict), key: key,
            droppedStaleCounterexample: dropped)
    }

    private static func source(trust: ProofCache.Trust, stored: ProofCache.Entry?, verdict: ProofVerdict) -> CachedResult.Source {
        guard trust == .recheck else { return .computed }
        guard let stored else { return .rechecked(agreedWithCache: nil) }
        switch verdict {
        case .proved: return .rechecked(agreedWithCache: stored.verdict == .proved)
        case .counterexample: return .rechecked(agreedWithCache: stored.verdict == .counterexample)
        case .unknown: return .rechecked(agreedWithCache: nil)
        }
    }

    // MARK: replay

    /// Runs the real claim once more with every input pinned to the stored values, so the encoder circuit itself decides.
    /// True only if that run finds exactly these inputs as a counterexample. A stored value that violates the declared
    /// input range, has the wrong arity or width, or an inconclusive replay all count as "no longer fails".
    static func counterexampleStillFails(
        _ values: [UInt64], symbol: String, module: SILModule, inputSignedBits: [Int?]?, conflictBudget: Int,
        requires: (CNFBuilder, [BV]) -> Int32, ensures: (CNFBuilder, [BV], BV) -> Int32
    ) -> Bool {
        guard let function = try? module.function(symbol), function.parameterWidths.count == values.count else { return false }
        for (value, width) in zip(values, function.parameterWidths) where width < 64 && value >> UInt64(width) != 0 { return false }
        let pinned = try? SILVerifier.prove(
            symbol, in: module, inputSignedBits: inputSignedBits, conflictBudget: conflictBudget,
            requires: { c, inputs in
                var pin = requires(c, inputs)
                for (input, value) in zip(inputs, values) { pin = c.and(pin, c.eq(input, c.constant(value, width: input.width))) }
                return pin
            }, ensures: ensures)
        if case .counterexample(let found)? = pinned { return found == values }
        return false
    }

    /// Mirrors `SILVerifier.proveEquivalent`'s claim on constants: both circuits must fold to constants and disagree.
    static func equivalenceCounterexampleStillDiffers(
        _ values: [UInt64], _ symbolA: String, _ a: SILModule, _ symbolB: String, _ b: SILModule
    ) -> Bool {
        guard let fa = try? a.function(symbolA), let fb = try? b.function(symbolB),
            fa.parameterWidths == fb.parameterWidths, fa.resultWidth == fb.resultWidth,
            fa.parameterWidths.count == values.count
        else { return false }
        for (value, width) in zip(values, fa.parameterWidths) where width < 64 && value >> UInt64(width) != 0 { return false }
        let c = CNFBuilder()
        let inputs = zip(fa.parameterWidths, values).map { c.constant($1, width: $0) }
        guard let ea = try? SILEncoder(module: a, builder: c).encode(symbol: symbolA, arguments: inputs),
            let eb = try? SILEncoder(module: b, builder: c).encode(symbol: symbolB, arguments: inputs)
        else { return false }
        let sameTrap = -c.xor(ea.trap, eb.trap)
        let sameUndefined = -c.xor(ea.undefined, eb.undefined)
        let bothOK = c.and(-ea.trap, -ea.undefined)
        let sameValue = c.or(-bothOK, c.eq(ea.result, eb.result))
        return c.and(c.and(sameTrap, sameUndefined), sameValue) == c.falseLit
    }
}
