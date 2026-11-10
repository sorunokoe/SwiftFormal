import Foundation
import Testing
import SFBV
import SFCNF
import SFProve
import SFSIL
import SFTestSupport

/// Tests of the proof cache and of the compiler pin.
private enum CacheFixture {
    static let source = """
        public func clamp(_ x: Int32, _ lo: Int32, _ hi: Int32) -> Int32 {
            if x < lo { return lo }
            if x > hi { return hi }
            return x
        }
        public func avg(_ a: Int32, _ b: Int32) -> Int32 { (a + b) / 2 }
        public func div(_ a: Int32, _ b: Int32) -> Int32 { a / b }
        """

    /// `clamp` with `<=`, so that the SIL differs but the claim below still holds.
    static let changedSource = source.replacingOccurrences(of: "x < lo", with: "x <= lo")

    static let speed = try! SILCompiler.module(source: source, optimization: .speed)
    static let onone = try! SILCompiler.module(source: source, optimization: .none)

    static func symbol(_ name: String, _ module: SILModule = speed) throws -> String {
        try module.symbol(module: "Fixture", name: name)
    }

    static let clampRequires: @Sendable (CNFBuilder, [BV]) -> Int32 = { c, a in c.sle(a[1], a[2]) }
    static let clampEnsures: @Sendable (CNFBuilder, [BV], BV) -> Int32 = { c, a, r in c.and(c.sle(a[1], r), c.sle(r, a[2])) }
    static let divRequires: @Sendable (CNFBuilder, [BV]) -> Int32 = { c, a in
        c.and(
            -c.eq(a[1], c.constant(0, width: 32)),
            -c.and(c.eq(a[0], c.constant(1 << 31, width: 32)), c.eq(a[1], c.constant(~0, width: 32))))
    }

    /// A cache in a fresh directory.
    static func freshCache() -> ProofCache {
        ProofCache(
            directory: URL(fileURLWithPath: NSTemporaryDirectory())
                .appendingPathComponent("sf-proofcache-test-\(UUID().uuidString)", isDirectory: true))
    }

    static func clampKey(
        _ module: SILModule = speed, claimID: String = "clamp-in-range", symbol: String? = nil,
        fingerprint: CompilerFingerprint? = nil, optimization: Optimization = .speed,
        inputSignedBits: [Int?]? = nil, conflictBudget: Int = 1_000_000,
        requires: @escaping (CNFBuilder, [BV]) -> Int32 = clampRequires,
        ensures: @escaping (CNFBuilder, [BV], BV) -> Int32 = clampEnsures
    ) throws -> String {
        let fingerprint = try fingerprint ?? CompilerFingerprint.current(optimization: optimization)
        return try ProofCache.key(
            symbol: try symbol ?? CacheFixture.symbol("clamp", module), in: module, claimID: claimID,
            fingerprint: fingerprint, inputSignedBits: inputSignedBits, conflictBudget: conflictBudget,
            requires: requires, ensures: ensures)
    }
}

@Suite(.tags(.slow)) struct ProofCacheTests {
    // MARK: hashing

    @Test func fnvMatchesPublishedVectors() {
        // 128-bit FNV-1a test vectors.
        #expect(ProofDigest.fnv1a128([]) == "6c62272e07bb014262b821756295c58d")
        #expect(ProofDigest.fnv1a128(Array("a".utf8)) == "d228cb696f1a8caf78912b704e4a8964")
        #expect(ProofDigest.fnv1a128(Array("foobar".utf8)) == "343e1662793c64bf6f0d3597ba446f18")
        #expect(ProofDigest.hash("x").hasPrefix(ProofDigest.algorithm + ":"))
        #expect(ProofDigest.hash("x") != ProofDigest.hash("y"))
    }

    // MARK: keys

    @Test func keyChangesWithEverythingItDependsOn() throws {
        let base = try CacheFixture.clampKey()
        #expect(base == (try CacheFixture.clampKey()), "the key must be deterministic")

        let changedModule = try SILCompiler.module(source: CacheFixture.changedSource, optimization: .speed)
        #expect(try CacheFixture.clampKey(changedModule) != base, "different SIL")
        #expect(try CacheFixture.clampKey(CacheFixture.onone, optimization: .none) != base, "different SIL and optimization")
        #expect(try CacheFixture.clampKey(claimID: "other") != base, "claimID")
        let fingerprint0 = try CompilerFingerprint.current(optimization: .speed)
        let trivial = try ProofCache.key(
            symbol: try CacheFixture.symbol("avg"), in: CacheFixture.speed, claimID: "c", fingerprint: fingerprint0)
        let trivialOther = try ProofCache.key(
            symbol: try CacheFixture.symbol("div"), in: CacheFixture.speed, claimID: "c", fingerprint: fingerprint0)
        #expect(trivial != trivialOther, "symbol")
        #expect(try CacheFixture.clampKey(inputSignedBits: [31, 31, 31]) != base, "input assumptions")
        #expect(try CacheFixture.clampKey(inputSignedBits: [31, 31, 31]) != (try CacheFixture.clampKey(inputSignedBits: [31, 31, nil])))
        #expect(try CacheFixture.clampKey(conflictBudget: 10) != base, "budget class")
        #expect(try CacheFixture.clampKey(conflictBudget: 1_000_001) == base, "same budget class shares entries")
        #expect(try CacheFixture.clampKey(ensures: { c, _, _ in c.trueLit }) != base, "claim closure, forgotten claimID")
        #expect(try CacheFixture.clampKey(requires: { c, _ in c.trueLit }) != base, "claim closure, forgotten claimID")

        // Same SIL, same everything, but the optimization label differs: still a different key.
        let fingerprint = try CompilerFingerprint.current(optimization: .speed)
        #expect(try CacheFixture.clampKey(optimization: .none) != base, "optimization label")
        var other = fingerprint
        other.swiftcVersion += " (other)"
        #expect(try CacheFixture.clampKey(fingerprint: other) != base, "compiler")
        other = fingerprint; other.sdkVersion += ".1"
        #expect(try CacheFixture.clampKey(fingerprint: other) != base, "sdk")
        other = fingerprint; other.encoderVersion += 1
        #expect(try CacheFixture.clampKey(fingerprint: other) != base, "encoder semantics version")
        other = fingerprint; other.semanticsDigest += "0"
        #expect(try CacheFixture.clampKey(fingerprint: other) != base, "semantics digest")
    }

    /// The encoder also reads what the function bodies do not show: the contents of constant tables (`-O` turns a
    /// `let` array into a `sil_global`) and the witnesses it calls by type and requirement. A change there must change
    /// the key, or a cached `.proved` would be returned for different code.
    @Test func keyCoversTablesAndWitnesses() throws {
        func key(_ source: String, _ name: String, _ optimization: Optimization) throws -> String {
            let module = try SILCompiler.module(source: source, optimization: optimization)
            let symbol = try module.symbol(module: "Fixture", name: name)
            return try ProofCache.key(
                symbol: symbol, in: module, claimID: "c", fingerprint: try CompilerFingerprint.current(optimization: optimization))
        }
        let table = """
            let table: [Int8] = [1, 2, 3, 4]
            public func pick(_ i: Int8) -> Int8 { table[Int(i & 3)] }
            """
        let otherTable = table.replacingOccurrences(of: "3, 4]", with: "3, 5]")
        #expect(try key(table, "pick", .speed) == (try key(table, "pick", .speed)))
        #expect(try key(table, "pick", .speed) != (try key(otherTable, "pick", .speed)), "table contents")

        let witness = """
            public struct P: Equatable {
                var v: Int8
                public static func == (a: P, b: P) -> Bool { a.v == b.v }
            }
            public func has(_ a: Int8) -> Bool { [P(v: 1), P(v: 2)].contains(P(v: a)) }
            """
        // `contains` reaches `==` only through P's witness table: no `function_ref` to it in `has`.
        let otherWitness = witness.replacingOccurrences(of: "a.v == b.v", with: "a.v != b.v")
        #expect(try key(witness, "has", .none) != (try key(otherWitness, "has", .none)), "witness body")
    }

    /// Keys are compared across processes, where dictionaries and sets iterate in another order (per-process hash seed).
    @Test func canonicalTextDoesNotDependOnIterationOrder() {
        var small: [String: [Int]] = [:]
        var large: [String: [Int]] = [:]
        large.reserveCapacity(4096)
        for k in 0..<200 { small["k\(k)"] = [k, k * 2] }
        for k in (0..<200).reversed() { large["k\(k)"] = [k, k * 2] }
        #expect(Array(small.keys) != Array(large.keys), "the two dictionaries must iterate differently for this test")
        #expect(ProofCache.canonicalText(small) == ProofCache.canonicalText(large))
        var set: Set<String> = []
        set.reserveCapacity(4096)
        set.formUnion(small.keys)
        #expect(ProofCache.canonicalText(Set(small.keys)) == ProofCache.canonicalText(set))
        #expect(ProofCache.canonicalText(small) != ProofCache.canonicalText(small.merging(["k1": [0]]) { $1 }))
    }

    @Test func fieldsCannotImitateEachOther() throws {
        let module = CacheFixture.speed
        let fingerprint = try CompilerFingerprint.current(optimization: .speed)
        let a = try ProofCache.key(
            symbol: try CacheFixture.symbol("div"), in: module, claimID: "a\nclaimProbe=0:", fingerprint: fingerprint)
        let b = try ProofCache.key(symbol: try CacheFixture.symbol("div"), in: module, claimID: "a", fingerprint: fingerprint)
        #expect(a != b)
    }

    @Test func semanticsDigestIsStableAndNonTrivial() {
        #expect(SemanticsDigest.current == SemanticsDigest.compute())
        let report = SemanticsDigest.s0Report()
        #expect(report.count > 100_000, "the battery should cover the whole S0 table")
        #expect(SemanticsDigest.canaryReport().contains("trap=1"), "the canary must exercise a trap")
        #expect(!SemanticsDigest.canaryReport().contains("error:"), "the canary must parse")
    }

    /// Plan item R7: changing what a standard-library summary assumes must change every cache key.
    @Test func editingASummaryRowChangesTheDigest() throws {
        var table = StdlibSummary.table
        let symbol = "$ss26DefaultStringInterpolationV15literalCapacity18interpolationCountABSi_SitcfC"
        let row = try #require(table[symbol])
        #expect(SemanticsDigest.summaryReport().contains(symbol))
        table[symbol] = StdlibSummary.Entry(name: row.name, summary: .unknown, isGeneric: row.isGeneric)
        #expect(SemanticsDigest.summaryReport(table) != SemanticsDigest.summaryReport())
        table[symbol] = nil
        #expect(SemanticsDigest.summaryReport(table) != SemanticsDigest.summaryReport())
    }

    @Test func fingerprintNamesTheInstalledCompiler() throws {
        let toolchain = try CompilerToolchain.installed()
        #expect(toolchain.swiftcVersion.contains("Swift"))
        #expect(!toolchain.sdkVersion.isEmpty)
        let fingerprint = try CompilerFingerprint.current(optimization: .speed)
        #expect(fingerprint.optimization == "-O")
        #expect(fingerprint.encoderVersion == SILFrontendVersion.semantics)
        #expect(fingerprint != (try CompilerFingerprint.current(optimization: .none)))
    }

    // MARK: hit and miss

    @Test func provedVerdictIsCachedAndRecheckedOnRequest() throws {
        let cache = CacheFixture.freshCache()
        defer { cache.clear() }
        let verifier = CachedVerifier(cache: cache)
        let symbol = try CacheFixture.symbol("clamp")
        func prove(_ verifier: CachedVerifier, claimID: String = "clamp-in-range") throws -> CachedResult {
            try verifier.prove(
                symbol: symbol, in: CacheFixture.speed, claimID: claimID, optimization: .speed,
                requires: CacheFixture.clampRequires, ensures: CacheFixture.clampEnsures)
        }
        let cold = try prove(verifier)
        #expect(cold.verdict == .proved && cold.source == .computed)
        let warm = try prove(verifier)
        #expect(warm.verdict == .proved && warm.source == .cacheHit)
        #expect(warm.key == cold.key)
        #expect(try prove(verifier, claimID: "renamed").source == .computed, "a new claimID is a miss")

        let rechecked = try prove(CachedVerifier(cache: cache, trust: .recheck))
        #expect(rechecked.verdict == .proved && rechecked.source == .rechecked(agreedWithCache: true))

        let entry = try #require(cache.lookup(key: cold.key, fingerprint: try .current(optimization: .speed)))
        #expect(entry.verdict == .proved && entry.key == cold.key && !entry.timestamp.isEmpty)
        let statistics = cache.statistics
        #expect(statistics.hits == 1 && statistics.misses == 3 && statistics.stores == 3)
    }

    @Test func unknownIsNeverStored() throws {
        let cache = CacheFixture.freshCache()
        defer { cache.clear() }
        try cache.store(verdict: .unknown, key: "sha256:abc", fingerprint: try .current(optimization: .speed), symbol: "s", claimID: "c")
        #expect(!FileManager.default.fileExists(atPath: cache.fileURL(forKey: "sha256:abc").path))
        #expect(cache.statistics.stores == 0)
    }

    @Test func realCounterexampleIsReplayedAndReturned() throws {
        let cache = CacheFixture.freshCache()
        defer { cache.clear() }
        let verifier = CachedVerifier(cache: cache)
        let symbol = try CacheFixture.symbol("div")
        let cold = try verifier.prove(symbol: symbol, in: CacheFixture.speed, claimID: "div-total", optimization: .speed)
        guard case .counterexample(let values) = cold.verdict else { Issue.record("div must be able to trap"); return }
        #expect(cold.source == .computed)
        let warm = try verifier.prove(symbol: symbol, in: CacheFixture.speed, claimID: "div-total", optimization: .speed)
        #expect(warm.source == .cacheHit && warm.verdict == .counterexample(values))
    }

    @Test func staleCounterexampleIsDropped() throws {
        let cache = CacheFixture.freshCache()
        defer { cache.clear() }
        let verifier = CachedVerifier(cache: cache)
        let symbol = try CacheFixture.symbol("clamp")
        let fingerprint = try CompilerFingerprint.current(optimization: .speed)
        func prove() throws -> CachedResult {
            try verifier.prove(
                symbol: symbol, in: CacheFixture.speed, claimID: "clamp-in-range", optimization: .speed,
                requires: CacheFixture.clampRequires, ensures: CacheFixture.clampEnsures)
        }
        let key = try CacheFixture.clampKey()
        // The claim holds, so any stored counterexample is a lie. Try several kinds of lies.
        let lies: [[UInt64]] = [[5, 1, 10], [5, 10, 1], [0, 0, 0], [1, 2], [1, 2, 3, 4], [1 << 40, 1, 2]]
        for lie in lies {
            try cache.store(verdict: .counterexample(lie), key: key, fingerprint: fingerprint, symbol: symbol, claimID: "clamp-in-range")
            let result = try prove()
            #expect(result.verdict == .proved, "poisoned entry \(lie) must not be returned")
            #expect(result.droppedStaleCounterexample && result.source == .computed)
        }
        #expect(cache.statistics.droppedCounterexamples == lies.count)
        #expect(try prove().source == .cacheHit, "after the drop, the recomputed proof is cached")

        // A counterexample that violates the precondition is not a counterexample either.
        let sneaky: [UInt64] = [5, 10, 1]
        try cache.store(verdict: .counterexample(sneaky), key: key, fingerprint: fingerprint, symbol: symbol, claimID: "clamp-in-range")
        #expect(try prove().verdict == .proved)

        // A stored counterexample that fails the claim only without its precondition is dropped when replayed with it.
        let withoutPrecondition = try verifier.prove(
            symbol: symbol, in: CacheFixture.speed, claimID: "no-requires", optimization: .speed,
            ensures: CacheFixture.clampEnsures)
        guard case .counterexample(let real) = withoutPrecondition.verdict else { Issue.record("expected a counterexample"); return }
        let again = try verifier.prove(
            symbol: symbol, in: CacheFixture.speed, claimID: "no-requires", optimization: .speed,
            ensures: CacheFixture.clampEnsures)
        #expect(again.source == .cacheHit && again.verdict == .counterexample(real))
    }

    @Test func staleEquivalenceCounterexampleIsDropped() throws {
        let cache = CacheFixture.freshCache()
        defer { cache.clear() }
        let verifier = CachedVerifier(cache: cache)
        let a = try CacheFixture.symbol("clamp", CacheFixture.onone), b = try CacheFixture.symbol("clamp", CacheFixture.speed)
        let cold = try verifier.proveEquivalent(
            a, in: CacheFixture.onone, optimization: .none, b, in: CacheFixture.speed, optimization: .speed)
        #expect(cold.verdict == .proved && cold.source == .computed)
        #expect(
            try verifier.proveEquivalent(
                a, in: CacheFixture.onone, optimization: .none, b, in: CacheFixture.speed,
                optimization: .speed
            ).source == .cacheHit)
        try cache.store(
            verdict: .counterexample([1, 2, 3]), key: cold.key,
            fingerprint: CompilerFingerprint(toolchain: try .installed(), optimizations: (.none, .speed)),
            symbol: "x", claimID: "equivalence")
        let poisoned = try verifier.proveEquivalent(
            a, in: CacheFixture.onone, optimization: .none, b, in: CacheFixture.speed, optimization: .speed)
        #expect(poisoned.verdict == .proved && poisoned.droppedStaleCounterexample)

        // Two functions that really differ: the counterexample is cached, replayed, and returned.
        let c = try CacheFixture.symbol("div")
        let signature = try? verifier.proveEquivalent(
            a, in: CacheFixture.onone, optimization: .none, c, in: CacheFixture.speed, optimization: .speed)
        #expect(signature == nil, "different signatures are an error, and errors are not cached")
    }

    @Test func entriesWithWrongKeyFingerprintOrFormatAreIgnored() throws {
        let cache = CacheFixture.freshCache()
        defer { cache.clear() }
        let fingerprint = try CompilerFingerprint.current(optimization: .speed)
        try cache.store(verdict: .proved, key: "sha256:aaaa", fingerprint: fingerprint, symbol: "s", claimID: "c")
        #expect(cache.lookup(key: "sha256:aaaa", fingerprint: fingerprint)?.verdict == .proved)
        var other = fingerprint; other.sdkVersion = "0.0"
        #expect(cache.lookup(key: "sha256:aaaa", fingerprint: other) == nil)
        // A proof copied to another key's file name is not accepted.
        try FileManager.default.copyItem(at: cache.fileURL(forKey: "sha256:aaaa"), to: cache.fileURL(forKey: "sha256:bbbb"))
        #expect(cache.lookup(key: "sha256:bbbb", fingerprint: fingerprint) == nil)
        try Data("not json".utf8).write(to: cache.fileURL(forKey: "sha256:cccc"))
        #expect(cache.lookup(key: "sha256:cccc", fingerprint: fingerprint) == nil)
        #expect(cache.statistics.rejectedEntries == 3)
    }

    @Test func concurrentAccessNeverSeesACorruptEntry() throws {
        let cache = CacheFixture.freshCache()
        defer { cache.clear() }
        let fingerprint = try CompilerFingerprint.current(optimization: .speed)
        let keys = (0..<4).map { "sha256:key\($0)" }
        let torn = Atomic()
        DispatchQueue.concurrentPerform(iterations: 64) { i in
            let key = keys[i % keys.count]
            for round in 0..<60 {
                if (i + round) % 3 == 0 {
                    // Large counterexamples make a torn write likely, if writes were not atomic.
                    let verdict: ProofVerdict = (i % 2 == 0) ? .proved : .counterexample((0..<200).map { UInt64($0 + i) })
                    try? cache.store(verdict: verdict, key: key, fingerprint: fingerprint, symbol: "s", claimID: "c\(i)")
                } else if let entry = cache.lookup(key: key, fingerprint: fingerprint) {
                    if entry.key != key { torn.increment() }
                } else if FileManager.default.fileExists(atPath: cache.fileURL(forKey: key).path) {
                    torn.increment()
                }
            }
        }
        #expect(torn.value == 0)
        #expect(cache.statistics.rejectedEntries == 0)
        for key in keys { #expect(cache.lookup(key: key, fingerprint: fingerprint) != nil) }
        let leftovers = try FileManager.default.contentsOfDirectory(atPath: cache.directory.path)
        #expect(leftovers.allSatisfy { $0.hasSuffix(".json") }, "no temporary files left behind: \(leftovers)")
    }

    // MARK: cold versus warm

    @Test func coldVersusWarm() throws {
        let cache = CacheFixture.freshCache()
        defer { cache.clear() }
        let verifier = CachedVerifier(cache: cache)
        let module = CacheFixture.speed
        struct Job {
            var name: String
            var run: (CachedVerifier) throws -> CachedResult
        }
        let jobs: [Job] = [
            Job(name: "clamp (proved)") {
                try $0.prove(
                    symbol: try CacheFixture.symbol("clamp"), in: module, claimID: "clamp-in-range", optimization: .speed,
                    requires: CacheFixture.clampRequires, ensures: CacheFixture.clampEnsures)
            },
            Job(name: "div (proved, needs 2 preconditions)") {
                try $0.prove(
                    symbol: try CacheFixture.symbol("div"), in: module, claimID: "div-safe", optimization: .speed,
                    requires: CacheFixture.divRequires)
            },
            Job(name: "avg (proved with 31-bit inputs)") {
                try $0.prove(
                    symbol: try CacheFixture.symbol("avg"), in: module, claimID: "avg-31bit", optimization: .speed,
                    inputSignedBits: [31, 31])
            },
            Job(name: "avg (counterexample)") {
                try $0.prove(symbol: try CacheFixture.symbol("avg"), in: module, claimID: "avg-free", optimization: .speed)
            },
        ]
        let setup = ContinuousClock.now
        _ = try CompilerToolchain.installed()  // one-time per process: two xcrun calls and the S0/encoder digest
        _ = SemanticsDigest.current
        print("[ProofCache] one-time per-process setup (xcrun x2 + semantics digest): \(ContinuousClock.now - setup)")
        var lines: [String] = []
        for job in jobs {
            let t0 = ContinuousClock.now
            let cold = try job.run(verifier)
            let t1 = ContinuousClock.now
            let warm = try job.run(verifier)
            let t2 = ContinuousClock.now
            let recheck = try job.run(CachedVerifier(cache: cache, trust: .recheck))
            let t3 = ContinuousClock.now
            for _ in 0..<20 { _ = try job.run(verifier) }
            let t4 = ContinuousClock.now
            #expect(cold.source == .computed && warm.source == .cacheHit)
            #expect(warm.verdict == cold.verdict && recheck.verdict == cold.verdict)
            func ms(_ a: ContinuousClock.Instant, _ b: ContinuousClock.Instant, per n: Double = 1) -> String {
                let d = b - a
                return String(format: "%9.2f ms", (Double(d.components.seconds) * 1000 + Double(d.components.attoseconds) / 1e15) / n)
            }
            lines.append(
                "\(job.name.padding(toLength: 40, withPad: " ", startingAt: 0)) cold \(ms(t0, t1))  warm \(ms(t1, t2))  warm(avg of 20) \(ms(t3, t4, per: 20))  recheck \(ms(t2, t3))"
            )
        }
        print("[ProofCache] cold/warm (release, noisy: other agents running):\n" + lines.joined(separator: "\n"))
    }

    // MARK: pin

    @Test func pinRejectsUnknownCompilersLoudly() throws {
        let fake = CompilerToolchain(
            swiftcVersion: "Apple Swift version 99.0 (swiftlang-99.0.0.1 clang-9999.0.0.1)\nTarget: arm64-apple-macosx27.0",
            sdkVersion: "99.0")
        #expect(throws: ProofCacheError.self) { try PinnedCompiler.check(toolchain: fake) }
        do {
            _ = try PinnedCompiler.module(source: "public func f(_ x: Int32) -> Int32 { x }", optimization: .speed, toolchain: fake)
            Issue.record("an unpinned compiler must not be accepted")
        } catch let error as ProofCacheError {
            let text = error.description
            #expect(text.contains("UNPINNED") && text.contains("99.0") && text.contains("swiftlang-6.4.0.34.1"))
        }
        // Explicit opt-out.
        #expect(try PinnedCompiler.check(toolchain: fake, allowUnpinned: true) == fake)
        // A pin extended with the fake compiler's line accepts it; the Target line is irrelevant.
        let extended = CompilerPin.verified.adding(fake.swiftcVersion)
        #expect(try PinnedCompiler.check(pin: extended, toolchain: fake) == fake)
        let sameLineOtherTarget = CompilerToolchain(
            swiftcVersion: "Apple Swift version 99.0 (swiftlang-99.0.0.1 clang-9999.0.0.1)\nTarget: x86_64-apple-macosx27.0",
            sdkVersion: "99.0")
        #expect(extended.accepts(sameLineOtherTarget))
        #expect(!CompilerPin.verified.accepts(fake))
    }

    @Test func pinRoundTripsThroughDisk() throws {
        let url = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("sf-pin-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }
        let pin = CompilerPin.verified.adding("Apple Swift version 1.0 (x)")
        try pin.save(to: url)
        #expect(try CompilerPin.load(from: url) == pin)
    }

    @Test func installedCompilerIsPinnedAndYieldsAModule() throws {
        let module = try PinnedCompiler.module(source: "public func inc(_ x: Int8) -> Int8 { x &+ 1 }", optimization: .speed)
        #expect(try SILVerifier.prove(try module.symbol(module: "Fixture", name: "inc"), in: module) == .proved)
    }
}

/// Minimal thread-safe counter.
private final class Atomic: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    func increment() { lock.lock(); count += 1; lock.unlock() }
    var value: Int { lock.lock(); defer { lock.unlock() }; return count }
}

// MARK: - SIL grammar fixtures

/// The parser accepts a whitelist of SIL instructions in the text form of one particular compiler. These tests hold
/// snippets of that text, produced by the pinned compiler, and compile the same source with the *installed* compiler. If the
/// installed compiler prints something else, the test fails and says what to re-validate. Passing means the pinned
/// text form still is the installed text form for these constructs; it does not prove the parser handles all SIL.
@Suite struct SILGrammarFixtureTests {
    static let source = """
        public func clamp(_ x: Int32, _ lo: Int32, _ hi: Int32) -> Int32 {
            if x < lo { return lo }
            if x > hi { return hi }
            return x
        }
        public func avg(_ a: Int32, _ b: Int32) -> Int32 { (a + b) / 2 }
        public func pre(_ x: Int64) -> Int64 { precondition(x > 0); return x - 1 }
        @inline(never) public func twice(_ x: Int32) -> Int32 { x &* 2 }
        public func useTwice(_ x: Int32) -> Int32 { twice(x) &+ 1 }
        """

    struct Snippet: Sendable {
        var optimization: Optimization
        var symbol: String
        var covers: String
        var text: String
    }

    static let snippets: [Snippet] = [
        Snippet(
            optimization: .speed, symbol: "$s7Fixture5clampys5Int32VAD_A2DtF",
            covers: "cond_br, br with block argument, block parameter, struct_extract, comparison builtin",
            text: """
                sil @$s7Fixture5clampys5Int32VAD_A2DtF : $@convention(thin) (Int32, Int32, Int32) -> Int32 {
                bb0(%0 : $Int32, %1 : $Int32, %2 : $Int32):
                debug_value %0, let, name "x", argno 1
                debug_value %1, let, name "lo", argno 2
                debug_value %2, let, name "hi", argno 3
                %6 = struct_extract %0, #Int32._value
                %7 = struct_extract %1, #Int32._value
                %8 = builtin "cmp_slt_Int32"(%6, %7) : $Builtin.Int1
                cond_br %8, bb1, bb2
                bb1:
                br bb5(%1)
                bb2:
                %11 = struct_extract %2, #Int32._value
                %12 = builtin "cmp_slt_Int32"(%11, %6) : $Builtin.Int1
                cond_br %12, bb3, bb4
                bb3:
                br bb5(%2)
                bb4:
                br bb5(%0)
                bb5(%16 : $Int32):
                return %16
                }
                """),
        Snippet(
            optimization: .none, symbol: "$s7Fixture3avgys5Int32VAD_ADtF",
            covers: "integer_literal, overflow builtin, tuple_extract, cond_fail, sdiv, struct",
            text: """
                sil @$s7Fixture3avgys5Int32VAD_ADtF : $@convention(thin) (Int32, Int32) -> Int32 {
                bb0(%0 : $Int32, %1 : $Int32):
                debug_value %0, let, name "a", argno 1
                debug_value %1, let, name "b", argno 2
                %4 = struct_extract %0, #Int32._value
                %5 = struct_extract %1, #Int32._value
                %6 = integer_literal $Builtin.Int1, -1
                %7 = builtin "sadd_with_overflow_Int32"(%4, %5, %6) : $(Builtin.Int32, Builtin.Int1)
                %8 = tuple_extract %7, 0
                %9 = tuple_extract %7, 1
                cond_fail %9, "arithmetic overflow"
                %11 = integer_literal $Builtin.Int32, 2
                %12 = integer_literal $Builtin.Int32, -2147483648
                %13 = builtin "cmp_eq_Int32"(%8, %12) : $Builtin.Int1
                cond_br %13, bb1, bb2
                bb1:
                br bb3
                bb2:
                br bb3
                bb3:
                %17 = builtin "sdiv_Int32"(%8, %11) : $Builtin.Int32
                %18 = struct $Int32 (%17)
                return %18
                }
                """),
        Snippet(
            optimization: .none, symbol: "$s7Fixture3preys5Int64VADF",
            covers: "failure plumbing: string_literal, StaticString, ptrtoint, function_ref, apply of a Never function, unreachable",
            text: """
                sil @$s7Fixture3preys5Int64VADF : $@convention(thin) (Int64) -> Int64 {
                bb0(%0 : $Int64):
                debug_value %0, let, name "x", argno 1
                %2 = string_literal utf8 "Fixture/Fixture.swift"
                %3 = integer_literal $Builtin.Word, 21
                %4 = builtin "ptrtoint_Word"(%2) : $Builtin.Word
                debug_step
                %6 = integer_literal $Builtin.Int8, 2
                %7 = struct $StaticString (%4, %3, %6)
                %8 = integer_literal $Builtin.Int64, 7
                %9 = struct $UInt (%8)
                %10 = function_ref @$ss12precondition__4file4lineySbyXK_SSyXKs12StaticStringVSutFfA0_SSycfu_ : $@convention(thin) () -> @owned String
                %11 = integer_literal $Builtin.Int64, 0
                %12 = struct_extract %0, #Int64._value
                %13 = builtin "cmp_slt_Int64"(%11, %12) : $Builtin.Int1
                %14 = integer_literal $Builtin.Int1, -1
                %15 = builtin "int_expect_Int1"(%13, %14) : $Builtin.Int1
                cond_br %15, bb2, bb1
                bb1:
                %17 = string_literal utf8 "Precondition failed"
                %18 = integer_literal $Builtin.Word, 19
                %19 = builtin "ptrtoint_Word"(%17) : $Builtin.Word
                %20 = integer_literal $Builtin.Int8, 2
                %21 = struct $StaticString (%19, %18, %20)
                %22 = apply %10() : $@convention(thin) () -> @owned String
                %23 = integer_literal $Builtin.Int32, 1
                %24 = struct $UInt32 (%23)
                %25 = function_ref @$ss17_assertionFailure__4file4line5flagss5NeverOs12StaticStringV_SSAHSus6UInt32VtF : $@convention(thin) (StaticString, @guaranteed String, StaticString, UInt, UInt32) -> Never
                %26 = apply %25(%21, %22, %7, %9, %24) : $@convention(thin) (StaticString, @guaranteed String, StaticString, UInt, UInt32) -> Never
                unreachable
                bb2:
                debug_step
                %29 = integer_literal $Builtin.Int64, 1
                %30 = struct_extract %0, #Int64._value
                %31 = integer_literal $Builtin.Int1, -1
                %32 = builtin "ssub_with_overflow_Int64"(%30, %29, %31) : $(Builtin.Int64, Builtin.Int1)
                %33 = tuple_extract %32, 0
                %34 = tuple_extract %32, 1
                cond_fail %34, "arithmetic overflow"
                %36 = struct $Int64 (%33)
                return %36
                }
                """),
        Snippet(
            optimization: .none, symbol: "$s7Fixture8useTwiceys5Int32VADF", covers: "function_ref and apply of a user function",
            text: """
                sil @$s7Fixture8useTwiceys5Int32VADF : $@convention(thin) (Int32) -> Int32 {
                bb0(%0 : $Int32):
                debug_value %0, let, name "x", argno 1
                %2 = function_ref @$s7Fixture5twiceys5Int32VADF : $@convention(thin) (Int32) -> Int32
                %3 = apply %2(%0) : $@convention(thin) (Int32) -> Int32
                %4 = struct_extract %3, #Int32._value
                %5 = integer_literal $Builtin.Int32, 1
                %6 = integer_literal $Builtin.Int1, 0
                %7 = builtin "sadd_with_overflow_Int32"(%4, %5, %6) : $(Builtin.Int32, Builtin.Int1)
                %8 = tuple_extract %7, 0
                %9 = struct $Int32 (%8)
                return %9
                }
                """),
        Snippet(
            optimization: .none, symbol: "$s7Fixture5twiceys5Int32VADF", covers: "[noinline] attribute, multiply with overflow",
            text: """
                sil [noinline] @$s7Fixture5twiceys5Int32VADF : $@convention(thin) (Int32) -> Int32 {
                bb0(%0 : $Int32):
                debug_value %0, let, name "x", argno 1
                %2 = struct_extract %0, #Int32._value
                %3 = integer_literal $Builtin.Int32, 2
                %4 = integer_literal $Builtin.Int1, 0
                %5 = builtin "smul_with_overflow_Int32"(%3, %2, %4) : $(Builtin.Int32, Builtin.Int1)
                %6 = tuple_extract %5, 0
                %7 = struct $Int32 (%6)
                return %7
                }
                """),
    ]

    /// Drops comments (outside string literals), blank lines, and the leading indentation.
    static func normalize(_ text: String) -> [String] {
        text.split(separator: "\n", omittingEmptySubsequences: false).compactMap { raw in
            var out = "", quoted = false, previous: Character? = nil
            for ch in raw {
                if ch == "\"" { quoted.toggle() }
                if !quoted && ch == "/" && previous == "/" { out.removeLast(); break }
                out.append(ch)
                previous = ch
            }
            let line = out.trimmingCharacters(in: .whitespaces)
            return line.isEmpty || line.hasPrefix("[global:") ? nil : line
        }
    }

    static func body(of symbol: String, in sil: String) -> [String] {
        var collected: [String] = [], inside = false
        for line in normalize(sil) {
            if line.hasPrefix("sil ") && line.contains(" @\(symbol) ") { inside = true }
            if inside {
                collected.append(line)
                if line == "}" { break }
            }
        }
        return collected
    }

    static let live: [Optimization: String] = {
        var result: [Optimization: String] = [:]
        for optimization in [Optimization.none, .speed] {
            result[optimization] = try! SILCompiler.emit(source: source, optimization: optimization)
        }
        return result
    }()

    @Test(
        .enabled(
            if: (try? PinnedCompiler.check()) != nil,
            "the installed compiler is not pinned: see docs/guides/compilers.md to re-validate the SIL reader against it"), .tags(.oracle))
    func installedCompilerPrintsTheSameSILAsTheFixtures() throws {
        for snippet in Self.snippets {
            let expected = Self.normalize(snippet.text)
            let actual = Self.body(of: snippet.symbol, in: Self.live[snippet.optimization]!)
            #expect(
                actual == expected,
                """
                SIL text form changed for \(snippet.symbol) (\(snippet.optimization.rawValue)); covers: \(snippet.covers).
                The compiler is \((try? CompilerToolchain.installed().versionLine) ?? "unknown"). Re-validate SILParser and SILEncoder against the new text, \
                update these snippets, bump SILFrontendVersion.semantics, and only then add the compiler to the pin.
                """)
            if actual != expected {
                let firstDifference = zip(actual, expected).first { $0 != $1 }
                Issue.record(
                    "first differing line: installed=\(firstDifference?.0 ?? "<missing>") fixture=\(firstDifference?.1 ?? "<missing>")")
            }
        }
    }

    @Test func fixtureSnippetsParseAndEncodeToTheExpectedSemantics() throws {
        // The snippets are the parser's input contract: they must parse as they are, with no compiler involved.
        var texts: [Optimization: String] = [:]
        for snippet in Self.snippets {
            texts[snippet.optimization, default: "sil_stage canonical\n\n"] += snippet.text + "\n\n"
        }
        let onone = try SILModule(text: try #require(texts[.none]))
        let speed = try SILModule(text: try #require(texts[.speed]))
        func evaluate(_ symbol: String, _ module: SILModule, _ arguments: [UInt64]) throws -> String {
            let function = try module.function(symbol)
            let c = CNFBuilder()
            let inputs = zip(function.parameterWidths, arguments).map { c.constant($1, width: $0) }
            let encoded = try SILEncoder(module: module, builder: c).encode(symbol: symbol, arguments: inputs)
            if encoded.trap == c.trueLit { return "trap" }
            if encoded.undefined == c.trueLit { return "undefined" }
            guard encoded.trap == c.falseLit, encoded.undefined == c.falseLit, let value = c.constantValue(encoded.result) else {
                return "symbolic"
            }
            return String(value)
        }
        let int32max: UInt64 = 0x7FFF_FFFF
        // clamp(5, 1, 3) = 3 ; clamp(-9, 1, 3) = 1 ; clamp(2, 1, 3) = 2
        #expect(try evaluate("$s7Fixture5clampys5Int32VAD_A2DtF", speed, [5, 1, 3]) == "3")
        #expect(try evaluate("$s7Fixture5clampys5Int32VAD_A2DtF", speed, [0xFFFF_FFF7, 1, 3]) == "1")
        #expect(try evaluate("$s7Fixture5clampys5Int32VAD_A2DtF", speed, [2, 1, 3]) == "2")
        #expect(try evaluate("$s7Fixture3avgys5Int32VAD_ADtF", onone, [10, 20]) == "15")
        #expect(try evaluate("$s7Fixture3avgys5Int32VAD_ADtF", onone, [int32max, 1]) == "trap")
        #expect(try evaluate("$s7Fixture3preys5Int64VADF", onone, [5]) == "4")
        #expect(try evaluate("$s7Fixture3preys5Int64VADF", onone, [0]) == "trap")
        #expect(try evaluate("$s7Fixture8useTwiceys5Int32VADF", onone, [20]) == "41")
    }
}
