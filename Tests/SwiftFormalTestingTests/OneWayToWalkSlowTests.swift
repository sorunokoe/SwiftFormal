// Builds a fixture package with `Process`: macOS and Linux only.
#if os(macOS) || os(Linux)
    import Foundation
    import SFTestSupport
    import Testing

    /// One way to walk: from a package that depends on SwiftFormal as an app does, every `Prove` form and `@Verify`
    /// compile, and every name that walked before `Prove` does not, with a message that names what to write instead.
    /// A cold run builds SwiftFormal and swift-syntax for the fixture (minutes); later runs are incremental.
    @Suite(.serialized) struct OneWayToWalkSlowTests {
        private static let walks = """
            import SwiftFormal
            import SwiftFormalTesting
            import SwiftUI
            import Testing

            enum Surface: CaseIterable, Finite { case grass, sand }

            /// SwiftUI next to the test library: its `Image` and `Table`, and the standard library's `min` and `max` next to
            /// SFProve's, which SwiftFormalTesting re-exports.
            @available(macOS 14, *)
            struct Names {
                let image = Image(systemName: "flag")
                let small = min(1, 2) + max(3, 4)
                let large = max(1.5, 2.5)
                let lowest = [3, 1, 2].min()
                func table(_ rows: [Row]) -> some View { Table(rows) { TableColumn("Name", value: \\.name) } }
            }

            struct Row: Identifiable {
                let id: Int
                let name: String
            }

            enum Halve: ExitTestWalk {
                static let inputs: Domain<Int> = .int(0...3)
                static func call(_ value: Int) -> Int { value / 2 }
            }

            @Verify(over: .int(0...3))
            func half(_ value: Int) -> Int {
                #requires(value >= 0)
                #ensures { $0 <= value }
                return value / 2
            }

            @Suite(.swiftFormal(budget: Budget(maxEvaluations: 100), allowBounded: true))
            struct Walks {
                @Test func everyForm() async {
                    Prove(it: { (surface: Surface) in "\\(surface)" }, over: .allCases) { Deterministic() }
                    Prove("Surface.label", it: { (surface: Surface) in "\\(surface)" }) { Injective() }
                    Prove(it: { counter.add(into: &$0, $1) }, over: .sessions(from: 0, actions: .int(0...2), upTo: 2)) {
                        Always("never negative") { $0 >= 0 }
                    }
                    Prove(it: { $0 += $1 }, over: .sessions(from: Domain<Int>.int(0...1), actions: .int(0...2), upTo: 2)) {
                        EachStep("never shrinks") { before, _, after in after >= before }
                    }
                    await Prove(neverTraps: Halve.self)
                    await Prove("Halve.call(_:)", neverTraps: Halve.self, budget: Budget(maxEvaluations: 2), allowBounded: true)
                    let walk = Prove(it: { (flag: Bool) in !flag }, over: .bool, reporting: .everyFailure, knownIssue: nil) {
                        Satisfies("flips") { flag, flipped in flag != flipped }
                    }
                    _ = (walk.report.isProved, walk.failures.count, verify_half().isProved)
                    // The symbolic integer proofs come with the same import.
                    let proof = try? proveSigned(widths: [8], requires: { $0[0] >= 0 }) { v in v[0] >= 0 }
                    _ = proof == .proved
                }
            }

            struct Counter {
                /// Returns a value, as a TCA reducer returns an effect: the step closure may call it without `_ =`.
                func add(into total: inout Int, _ amount: Int) -> Int {
                    total += amount
                    return total
                }
            }

            let counter = Counter()

            """

        /// One removed call per line, each with the word its message must contain.
        private static let removed: [(call: String, hint: String)] = [
            ("expectProved(report)", "Prove("),
            ("expectProved(\"f\", { (flag: Bool) in flag }, over: .bool)", "Prove("),
            ("expectProved(\"f\", { (flag: Bool) in flag })", "Prove("),
            ("expectProved(\"S.step\", from: 0, actions: .int(0...1), upTo: 2, step: { $0 += $1 })", "Prove("),
            ("expectProved(\"S.step\", from: Domain<Int>.int(0...1), actions: .int(0...1), upTo: 2, step: { $0 += $1 })", "Prove("),
            ("prove(\"f\", { (flag: Bool) in flag }, over: .bool)", "Prove("),
            ("prove(\"f\", { (flag: Bool) in flag })", "Prove("),
            ("await expectNoTrap(\"Halve.call(_:)\", Halve.self)", "Prove(neverTraps:"),
            ("verify(\"f\", { (flag: Bool) in flag }, over: .bool)", "Prove("),
            ("verify(\"f\", { (flag: Bool) in flag })", "Prove("),
            ("verifyContracts(\"f\", { (flag: Bool) in flag }, over: .bool)", "@Verify"),
            ("partition({ (flag: Bool) in flag }, over: .bool)", "Prove("),
            ("lockBehavior(\"f\", { (flag: Bool) in flag }, over: .bool)", "Prove("),
            ("expectLocked(\"f\", { (flag: Bool) in flag }, over: .bool)", "Prove("),
            ("describeOutput(1)", "String(describing:)"),
            ("walkInExitTest(\"f\", { (flag: Bool) in flag }, over: .bool)", "neverTraps:"),
            ("Table<Bool, Int>([true: 1])", "Matches(table:)"),
            ("Image(equals: [1]) as Property<Bool, Int>", "Outputs(exactly:)"),
            ("Image(within: [1]) as Property<Bool, Int>", "Outputs(within:)"),
        ]

        /// What `Prove` and `@Verify` run on, `package` so that it is no way of its own: one use per line.
        private static let hidden = [
            "runWalk(\"f\", { (flag: Bool) in flag }, over: .bool)",
            "runPartition({ (flag: Bool) in flag }, over: .bool)",
            "checkBehaviorLock(\"f\", { (flag: Bool) in flag }, over: .bool)",
            "walkInThisExitTest(\"f\", { (flag: Bool) in flag }, over: .bool)",
            "TrapWalk<Bool>.self",
            "Partition<Bool, Bool>.self",
            "Checked<Bool>.self",
            "Parallelism.threads(2)",
        ]

        private static let header = """
            import SwiftFormal
            import SwiftFormalTesting
            import Testing

            enum Halve: ExitTestWalk {
                static let inputs: Domain<Int> = .int(0...3)
                static func call(_ value: Int) -> Int { value / 2 }
            }

            func removedNames(_ report: Report) async {

            """

        private func fixture() throws -> FixturePackage {
            let product = { (name: String) in ".product(name: \"\(name)\", package: \"SwiftFormal\")" }
            let dependencies = "[\(product("SwiftFormal")), \(product("SwiftFormalTesting"))]"
            let removed = Self.header + Self.removed.map { "    _ = \($0.call)\n" }.joined() + "}\n"
            let hidden = Self.header + Self.hidden.map { "    _ = \($0)\n" }.joined() + "}\n"
            return try FixturePackage(
                name: "one-way-to-walk",
                targets: """
                        .target(name: "Walks", dependencies: \(dependencies)),
                        .target(name: "RemovedNames", dependencies: \(dependencies)),
                        .target(name: "HiddenNames", dependencies: \(dependencies)),
                    """,
                files: [
                    "Sources/Walks/Walks.swift": Self.walks, "Sources/RemovedNames/RemovedNames.swift": removed,
                    "Sources/HiddenNames/HiddenNames.swift": hidden,
                ])
        }

        @Test func everyProveFormCompilesOutsideThePackage() throws {
            let build = try fixture().build(target: "Walks")
            #expect(build.status == 0, "\(build.output.suffix(4000))")
        }

        @Test func everyRemovedNameFailsWithAPointerToItsReplacement() throws {
            let build = try fixture().build(target: "RemovedNames")
            #expect(build.status != 0)
            let errors = build.errors(in: "RemovedNames.swift")
            let firstLine = Self.header.split(separator: "\n", omittingEmptySubsequences: false).count
            for (offset, removed) in Self.removed.enumerated() {
                let messages = errors[firstLine + offset] ?? []
                #expect(
                    messages.contains { $0.contains("is unavailable") && $0.contains(removed.hint) },
                    "\(removed.call): \(messages)\n\(build.output.suffix(3000))")
            }
        }

        @Test func whatProveRunsOnIsHidden() throws {
            let build = try fixture().build(target: "HiddenNames")
            #expect(build.status != 0)
            let errors = build.errors(in: "HiddenNames.swift")
            let firstLine = Self.header.split(separator: "\n", omittingEmptySubsequences: false).count
            for (offset, name) in Self.hidden.enumerated() {
                let messages = errors[firstLine + offset] ?? []
                #expect(
                    messages.contains { $0.contains("cannot find") || $0.contains("inaccessible") },
                    "\(name): \(messages)\n\(build.output.suffix(3000))")
            }
        }
    }
#endif
