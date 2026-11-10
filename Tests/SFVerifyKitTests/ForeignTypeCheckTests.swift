import Foundation
import SFSIL
import Testing

@testable import SFVerifyKit

/// Plan item R6-1: which names are Objective-C types comes from the demangler's trees, their Swift names from the
/// compiler's "renamed" errors, and the supertypes a probe must ask about from the SIL's inheritance clauses.
@Suite struct ForeignTypeCheckTests {
    /// Trees as `swift-demangle -tree-only` prints them: a class and a protocol of `__C`, and a Swift protocol.
    static let trees = """
        Demangling for $s7MainApp4RuleV5input9formatterACSo20KmpDomainReportStatsC_AA9Formatter_ptcfC
        kind=Global
          kind=Allocator
            kind=Type
              kind=FunctionType
                kind=ArgumentTuple
                  kind=Type
                    kind=Class
                      kind=Module, text="__C"
                      kind=Identifier, text="KmpDomainReportStats"
                  kind=Type
                    kind=Protocol
                      kind=Module, text="MainApp"
                      kind=Identifier, text="Formatter"
                  kind=Type
                    kind=Protocol
                      kind=Module, text="__C"
                      kind=Identifier, text="DomainRecord"
                  kind=Type
                    kind=Structure
                      kind=Module, text="__C"
                      kind=Identifier, text="CGRect"
        """

    @Test func theTreesNameTheClassesAndProtocolsOfTheClangModule() {
        let found = ForeignTypeCheck.clangTypes(inTrees: Self.trees)
        #expect(found.classes == ["KmpDomainReportStats"])
        #expect(found.protocols == ["DomainRecord"], "a protocol of another module and a C struct are not foreign objects")
    }

    @Test func aRenamedTypeGetsItsSwiftName() {
        let renamed = ForeignTypeCheck.renaming("'SharedKtDouble' has been renamed to 'KotlinDouble'")
        #expect(renamed?.from == "SharedKtDouble" && renamed?.to == "KotlinDouble")
        #expect(ForeignTypeCheck.renaming("cannot convert return expression of type 'SFX' to return type 'GKTKind'") == nil)
        #expect(ForeignTypeCheck.renaming("'a b' has been renamed to 'c'") == nil)
    }

    /// Attributes, `where` clauses and generic arguments are not supertypes; an extension's `where` colon is no clause.
    @Test func inheritanceClausesGiveTheSupertypesToAskAbout() throws {
        let text = """
            sil_stage canonical

            import GKT

            @objc @_inheritsConvenienceInitializers final class Mine : GKTDomainX, @unchecked Sendable {
            }

            extension Array where Element : Identifiable {
            }

            extension Holder : nonisolated Observable {
            }

            class Box<T> : Base<T> where T : Equatable {
            }

            sil @$s1M4mineySo10GKTDomainXCF : $@convention(thin) (@guaranteed GKTDomainX) -> () {
            bb0(%0 : $GKTDomainX):
              %1 = tuple ()
              return %1
            }
            """
        var module = try SILModule(text: text)
        #expect(module.foreignCandidateSymbols == ["$s1M4mineySo10GKTDomainXCF"])
        module.confirmForeignTypes(classes: ["GKTDomainX", "GKTKind"], protocols: [])
        let question = module.foreignSupertypeQuestion
        #expect(question.supertypes == ["Base", "GKTDomainX", "Observable"], "\(question.supertypes)")
        #expect(question.types == ["GKTKind"], "a subclassed foreign type is refused without asking")
    }

    /// When the probe ran, its answer decides, also without supertypes: a name it could not resolve (an ambiguous bare
    /// name, say) is not read.
    @Test func aTypeTheProbeLeftOutIsNotRead() throws {
        func body(_ name: String) -> String {
            """
            sil @$s1M3use\(name)ySo1\(name)CF : $@convention(thin) (@guaranteed \(name)) -> Int32 {
            bb0(%0 : $\(name)):
              %1 = objc_method %0, #\(name).count!getter.foreign : (\(name)) -> () -> Int32, $@convention(objc_method) (\(name)) -> Int32
              %2 = apply %1(%0) : $@convention(objc_method) (\(name)) -> Int32
              return %2
            }
            """
        }
        var module = try SILModule(text: "sil_stage canonical\n\n" + body("A") + "\n\n" + body("B") + "\n")
        module.confirmForeignTypes(classes: ["A", "B"], protocols: [])
        module.confirmUnrelatedForeignTypes(["A"])
        _ = try module.function("$s1M3useAySo1ACF")
        #expect(throws: SILError.self) { _ = try module.function("$s1M3useBySo1BCF") }
    }

    /// A malformed member reference (`!` before `.`) or receiver is refused, never a crash.
    @Test func malformedObjectiveCCallsAreRefused() throws {
        for reference in ["#GKTKind!getter.foreign", "#GKTKind.driver.foreign", "#!.foreign", "#GKTKind.!foreign"] {
            let text = """
                sil_stage canonical

                sil @$s1M1fySo7GKTKindCF : $@convention(thin) (@guaranteed GKTKind) -> Int32 {
                bb0(%0 : $GKTKind):
                  %1 = objc_method %0, \(reference) : (GKTKind) -> () -> Int32, $@convention(objc_method) (GKTKind) -> Int32
                  %2 = apply %1(%0) : $@convention(objc_method) (GKTKind) -> Int32
                  return %2
                }
                """
            var module = try SILModule(text: text)
            module.confirmForeignTypes(classes: ["GKTKind"], protocols: [])
            module.confirmUnrelatedForeignTypes(["GKTKind"])
            #expect(throws: SILError.self, "\(reference)") { _ = try module.function("$s1M1fySo7GKTKindCF") }
        }
    }
}
