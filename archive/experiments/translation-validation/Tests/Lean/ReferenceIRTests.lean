namespace ReferenceIRTests
open ReferenceIR

def environment : Environment :=
  [(0, .word 9223372036854775807), (1, .word 1), (2, .bit true)]

theorem instructionSemantics :
    evaluate environment (.add 0 1 2) = some (.pair (-9223372036854775808) true) /\
    evaluate environment (.subtract 1 0 2) = some (.pair (-9223372036854775806) false) /\
    evaluate [(0, .word (-9223372036854775808)), (1, .word 1), (2, .bit true)]
      (.subtract 0 1 2) = some (.pair 9223372036854775807 true) /\
    evaluate [(0, .pair (-9223372036854775808) true)] (.project 0 0) =
      some (.word (-9223372036854775808)) /\
    evaluate [(0, .pair (-9223372036854775808) true)] (.project 0 1) = some (.bit true) /\
    evaluate environment (.box 99) = none /\
    evaluate [(0, .boxed 1)] (.box 0) = none /\
    evaluate ((2, .bit false) :: environment) (.add 0 1 2) = none /\
    run 1 [] [(2, .bit true)] [.trap 2] = .arithmeticTrap /\
    run 2 [(1, { parameters := [2, 3], instructions := [.returned 2] })]
      [(0, .boxed 7), (1, .boxed 9)] [.branch { block := 1, arguments := [1, 0] }] = .returned 9 /\
    run 0 [] [] [] = .exhausted /\
    run 1 [] [] [] = .invalidIR /\
    jump [(0, { parameters := [0], instructions := [] })] [] { block := 0, arguments := [] } = none := by
  decide

#print axioms instructionSemantics
end ReferenceIRTests
