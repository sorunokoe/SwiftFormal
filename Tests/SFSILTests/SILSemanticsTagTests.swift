import SFProve
import SFSIL
import Testing

/// Plan item R9: the `[_semantics "…"]` tags the compiler prints on a summarized callee are a fail-closed cross-check
/// of the summary table. A tag the table does not expect for that symbol refuses the call (`unsupported`); a tag never
/// adds behaviour, and a callee printed without tags is accepted.
@Suite struct SILSemanticsTagTests {
    /// `public func same(_ a: String, _ b: String) -> Bool { a == b }`, as `swiftc -emit-sil -Onone` prints it.
    private static func module(declaring attributes: String) throws -> SILModule {
        try SILModule(
            text: """
                sil_stage canonical

                import Builtin
                import Swift

                sil @$s1T4sameySbSS_SStF : $@convention(thin) (@guaranteed String, @guaranteed String) -> Bool {
                bb0(%0 : $String, %1 : $String):
                  %4 = metatype $@thin String.Type
                  %5 = function_ref @$sSS2eeoiySbSS_SStFZ : $@convention(method) (@guaranteed String, @guaranteed String, @thin String.Type) -> Bool
                  %6 = apply %5(%0, %1, %4) : $@convention(method) (@guaranteed String, @guaranteed String, @thin String.Type) -> Bool
                  return %6
                }

                sil \(attributes)@$sSS2eeoiySbSS_SStFZ : $@convention(method) (@guaranteed String, @guaranteed String, @thin String.Type) -> Bool
                """)
    }

    private static func verdict(declaring attributes: String) throws -> ProofVerdict {
        try SILVerifier.proveAggregate("$s1T4sameySbSS_SStF", in: try module(declaring: attributes), conflictBudget: 2_000)
    }

    @Test func theExpectedTagOrNoTagKeepsTheSummary() throws {
        #expect(try Self.verdict(declaring: "[heuristic_always_inline] [readonly] [_semantics \"string.equals\"] ") == .proved)
        #expect(try Self.verdict(declaring: "[readonly] ") == .proved)
    }

    @Test func anUnexpectedTagRefusesTheCall() throws {
        for attributes in [
            "[_semantics \"array.mutate_unknown\"] ",
            "[_semantics \"string.equals\"] [_semantics \"optimize.sil.specialize.generic.never\"] ",
        ] {
            #expect {
                _ = try Self.verdict(declaring: attributes)
            } throws: { error in
                guard case SILError.unsupported(let reason) = error else { return false }
                return reason.contains("_semantics") && reason.contains("String.==")
            }
        }
    }

    @Test func tagsArePerSymbolAndSurviveLinking() throws {
        let module = try Self.module(declaring: "[_semantics \"string.equals\"] [_semantics \"x.y\"] ")
        #expect(module.semanticsTags(of: "$sSS2eeoiySbSS_SStFZ") == ["string.equals", "x.y"])
        #expect(module.semanticsTags(of: "$s1T4sameySbSS_SStF").isEmpty)
        var linked = try Self.module(declaring: "")
        linked.link(module)
        #expect(linked.semanticsTags(of: "$sSS2eeoiySbSS_SStFZ") == ["string.equals", "x.y"])
    }

    /// Every entry names the tags it expects, and only the documented ones carry any (see `StdlibSummary.Entry.semantics`).
    @Test func theTableExpectsTheTagsTheCompilerPrints() {
        let tagged = StdlibSummary.table.filter { !$0.value.semantics.isEmpty }.mapValues(\.semantics)
        #expect(tagged["$sSS2eeoiySbSS_SStFZ"] == ["string.equals"])
        #expect(tagged["$sSa6remove2atxSi_tF"] == ["array.mutate_unknown"])
        #expect(tagged["$sSD17dictionaryLiteralSDyxq_Gx_q_td_tcfC"] == ["optimize.sil.specialize.generic.size.never"])
        #expect(tagged["$ss21_findStringSwitchCase5cases6stringSiSays06StaticB0VG_SStF"] == ["findStringSwitchCase"])
        #expect(tagged.count == 16)
    }
}
