import Foundation
import Testing
import SFBV
import SFCNF
import SFProve
import SFSIL
import SFTestSupport

/// Enums and Optionals in real `swiftc` output, cross-checked against native execution.
enum EnumFixture {
    static let source = """
        public enum Dir { case north, east, south, west }
        public enum Shape { case circle(Int32), rect(w: Int32, h: Int32), none }
        public enum Code: Int8 { case ok = 0, notFound = 4, fail = -3 }
        public struct Club { public var loft: Int8?; public var id: Int32 }
        public struct Slot { public var dir: Dir; public var n: Int16 }

        public func turn(_ d: Dir) -> Dir { switch d { case .north: .east; case .east: .south; case .south: .west; case .west: .north } }
        public func isVertical(_ d: Dir) -> Bool { d == .north || d == .south }
        public func area(_ s: Shape) -> Int32 {
            switch s { case .circle(let r): return 3 * r * r; case .rect(let w, let h): return w &* h; case .none: return 0 }
        }
        public func wide(_ s: Shape) -> Shape { if case .rect(let w, let h) = s { return .rect(w: w &* 2, h: h) }; return s }
        public func code(_ x: Int8) -> Code? { Code(rawValue: x) }
        public func raw(_ c: Code) -> Int8 { c.rawValue }
        public func orZero(_ x: Int32?) -> Int32 { x ?? 0 }
        public func force(_ x: Int32?) -> Int32 { x! }
        public func bump(_ x: Int16?) -> Int16? { if let v = x { return v &+ 1 }; return nil }
        public func both(_ a: Int8?, _ b: Int8?) -> Int8 { guard let a, let b else { return -1 }; return a &+ b }
        public func nested(_ x: Int8??) -> Int8 {
            switch x { case .none: return 0; case .some(.none): return 1; case .some(.some(let v)): return v }
        }
        public func loftOr(_ c: Club) -> Int8 { c.loft ?? 10 }
        public func mkClub(_ l: Int8?, _ id: Int32) -> Club { Club(loft: l, id: id) }
        public func slotN(_ s: Slot) -> Int16 { s.dir == .west ? s.n : s.n &+ 1 }
        public func checkedLoft(_ c: Club) -> Int8 { (c.loft ?? 0) + 1 }
        public enum Load<T> { case idle; case loaded(T); case failed(code: Int8) }
        public struct Pair<A, B> { public var a: A; public var b: B }
        public func loadValue(_ s: Load<Int8>) -> Int8 { switch s { case .idle: 0; case .loaded(let v): v + 1; case .failed(let c): c } }
        public func mkLoad(_ x: Int8) -> Load<Int16> { x > 0 ? .failed(code: x) : x == 0 ? .idle : .loaded(Int16(x) * 300) }
        public func pick(_ p: Pair<Int8, Load<Bool>>) -> Int8 { if case .loaded(true) = p.b { return p.a }; return 0 }
        """

    /// Native helpers that build values from model leaves and flatten results back into leaves.
    static let helpers = """
        func u<T: BinaryInteger>(_ v: T) -> UInt64 { UInt64(truncatingIfNeeded: v) }
        func dir(_ a: [UInt64], _ i: Int) -> Dir { [Dir.north, .east, .south, .west][Int(a[i])] }
        func dirTag(_ d: Dir) -> UInt64 { switch d { case .north: 0; case .east: 1; case .south: 2; case .west: 3 } }
        func shape(_ a: [UInt64], _ i: Int) -> Shape {
            switch a[i] {
            case 0: .circle(Int32(truncatingIfNeeded: a[i + 1]))
            case 1: .rect(w: Int32(truncatingIfNeeded: a[i + 2]), h: Int32(truncatingIfNeeded: a[i + 3]))
            default: .none
            }
        }
        func shapeLeaves(_ s: Shape) -> [UInt64] {
            switch s { case .circle(let r): [0, u(r), 0, 0]; case .rect(let w, let h): [1, 0, u(w), u(h)]; case .none: [2, 0, 0, 0] }
        }
        func code(_ a: [UInt64], _ i: Int) -> Code { [Code.ok, .notFound, .fail][Int(a[i])] }
        func codeTag(_ c: Code) -> UInt64 { switch c { case .ok: 0; case .notFound: 1; case .fail: 2 } }
        func opt<T: FixedWidthInteger>(_ a: [UInt64], _ i: Int) -> T? { a[i] == 0 ? nil : T(truncatingIfNeeded: a[i + 1]) }
        func optLeaves<T: BinaryInteger>(_ x: T?) -> [UInt64] { x.map { [1, u($0)] } ?? [0, 0] }
        func nest(_ a: [UInt64], _ i: Int) -> Int8?? { a[i] == 0 ? .none : .some(opt(a, i + 1)) }
        func club(_ a: [UInt64], _ i: Int) -> Club { Club(loft: opt(a, i), id: Int32(truncatingIfNeeded: a[i + 2])) }
        func load8(_ a: [UInt64], _ i: Int) -> Load<Int8> {
            [Load.idle, .loaded(Int8(truncatingIfNeeded: a[i + 1])), .failed(code: Int8(truncatingIfNeeded: a[i + 2]))][Int(a[i])]
        }
        func loadBool(_ a: [UInt64], _ i: Int) -> Load<Bool> {
            [Load.idle, .loaded(a[i + 1] != 0), .failed(code: Int8(truncatingIfNeeded: a[i + 2]))][Int(a[i])]
        }
        func load16Leaves(_ s: Load<Int16>) -> [UInt64] {
            switch s { case .idle: [0, 0, 0]; case .loaded(let v): [1, u(v), 0]; case .failed(let c): [2, 0, u(c)] }
        }
        """

    /// Name, the native call over leaf array `a`, and the native expression giving the result leaves from `r`.
    struct Spec {
        let name: String
        let call: String
        let leaves: String
        init(_ name: String, _ call: String, _ leaves: String) { (self.name, self.call, self.leaves) = (name, call, leaves) }
    }

    static let specs: [Spec] = [
        .init("loadValue", "loadValue(load8(a, 0))", "[u(r)]"),
        .init("mkLoad", "mkLoad(Int8(truncatingIfNeeded: a[0]))", "load16Leaves(r)"),
        .init("pick", "pick(Pair(a: Int8(truncatingIfNeeded: a[0]), b: loadBool(a, 1)))", "[u(r)]"),
        .init("turn", "turn(dir(a, 0))", "[dirTag(r)]"),
        .init("isVertical", "isVertical(dir(a, 0))", "[r ? 1 : 0]"),
        .init("area", "area(shape(a, 0))", "[u(r)]"),
        .init("wide", "wide(shape(a, 0))", "shapeLeaves(r)"),
        .init("code", "code(Int8(truncatingIfNeeded: a[0]))", "r.map { [1, codeTag($0)] } ?? [0, 0]"),
        .init("raw", "raw(code(a, 0))", "[u(r)]"),
        .init("orZero", "orZero(opt(a, 0))", "[u(r)]"),
        .init("force", "force(opt(a, 0))", "[u(r)]"),
        .init("bump", "bump(opt(a, 0))", "optLeaves(r)"),
        .init("both", "both(opt(a, 0), opt(a, 2))", "[u(r)]"),
        .init("nested", "nested(nest(a, 0))", "[u(r)]"),
        .init("loftOr", "loftOr(club(a, 0))", "[u(r)]"),
        .init("mkClub", "mkClub(opt(a, 0), Int32(truncatingIfNeeded: a[2]))", "optLeaves(r.loft) + [u(r.id)]"),
        .init("slotN", "slotN(Slot(dir: dir(a, 0), n: Int16(truncatingIfNeeded: a[1])))", "[u(r)]"),
        .init("checkedLoft", "checkedLoft(club(a, 0))", "[u(r)]"),
    ]

    static let onone = try! SILCompiler.module(source: source, name: "En", optimization: .none)
    static let speed = try! SILCompiler.module(source: source, name: "En", optimization: .speed)
    static func module(_ o: Optimization) -> SILModule { o == .none ? onone : speed }
    static func symbol(_ name: String, _ o: Optimization) throws -> String { try module(o).symbol(module: "En", name: name) }
}

/// Recursive enums the frontend must refuse.
private enum EnumRejectFixture {
    static let source = """
        public indirect enum Tree { case leaf(Int32), node(Tree, Tree) }
        public func leaf(_ t: Tree) -> Int32 { if case .leaf(let v) = t { return v }; return 0 }
        """
    static let onone = try! SILCompiler.module(source: source, name: "Er", optimization: .none)
}

private func mask(_ width: Int) -> UInt64 { width == 64 ? ~0 : (1 << UInt64(width)) - 1 }

/// Deterministic pseudo-random numbers.
private struct Mix {
    var state: UInt64
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }

    /// Edge values are drawn often: they are where the traps are.
    mutating func scalar(_ width: Int) -> UInt64 {
        let m = mask(width)
        let top: UInt64 = 1 << UInt64(width - 1)
        let edges: [UInt64] = [0, 1, 2, m, m - 1, top, top - 1, 127 & m, 128 & m]
        return next() % 2 == 0 ? edges[Int(next() % UInt64(edges.count))] & m : next() & m
    }

    /// The leaves of a random valid value of `type`: a real case, inactive payloads zero.
    mutating func value(_ type: ValueType) -> [UInt64] {
        switch type {
        case .scalar(let width): return [scalar(width)]
        case .opaque: return [next()]
        case .array, .hashed: return [next() & (1 << 48 - 1)]
        case .aggregate(_, let fields): return fields.flatMap { value($0.type) }
        case .enumeration(_, let cases):
            let tag = Int(next() % UInt64(cases.count))
            var leaves = [UInt64](repeating: 0, count: type.leafWidths.count)
            leaves[0] = UInt64(tag)
            if let payload = cases[tag].payload {
                for (i, v) in zip(type.payloadLeafRange(ofCase: tag), value(payload)) { leaves[i] = v }
            }
            return leaves
        }
    }
}

@Suite(.tags(.slow)) struct SILEnumTests {
    private static let optimizations: [Optimization] = [.none, .speed]

    private static func xcrun(_ args: [String]) throws -> (status: Int32, error: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/xcrun")
        process.arguments = args
        let err = Pipe()
        process.standardOutput = FileHandle.nullDevice
        process.standardError = err
        try process.run()
        let e = err.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return (process.terminationStatus, String(bytes: e, encoding: .utf8) ?? "")
    }

    private static func nativeMain() -> String {
        let cases = EnumFixture.specs.map { "    case \"\($0.name)\": let r = \($0.call); out = \($0.leaves)" }.joined(separator: "\n")
        return """
            import Foundation
            \(EnumFixture.helpers)
            let lines = try! String(contentsOfFile: CommandLine.arguments[1], encoding: .utf8).split(separator: "\\n")
            let start = Int(CommandLine.arguments[2])!
            for (index, line) in lines.enumerated() where index >= start {
                let f = line.split(separator: " ")
                let a = f.dropFirst().map { UInt64($0)! }
                var out: [UInt64] = []
                switch String(f[0]) {
            \(cases)
                default: fatalError("unknown")
                }
                print(index, out.map(String.init).joined(separator: " "))
                fflush(stdout)
            }
            """
    }

    private enum Native: Equatable { case trap, values([UInt64]) }

    /// One native run: the function, its argument leaves, and its parsed SIL.
    private struct NativeCase {
        let symbol: String
        let args: [UInt64]
        let function: SILFunction
    }

    /// Runs every case natively; a crash marks that case as a trap and the run resumes after it.
    private static func runNative(binary: String, cases: [String], directory: String) throws -> [Native] {
        let file = directory + "/cases.txt"
        try cases.joined(separator: "\n").write(toFile: file, atomically: true, encoding: .utf8)
        var results: [Native] = []
        while results.count < cases.count {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: binary)
            process.arguments = [file, String(results.count)]
            let out = Pipe()
            process.standardOutput = out
            process.standardError = FileHandle.nullDevice
            try process.run()
            let data = out.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            for line in (String(bytes: data, encoding: .utf8) ?? "").split(separator: "\n") {
                results.append(.values(line.split(separator: " ").dropFirst().map { UInt64($0)! }))
            }
            if process.terminationReason == .uncaughtSignal {
                results.append(.trap)
            } else {
                try #require(process.terminationStatus == 0)
            }
        }
        return results
    }

    @Test(.enabled(if: FileManager.default.isExecutableFile(atPath: "/usr/bin/xcrun")), .tags(.oracle))
    func enumEncodingsAgreeWithNativeExecution() throws {
        let directory = FileManager.default.currentDirectoryPath + "/.sf-enum-\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: directory) }
        try EnumFixture.source.write(toFile: directory + "/En.swift", atomically: true, encoding: .utf8)
        try Self.nativeMain().write(toFile: directory + "/main.swift", atomically: true, encoding: .utf8)

        for optimization in Self.optimizations {
            let module = EnumFixture.module(optimization)
            let binary = directory + "/native\(optimization.rawValue)"
            let build = try Self.xcrun(["swiftc", optimization.rawValue, directory + "/En.swift", directory + "/main.swift", "-o", binary])
            try #require(build.status == 0, "native build failed: \(build.error)")

            var cases: [String] = []
            var meta: [NativeCase] = []
            var rng = Mix(state: 7)
            for spec in EnumFixture.specs {
                let symbol = try EnumFixture.symbol(spec.name, optimization)
                let function = try module.function(symbol)
                for _ in 0..<120 {
                    let args = function.parameterTypes.flatMap { rng.value($0) }
                    cases.append(([spec.name] + args.map(String.init)).joined(separator: " "))
                    meta.append(NativeCase(symbol: symbol, args: args, function: function))
                }
            }
            let native = try Self.runNative(binary: binary, cases: cases, directory: directory)
            try #require(native.count == cases.count)

            var traps = 0, mismatches: [String] = []
            for (i, m) in meta.enumerated() {
                let c = CNFBuilder()
                let args = zip(m.function.parameterWidths, m.args).map { c.constant($0.1, width: $0.0) }
                let e = try SILEncoder(module: module, builder: c).encode(symbol: m.symbol, arguments: args)
                guard e.trap == c.trueLit || e.trap == c.falseLit, e.undefined == c.falseLit,
                    let values = try? e.results.map({ try #require(c.constantValue($0)) })
                else {
                    mismatches.append("\(cases[i]): circuit is not constant or reports undefined behaviour"); continue
                }
                let widths = m.function.resultWidths
                let model: Native = e.trap == c.trueLit ? .trap : .values(zip(values, widths).map { $0 & mask($1) })
                var expected = native[i]
                if case .values(let v) = expected { expected = .values(zip(v, widths).map { $0 & mask($1) }) }
                if model == .trap { traps += 1 }
                if model != expected, mismatches.count < 5 {
                    mismatches.append("\(optimization.rawValue) \(cases[i]): model \(model), native \(expected)")
                }
            }
            #expect(mismatches.isEmpty, "\(mismatches)")
            #expect(traps > 20, "too few trapping cases at \(optimization.rawValue): \(traps)")
        }
    }

    // MARK: proofs

    @Test(arguments: optimizations)
    func safeEnumCodeIsProved(_ o: Optimization) throws {
        let module = EnumFixture.module(o)
        for name in ["turn", "isVertical", "wide", "code", "raw", "orZero", "bump", "both", "nested", "loftOr", "mkClub", "slotN", "pick"] {
            let verdict = try SILVerifier.proveAggregate(try EnumFixture.symbol(name, o), in: module)
            #expect(verdict == .proved, "\(name) at \(o.rawValue): \(verdict)")
        }
    }

    @Test(arguments: optimizations)
    func trapsBehindEnumsAreFoundWithRealInputs(_ o: Optimization) throws {
        let module = EnumFixture.module(o)
        guard case .counterexample(let f) = try SILVerifier.proveAggregate(try EnumFixture.symbol("force", o), in: module) else {
            Issue.record("force unwrap of nil must be found"); return
        }
        #expect(f[0] == 0, "the counterexample must be nil")

        guard case .counterexample(let a) = try SILVerifier.proveAggregate(try EnumFixture.symbol("area", o), in: module) else {
            Issue.record("circle area overflow must be found"); return
        }
        let r = Int32(truncatingIfNeeded: a[1])
        let (once, first) = Int32(3).multipliedReportingOverflow(by: r)
        #expect(a[0] == 0 && (first || once.multipliedReportingOverflow(by: r).overflow), "must be a circle whose area overflows: \(a)")

        guard case .counterexample(let l) = try SILVerifier.proveAggregate(try EnumFixture.symbol("checkedLoft", o), in: module) else {
            Issue.record("loft + 1 overflow must be found"); return
        }
        #expect(l[0] == 1 && l[1] == 127, "must be loft == 127: \(l)")

        // Generic enums: the payload type comes from the use (`Load<Int8>`, `Load<Int16>`).
        guard case .counterexample(let v) = try SILVerifier.proveAggregate(try EnumFixture.symbol("loadValue", o), in: module) else {
            Issue.record("loaded(127) + 1 overflow must be found"); return
        }
        #expect(v[0] == 1 && v[1] == 127, "must be .loaded(127): \(v)")
        guard case .counterexample(let m) = try SILVerifier.proveAggregate(try EnumFixture.symbol("mkLoad", o), in: module) else {
            Issue.record("Int16(x) * 300 overflow must be found"); return
        }
        #expect(Int8(truncatingIfNeeded: m[0]) <= -110, "only x <= -110 overflows: \(m)")
    }

    @Test(arguments: optimizations)
    func resultsAreAlwaysRealValues(_ o: Optimization) throws {
        let module = EnumFixture.module(o)
        // Shape has 3 cases in a 2-bit tag: tag 3 is not a value. Input values are assumed real, so results are too.
        let wide = try SILVerifier.proveAggregate(
            try EnumFixture.symbol("wide", o), in: module,
            ensures: { c, _, r in
                let real = c.ult(r[0], c.constant(3, width: 2))
                let circleClean = c.or(
                    -c.eq(r[0], c.constant(0, width: 2)), c.and(c.eq(r[2], c.constant(0, width: 32)), c.eq(r[3], c.constant(0, width: 32))))
                return c.and(real, circleClean)
            })
        #expect(wide == .proved)
        // A precise claim: the rect width doubles and everything else is unchanged.
        let doubled = try SILVerifier.proveAggregate(
            try EnumFixture.symbol("wide", o), in: module,
            ensures: { c, a, r in
                let isRect = c.eq(a[0], c.constant(1, width: 2))
                let twice = c.add(a[2], a[2]).sum
                return c.and(c.and(c.eq(r[0], a[0]), c.eq(r[1], a[1])), c.and(c.eq(r[2], c.select(isRect, twice, a[2])), c.eq(r[3], a[3])))
            })
        #expect(doubled == .proved)
        // `x ?? 0` equals the payload leaf for every real input, because nil carries a zero payload.
        let payload = try SILVerifier.proveAggregate(
            try EnumFixture.symbol("orZero", o), in: module, ensures: { c, a, r in c.eq(r[0], a[1]) })
        #expect(payload == .proved)
        // A wrong claim still gets a counterexample.
        let wrong = try SILVerifier.proveAggregate(
            try EnumFixture.symbol("orZero", o), in: module, ensures: { c, _, r in -c.eq(r[0], c.constant(0, width: 32)) })
        guard case .counterexample(let v) = wrong else { Issue.record("expected a counterexample, got \(wrong)"); return }
        #expect(v[1] == 0, "the result is 0 only for nil or .some(0): \(v)")
    }

    @Test func rawValueInitMapsExactly() throws {
        for o in Self.optimizations {
            let verdict = try SILVerifier.proveAggregate(
                try EnumFixture.symbol("code", o), in: EnumFixture.module(o),
                ensures: { c, a, r in
                    func k(_ v: Int8) -> BV { c.constant(UInt64(UInt8(bitPattern: v)), width: 8) }
                    func tag(_ t: UInt64) -> BV { c.constant(t, width: 2) }
                    let some = c.eq(r[0], c.constant(1, width: 1))
                    let expectSome = c.or(c.or(c.eq(a[0], k(0)), c.eq(a[0], k(4))), c.eq(a[0], k(-3)))
                    let mapped = c.select(c.eq(a[0], k(0)), tag(0), c.select(c.eq(a[0], k(4)), tag(1), tag(2)))
                    return c.and(-c.xor(some, expectSome), c.or(-some, c.eq(r[1], mapped)))
                })
            #expect(verdict == .proved, "\(o.rawValue): \(verdict)")
        }
    }

    @Test func optimizedAndUnoptimizedEnumCodeAgree() throws {
        for spec in EnumFixture.specs {
            let a = try EnumFixture.symbol(spec.name, .none), b = try EnumFixture.symbol(spec.name, .speed)
            let verdict = try SILVerifier.proveEquivalent(a, in: EnumFixture.onone, b, in: EnumFixture.speed)
            #expect(verdict == .proved, "\(spec.name): -Onone and -O differ: \(verdict)")
        }
    }

    @Test func layoutIsTagThenEveryCasePayload() throws {
        let f = try EnumFixture.onone.function(try EnumFixture.symbol("area", .none))
        #expect(f.parameterWidths == [2, 32, 32, 32])
        let n = try EnumFixture.onone.function(try EnumFixture.symbol("nested", .none))
        #expect(n.parameterWidths == [1, 1, 8])
        let d = try EnumFixture.onone.function(try EnumFixture.symbol("turn", .none))
        #expect(d.parameterWidths == [2] && d.resultWidths == [2])
    }

    @Test func indirectEnumsAreRejected() throws {
        let module = EnumRejectFixture.onone
        for name in ["leaf"] {
            let symbol = try module.symbol(module: "Er", name: name)
            #expect(throws: SILError.self, "\(name) must be rejected") {
                let f = try module.function(symbol)
                let c = CNFBuilder()
                _ = try SILEncoder(module: module, builder: c).encode(
                    symbol: symbol, arguments: f.parameterWidths.map { c.input(width: $0) })
            }
        }
    }
}
