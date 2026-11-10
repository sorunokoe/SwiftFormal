namespace SILReaderTests

def symbol := "$s13BridgeFixture15clampedDiscountys5Int64VAD_ADtF"

def input := r#"sil_stage canonical
sil @$s13BridgeFixture15clampedDiscountys5Int64VAD_ADtF : $@convention(thin) (Int64, Int64) -> Int64 {
bb0(%0 : $Int64, %1 : $Int64):
  br bb1(%1, %0)
bb1(%2 : $Int64, %3 : $Int64):
  return %2
}
"#

def expected : ReferenceIR.Program := [
  (0, { parameters := [0, 1], instructions := [.branch { block := 1, arguments := [1, 0] }] }),
  (1, { parameters := [2, 3], instructions := [.returned 2] })
]

set_option maxRecDepth 8192 in
theorem preservesOperandsAndBlockArguments :
    SILInput.readChunks [input.toByteArray.data.toList] symbol = .ok expected := by decide +kernel

#print axioms preservesOperandsAndBlockArguments
end SILReaderTests
