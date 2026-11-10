import Foundation
import SFSIL
import SFVerifyKit
import Testing

/// Plan item U7: an unsupported function says where the construct is, the calls that lead there, and what to change;
/// an undecided one says why, and a reason other than the budget is not filed under the budget.
@Suite struct ExplainTests {
    static let source = """
        public func widen(_ a: Int16, _ b: Int16) -> Int32 {
            numericCast(a) &+ numericCast(b)
        }
        public func viaCallee(_ a: Int16) -> Int32 {
            widen(a, 1) &+ 1
        }
        public func greet(_ name: String) -> Int {
            name.count + 1
        }
        """

    static func scan(_ source: String = source, budget: Int = 300_000) throws -> ScanReport {
        let directory = NSTemporaryDirectory() + "sfv-u7-\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: directory) }
        let file = directory + "/explain.swift"
        try source.write(toFile: file, atomically: true, encoding: .utf8)
        var options = VerifyOptions(conflictBudget: budget)
        options.configurations = [.debug]
        return try SFVerify.run(CompileOptions(files: [file], moduleName: "Explain"), options)
    }

    @Test func anUnsupportedCallIsPlacedAtItsLineWithAFix() throws {
        let report = try Self.scan()
        let f = try #require(report.functions.first { $0.name.hasPrefix("widen(") })
        #expect(f.status == .unsupported)
        #expect(f.category == "generics")
        #expect(f.at?.line == 2, "\(String(describing: f.at))")
        #expect(f.calledFrom == nil)
        #expect(f.hint?.contains("numericCast") == true)
        let text = report.text(showUnsupported: true)
        #expect(text.contains("      at \(f.at?.description ?? "?"): generic call to numericCast"), "\(text)")
        #expect(text.contains("      fix: "))
    }

    /// App study round 6, bug D: `x.magnitude` was not read on floating point, so the hint for `abs` suggested something
    /// Scan refused too. `abs` on `Double` and `Float` is now read (the float summaries); the hint still covers the
    /// floating-point types `abs` is refused for (`CGFloat`, `Float80`), and an integer `abs` keeps the general hint.
    @Test func absOnFloatingPointSuggestsTheComparison() throws {
        let report = try Self.scan(
            """
            public func distance(_ x: Double) -> Double { abs(x) }
            public func spread(_ x: Float) -> Float { abs(x) }
            """)
        for name in ["distance(", "spread("] {
            let f = try #require(report.functions.first { $0.name.hasPrefix(name) })
            #expect(f.status == .safe, "\(f.status) \(String(describing: f.detail))")
        }
        for type in ["CGFloat", "Float80"] {
            let hint = Verifier.hint(forCategory: "generics", detail: "generic call to abs<A>(_:) with <\(type)>")
            #expect(hint.contains("x < 0 ? -x : x"), "\(hint)")
            #expect(!hint.contains("magnitude"), "\(hint)")
        }
        let integer = Verifier.hint(forCategory: "generics", detail: "generic call to numericCast<A, B>(_:) with <Int16, Int>")
        #expect(integer == Verifier.hint(forCategory: "generics"))
    }

    @Test func aRefusalInACalleeHasCalledFromNotes() throws {
        let report = try Self.scan()
        let f = try #require(report.functions.first { $0.name.hasPrefix("viaCallee(") })
        #expect(f.status == .unsupported)
        #expect(f.at?.line == 2, "\(String(describing: f.at))")
        #expect(f.calledFrom?.map(\.line) == [5])
        let notes = report.diagnostics(showUnsupported: true).split(separator: "\n").filter { $0.contains(":5:") }
        #expect(notes.contains { $0.hasSuffix("note: called from here") }, "\(notes)")
        #expect(!report.diagnostics().contains("called from here"))
    }

    @Test func undecidedSaysWhyAndIsNotFiledUnderTheBudget() throws {
        let report = try Self.scan()
        let greet = try #require(report.functions.first { $0.name.hasPrefix("greet(") })
        #expect(greet.status == .undecided)
        #expect(greet.category == Verifier.unmodelledCategory)
        let text = report.text()
        #expect(!text.contains("Undecided (budget)"))
        #expect(text.contains("Undecided: 1\n    1 × unmodelled results"), "\(text)")
    }

    @Test func runningOutOfConflictsIsFiledUnderTheBudget() throws {
        let report = try Self.scan(
            """
            public func commutes(_ a: UInt16, _ b: UInt16) -> UInt16 {
                precondition(a &* b == b &* a)
                return a
            }
            """, budget: 1)
        let f = try #require(report.functions.first)
        #expect(f.status == .undecided)
        #expect(f.category == Verifier.budgetCategory)
        #expect(f.hint?.contains("--budget") == true)
    }

    @Test func everyCategoryHasItsOwnHint() {
        let note = SILError.supportedTypesNote
        let errors: [SILError] = [
            .unsupported("type Optional<Int>\(note)"), .unsupported("type String\(note)"), .unsupported("type Set<Int>\(note)"),
            .unsupported("type Array<Int>\(note)"), .unsupported("type IndexingIterator<Range<Int>>\(note)"),
            .unsupported("type Double\(note)"), .unsupported("type any P\(note)"),
            .unsupported("type @_opaqueReturnTypeOf(\"x\", 0)\(note)"), .unsupported("type @callee_guaranteed () -> ()\(note)"),
            .unsupported("array of any P"), .unsupported("destroying a closure"), .unsupported("UNSUPPORTED: class C"),
            .unsupported("indirect enum E"), .unsupported("loops in f"), .unsupported("recursion through f"),
            .unsupported("call depth above 8 at f"), .unsupported("no body for f"), .unsupported("generic call to abs"),
            .unsupported("witness_method"), .unsupported("indirect call"), .unsupported("mutable global g"),
            .unsupported("global g"), .unsupported("async f"), .invalid("what is this"),
            .unsupported("\(SILError.ambiguousTypeKind)"),
        ]
        for error in errors {
            let category = Verifier.category(of: error)
            #expect(Verifier.categoryHints[category] != nil, "no hint for \(category) (\(error))")
        }
        #expect(Verifier.hint(forCategory: "type Foo").contains("Scan cannot read Foo"))
    }

    /// A `Double` stored in a struct printed as its bit pattern (`self = HB(input: 5755600323779493888)`), while the
    /// replay line printed the number: the layout has only a 64-bit leaf, so the field's declared type is needed.
    @Test func aFloatingPointFieldIsPrintedAsANumber() throws {
        let report = try Self.scan(
            """
            public struct HB {
                public let input: Double
                public var scaled: Int { Int((abs(input) * 10.0).rounded()) }
            }
            """)
        let f = try #require(report.functions.first { $0.name == "HB.scaled.getter" })
        #expect(f.status == .mayTrap, "\(f.status) \(f.detail ?? "")")
        let input = try #require(f.counterexample?.inputs.first)
        let prefix = "self = HB(input: "
        #expect(input.hasPrefix(prefix) && input.hasSuffix(")"), "\(input)")
        let number = String(input.dropFirst(prefix.count).dropLast())
        #expect(number.contains(".") || number.contains("e") || number.contains("nan") || number.contains("inf"), "\(input)")
        #expect(f.counterexample?.replay == "HB(input: \(number)).scaled", "\(String(describing: f.counterexample?.replay))")
    }

    /// The same inside an `Optional` (the app's `TargetPresentationRule(input: -2251799813685248)`, a NaN).
    @Test func anOptionalFloatingPointFieldIsPrintedAsANumber() throws {
        let report = try Self.scan(
            """
            public struct Target {
                public let input: Double?
                public var whole: Int { input.map { Int($0) } ?? 0 }
            }
            """)
        let f = try #require(report.functions.first { $0.name == "Target.whole.getter" })
        #expect(f.status == .mayTrap, "\(f.status) \(f.detail ?? "")")
        let input = try #require(f.counterexample?.inputs.first)
        let prefix = "self = Target(input: "
        #expect(input.hasPrefix(prefix) && input.hasSuffix(")"), "\(input)")
        let value = String(input.dropFirst(prefix.count).dropLast())
        #expect(Int64(value) == nil, "a Double printed as an integer: \(input)")
    }
}
