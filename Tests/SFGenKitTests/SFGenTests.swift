import Foundation
@testable import SFGenKit
import Testing

// The generator reads sources with swift-syntax, which only the `Generator` trait (on by default) builds.
#if Generator

    private let source = """
        enum Mode { case fast, slow(level: Int) }

        struct Input {
            let mode: Mode
            let name: String?
            var tags: [Bool] = []
        }

        struct ThresholdRule: Rule {
            let input: Input
            var body: String { input.mode == .fast && input.name == "gold" ? "vip" : "x" }
            func limit() -> Int { 42 }
        }

        struct PlainRule: Rule {
            let input: Bool
            var body: String { input ? "y" : "n" }
        }

        struct ClosureRule: Rule {
            let input: (Int) -> Int
            var body: Int { input(1) }
        }

        struct PrivateStoredRule: Rule {
            private let input: Int
            var body: Int { input }
        }
        """

    private func makeIndex() -> (TypeIndex, SourceIndexer) {
        let index = TypeIndex()
        let indexer = SourceIndexer(index: index)
        indexer.indexSource(source, path: "Rules.swift")
        return (index, indexer)
    }

    @Suite struct SFGenTests {
        @Test func findsRulesWithTheirLiterals() {
            let (_, indexer) = makeIndex()
            #expect(indexer.rules.map(\.name) == ["ThresholdRule", "PlainRule", "ClosureRule", "PrivateStoredRule"])
            let rule = indexer.rules[0]
            #expect(rule.ints == [42] && rule.strings.contains("gold") && rule.strings.contains("vip"))
        }

        @Test func buildsDomainsFromEnumsPayloadsOptionalsAndArrays() throws {
            let (index, indexer) = makeIndex()
            let result = RuleGenerator.generate(
                rules: indexer.rules, index: index, options: GenerationOptions(imports: [], testableImports: ["App"])
            )
            #expect(result.generated == ["ThresholdRule", "PlainRule"])
            let skipped = Dictionary(uniqueKeysWithValues: result.skipped.map { ($0.rule, $0.reason) })
            #expect(skipped["ClosureRule"]?.contains("closure") == true)
            #expect(skipped["PrivateStoredRule"]?.contains("private stored property") == true)

            let text = result.source
            #expect(text.contains("Domain<Mode>.union"), "payload enum is a union of its cases")
            #expect(text.contains("Domain<Int>.samples") && text.contains("42"), "the Rule's literal becomes an input value")
            #expect(text.contains("\"gold\""))
            #expect(text.contains(".optional("))
            #expect(text.contains("@testable import App"))
            // Test code in the app's package sees only the public API: the one way to walk, nothing removed.
            #expect(text.contains("let report = Prove(") && text.contains("{ Deterministic() }.report"))
            for removed in ["expectProved", "expectLocked", "describeOutput", "verify(", "__SFLocks__"] {
                #expect(!text.contains(removed), "\(removed)")
            }
        }

        @Test func resolvesKotlinStyleProtocolsThroughTheirConformers() {
            let index = TypeIndex()
            index.add(TypeInfo(name: "Shape", kind: .protocolType))
            var circle = TypeInfo(name: "Circle", kind: .classType)
            circle.inits = [[TypeParam(label: "radius", type: "Double")]]
            var origin = TypeInfo(name: "Origin", kind: .classType)
            origin.hasShared = true
            index.add(circle)
            index.add(origin)
            index.addSubtype("Circle", of: "Shape")
            index.addSubtype("Origin", of: "Shape")

            let builder = DomainBuilder(index: index)
            let built = try? builder.domain(for: "any Shape", scope: nil, pool: nil)
            #expect(built?.type == "any Shape")
            let all = builder.declarations.joined(separator: "\n")
            #expect(all.contains("Origin.shared") && all.contains("Circle(radius: "))
            #expect(all.contains("-> any Shape in value"))
        }

        @Test func skieTypeDefTargetsDropTheFrameworkPrefix() throws {
            let index = TypeIndex()
            var shot = TypeInfo(name: "Shot", kind: .enumeration)
            shot.cases = [TypeEnumCase(name: "drive"), TypeEnumCase(name: "putt")]
            shot.module = "SharedKt"
            index.add(shot)
            let builder = DomainBuilder(index: index)
            for spelling in [
                "__Skie__TypeDef__0__id_Shot_", "__Skie__TypeDef__1__id_SharedKtShot_",
                "__Skie__TypeDef__2__id_SharedKtModelsShot_",
            ] {
                #expect(try builder.domain(for: spelling, scope: nil, pool: nil).type == "Shot", "\(spelling)")
            }
            #expect(throws: Unsupported.self) {
                try builder.domain(for: "__Skie__TypeDef__3__id_OtherKtShot_", scope: nil, pool: nil)
            }
        }

        @Test func unknownTypesAreSkippedWithAReasonAndRecursionIsCut() {
            let index = TypeIndex()
            var node = TypeInfo(name: "Node", kind: .enumeration)
            node.cases = [TypeEnumCase(name: "leaf"), TypeEnumCase(name: "pair", params: [TypeParam(label: nil, type: "Node")])]
            index.add(node)
            let builder = DomainBuilder(index: index)
            #expect(throws: Unsupported.self) { try builder.domain(for: "Mystery", scope: nil, pool: nil) }
            // The recursive case is dropped, the other case still gives a (partial) domain.
            let built = try? builder.domain(for: "Node", scope: nil, pool: nil)
            #expect(built != nil)
            #expect(builder.dropped["Node"]?.first?.contains("recursive") == true)
        }

        @Test func prunerRemovesTheRuleBehindABrokenSharedDomain() {
            let generated = """
                private let sfd_1: Domain<Int> = Domain<Int>.samples([0])
                private let sfd_2: Domain<X> = Domain<X>.just(X(a: sfd_1[0]))
                private let sfd_3: Domain<Y> = Domain<Y>.just(Y())
                // sfgen:rule A
                @Test("A") func testA() { sfCheck("A", sfd_2) }
                // sfgen:rule B
                @Test("B") func testB() { sfCheck("B", sfd_3) }
                """
            #expect(Pruner.rulesToExclude(generated: generated, errorLines: [1]) == ["A"])
            #expect(Pruner.rulesToExclude(generated: generated, errorLines: [7]) == ["B"])
        }
    }
#endif
