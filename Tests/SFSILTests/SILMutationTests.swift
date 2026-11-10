import SFSIL
import Testing

/// The edits `sfverify --mutate` checks a proved contract against (`SILModule.mutants(of:limit:)`), on SIL as the
/// compiler prints it at -Onone (debug positions already stripped, as Scan reads it).
@Suite struct SILMutationTests {
    /// `mutating func bump(_ by: Int8) -> Int8 { if by > 0 { reset() }; value = by; return limit }`.
    static let text = """
        sil_stage canonical

        public struct Meter {
          @_hasStorage public var value: Int8 { get set }
          @_hasStorage public var limit: Int8 { get set }
          public mutating func reset()
          public mutating func bump(_ by: Int8) -> Int8
          init(value: Int8, limit: Int8)
        }

        sil @$s1M5MeterV5resetyyF : $@convention(method) (@inout Meter) -> () {
        // %0 "self"
        bb0(%0 : $*Meter):
          %1 = integer_literal $Builtin.Int8, 0
          %2 = struct $Int8 (%1)
          %3 = begin_access [modify] [static] %0
          %4 = struct_element_addr %3, #Meter.value
          store %2 to %4
          end_access %3
          %7 = tuple ()
          return %7
        } // end sil function '$s1M5MeterV5resetyyF'

        sil @$s1M5MeterV4bumpys4Int8VAFF : $@convention(method) (Int8, @inout Meter) -> Int8 {
        // %0 "by"                                        // users: %16, %5, %2
        // %1 "self"                                      // users: %18, %14, %8, %3
        bb0(%0 : $Int8, %1 : $*Meter):
          %4 = integer_literal $Builtin.Int8, 0           // user: %6
          %5 = struct_extract %0, #Int8._value            // user: %6
          %6 = builtin "cmp_slt_Int8"(%4, %5) : $Builtin.Int1 // user: %7
          cond_br %6, bb1, bb2                            // id: %7

        bb1:                                              // Preds: bb0
          %8 = begin_access [modify] [static] %1          // users: %11, %10
          // function_ref Meter.reset()
          %9 = function_ref @$s1M5MeterV5resetyyF : $@convention(method) (@inout Meter) -> () // user: %10
          %10 = apply %9(%8) : $@convention(method) (@inout Meter) -> ()
          end_access %8                                   // id: %11
          br bb3                                          // id: %12

        bb2:                                              // Preds: bb0
          br bb3                                          // id: %13

        bb3:                                              // Preds: bb1 bb2
          %14 = begin_access [modify] [static] %1         // users: %17, %15
          %15 = struct_element_addr %14, #Meter.value     // user: %16
          store %0 to %15                                 // id: %16
          end_access %14                                  // id: %17
          %18 = begin_access [read] [static] %1           // users: %21, %19
          %19 = struct_element_addr %18, #Meter.limit     // user: %20
          %20 = load %19                                  // user: %22
          end_access %18                                  // id: %21
          return %20                                      // id: %22
        } // end sil function '$s1M5MeterV4bumpys4Int8VAFF'
        """
    static let bump = "$s1M5MeterV4bumpys4Int8VAFF"

    @Test func eachKindOfEditInPriorityOrder() throws {
        let module = try SILModule(text: Self.text)
        let mutants = module.mutants(of: Self.bump)
        #expect(
            mutants.map(\.description) == [
                "the call to Meter.reset() is skipped",
                "the write to self.value is dropped",
                "it returns by instead",
                "it returns 0 instead",
                "the condition of this branch is negated",
                "< becomes <=",
                "the constant 0 becomes 1",
            ])
        #expect(
            mutants.map(\.kind) == [
                .skippedCall, .droppedWrite, .returnedValue, .returnedValue, .negatedBranch, .changedOperator, .changedConstant,
            ])
        #expect(mutants.map(\.anchor) == ["%10", "%15", "%20", "%20", "%6", "%6", "%4"])
        #expect(mutants[0].replacement == ["  %10 = tuple ()"])
        #expect(mutants[3].replacement == ["  %23 = integer_literal $Builtin.Int8, 0", "  %24 = struct $Int8 (%23)", "  return %24"])
        #expect(mutants[4].replacement == ["  cond_br %6, bb2, bb1"])
    }

    @Test func everyEditIsStillSILTheReaderAccepts() throws {
        let module = try SILModule(text: Self.text)
        for mutant in module.mutants(of: Self.bump) {
            let mutated = try #require(mutant.applied(to: module), "\(mutant.description)")
            #expect(throws: Never.self, "\(mutant.description)") { try mutated.function(Self.bump) }
            #expect(mutated.bodyLines(of: Self.bump) != module.bodyLines(of: Self.bump))
        }
    }

    @Test func theLimitKeepsTheMostTellingEdits() throws {
        let module = try SILModule(text: Self.text)
        #expect(module.mutants(of: Self.bump, limit: 2).map(\.kind) == [.skippedCall, .droppedWrite])
        #expect(module.mutants(of: "$s1M5MeterV5resetyyF").map(\.kind) == [.droppedWrite, .changedConstant])
        #expect(module.mutants(of: "missing").isEmpty)
    }

    @Test func anEditOfAnotherBodyDoesNotApply() throws {
        let module = try SILModule(text: Self.text)
        let mutant = try #require(module.mutants(of: Self.bump).first)
        let changed = module.replacingBody(of: Self.bump, with: ["bb0(%0 : $Int8, %1 : $*Meter):", "  unreachable"])
        #expect(mutant.applied(to: changed) == nil)
    }

    @Test func casesThatEndUpInTheSameBlockAreNotSwapped() throws {
        let text = """
            sil_stage canonical

            public enum E {
              case a
              case b
              case c
            }

            sil @g : $@convention(thin) (E) -> Int8 {
            bb0(%0 : $E):
              switch_enum %0, case #E.a!enumelt: bb1, case #E.b!enumelt: bb2, case #E.c!enumelt: bb3

            bb1:
              br bb4

            bb2:
              br bb4

            bb3:
              %1 = integer_literal $Builtin.Int8, 1
              %2 = struct $Int8 (%1)
              br bb5(%2)

            bb4:
              %3 = integer_literal $Builtin.Int8, 0
              %4 = struct $Int8 (%3)
              br bb5(%4)

            bb5(%5 : $Int8):
              return %5
            }
            """
        let module = try SILModule(text: text)
        let swaps = module.mutants(of: "g").filter { $0.kind == .swappedCases }
        #expect(swaps.map(\.description) == ["the cases .b and .c are swapped"])
        #expect(swaps.first?.replacement == ["  switch_enum %0, case #E.a!enumelt: bb1, case #E.b!enumelt: bb3, case #E.c!enumelt: bb2"])
        let mutated = try #require(swaps.first?.applied(to: module))
        #expect(throws: Never.self) { try mutated.function("g") }
    }
}
