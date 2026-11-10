namespace LocalDebugTests

def symbol := "$s13BridgeFixture15clampedDiscountys5Int64VAD_ADtF"

def input (debug : String) : List (List UInt8) :=
  [(r#"sil_stage canonical
sil @$s13BridgeFixture15clampedDiscountys5Int64VAD_ADtF : $@convention(thin) (Int64, Int64) -> Int64 {
bb0(%0 : $Int64, %1 : $Int64):
  debug_value %0, let, name "subtotal", argno 1
  debug_value %1, let, name "discount", argno 2
  br bb1(%1, %0)
bb1(%2 : $Int64, %3 : $Int64):
  "# ++ debug ++ r#"
  return %2
}
"#).toByteArray.data.toList]

def expected : ReferenceIR.Program := [
  (0, { parameters := [0, 1], instructions :=
    [.debug, .debug, .branch { block := 1, arguments := [1, 0] }] }),
  (1, { parameters := [2, 3], instructions := [.debug, .returned 2] })
]

def localDebug := r#"debug_value %3, let, name "result""#

set_option maxRecDepth 8192 in
theorem acceptsParameterDebug :
    SILInput.readChunks (input (localDebug ++ ", argno 3")) symbol = .ok expected := by decide +kernel

set_option maxRecDepth 8192 in
theorem acceptsLocalDebug :
    SILInput.readChunks (input localDebug) symbol = .ok expected := by decide +kernel

set_option maxRecDepth 8192 in
theorem acceptsLocatedLocalDebug :
    SILInput.readChunks
      (input (localDebug ++ r#", loc "Fixture.swift":5:9, scope 5 // id: %4"#)) symbol =
      .ok expected := by decide +kernel

theorem returnsActualOperand :
    SILInput.executeChunks 8 (input localDebug) symbol 10 3 = .returned 3 := by
  unfold SILInput.executeChunks
  rw [acceptsLocalDebug]
  decide +kernel

def unsupported := [
  r#"debug_value %3, var, name "result""#,
  "debug_value %3, let, name result",
  localDebug ++ ", unknown_attribute",
  localDebug ++ ", argno",
  localDebug ++ ", argno 1, argno 2",
  localDebug ++ ", return %0",
  localDebug ++ "\n  unknown_operation %3"
]

def rejected (debug : String) : Bool :=
  match SILInput.readChunks (input debug) symbol with
  | .error _ => true
  | .ok _ => false

set_option maxRecDepth 8192 in
set_option maxHeartbeats 4000000 in
theorem rejectsUnsupportedDebugForms : unsupported.all rejected = true := by decide +kernel

#print axioms acceptsParameterDebug
#print axioms acceptsLocalDebug
#print axioms acceptsLocatedLocalDebug
#print axioms returnsActualOperand
#print axioms rejectsUnsupportedDebugForms
end LocalDebugTests
