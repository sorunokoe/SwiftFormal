deriving instance Lean.ToExpr for ReferenceIR.Operation
deriving instance Lean.ToExpr for ReferenceIR.Edge
deriving instance Lean.ToExpr for ReferenceIR.Instruction
deriving instance Lean.ToExpr for ReferenceIR.Block
deriving instance Lean.ToExpr for SILInput.State

syntax (name := proposedState) "proposed_state% " term : term

-- Only proposes data. A separate kernel proof must check every transition.
@[term_elab proposedState] unsafe def elaborateProposedState : Lean.Elab.Term.TermElab := fun stx _ => do
  let type := Lean.mkApp2 (Lean.mkConst ``Except [Lean.Level.zero, Lean.Level.zero])
    (Lean.mkConst ``String) (Lean.mkConst ``SILInput.State)
  let expression <- Lean.Elab.Term.elabTermAndSynthesize stx[1] (some type)
  match <- Lean.Meta.evalExpr (Except String SILInput.State) type expression with
  | .error message => throwError "Reader proposal failed: {message}"
  | .ok state => return Lean.toExpr state
