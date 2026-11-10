namespace ReferenceIR

def Fits (value : Int) : Prop :=
  -9223372036854775808 <= value /\ value <= 9223372036854775807

instance (value : Int) : Decidable (Fits value) :=
  inferInstanceAs (Decidable (_ /\ _))

def wrap64 (value : Int) : Int :=
  (value + 9223372036854775808) % 18446744073709551616 - 9223372036854775808

theorem wrap64_of_fits (value : Int) (h : Fits value) : wrap64 value = value := by
  unfold Fits at h
  unfold wrap64
  omega

inductive Value where
  | boxed (value : Int)
  | word (value : Int)
  | bit (value : Bool)
  | pair (partialValue : Int) (overflow : Bool)
  deriving DecidableEq

inductive Operation where
  | literal (value : Int)
  | bit (value : Bool)
  | unbox (operand : Nat)
  | box (operand : Nat)
  | lessThan (left right : Nat)
  | add (left right flag : Nat)
  | subtract (left right flag : Nat)
  | project (operand index : Nat)

structure Edge where
  block : Nat
  arguments : List Nat

inductive Instruction where
  | assign (result : Nat) (operation : Operation)
  | debug
  | trap (flag : Nat)
  | branch (edge : Edge)
  | conditional (condition : Nat) (yes no : Edge)
  | returned (operand : Nat)

structure Block where
  parameters : List Nat
  instructions : List Instruction

abbrev Program := List (Prod Nat Block)
abbrev Environment := List (Prod Nat Value)

inductive Outcome where
  | returned (value : Int)
  | arithmeticTrap
  | invalidIR
  | exhausted
  deriving DecidableEq

def lookup (environment : Environment) (id : Nat) : Option Value :=
  match environment with
  | [] => none
  | (key, value) :: rest => if key == id then some value else lookup rest id

def findBlock (program : Program) (id : Nat) : Option Block :=
  match program with
  | [] => none
  | (key, block) :: rest => if key == id then some block else findBlock rest id

def bind (parameters : List Nat) (values : List Value)
    (environment : Environment) : Option Environment :=
  match parameters, values with
  | [], [] => some environment
  | parameter :: rest, value :: remaining =>
    bind rest remaining ((parameter, value) :: environment)
  | _, _ => none

def arguments (environment : Environment) (ids : List Nat) : Option (List Value) :=
  match ids with
  | [] => some []
  | id :: rest => do
    let value <- lookup environment id
    let remaining <- arguments environment rest
    pure (value :: remaining)

def jump (program : Program) (environment : Environment)
    (edge : Edge) : Option (Prod Environment (List Instruction)) := do
  let block <- findBlock program edge.block
  let values <- arguments environment edge.arguments
  let next <- bind block.parameters values environment
  pure (next, block.instructions)

def arithmetic (environment : Environment) (left right flag : Nat)
    (operation : Int -> Int -> Int) : Option Value :=
  match lookup environment left, lookup environment right, lookup environment flag with
  | some (.word a), some (.word b), some (.bit true) =>
    let value := operation a b
    some (.pair (wrap64 value) (!decide (Fits value)))
  | _, _, _ => none

def evaluate (environment : Environment) (operation : Operation) : Option Value :=
  match operation with
  | .literal value => some (.word value)
  | .bit value => some (.bit value)
  | .unbox operand =>
    match lookup environment operand with
    | some (.boxed value) => some (.word value)
    | _ => none
  | .box operand =>
    match lookup environment operand with
    | some (.word value) => some (.boxed value)
    | _ => none
  | .lessThan left right =>
    match lookup environment left, lookup environment right with
    | some (.word a), some (.word b) => some (.bit (decide (a < b)))
    | _, _ => none
  | .add left right flag => arithmetic environment left right flag (fun a b => a + b)
  | .subtract left right flag => arithmetic environment left right flag (fun a b => a - b)
  | .project operand index =>
    match lookup environment operand with
    | some (.pair value overflow) =>
      if index == 0 then some (.word value)
      else if index == 1 then some (.bit overflow)
      else none
    | _ => none

def run : Nat -> Program -> Environment -> List Instruction -> Outcome
  | 0, _, _, _ => .exhausted
  | _ + 1, _, _, [] => .invalidIR
  | fuel + 1, program, environment, instruction :: remaining =>
    match instruction with
    | .debug => run fuel program environment remaining
    | .assign result operation =>
      match evaluate environment operation with
      | some value => run fuel program ((result, value) :: environment) remaining
      | none => .invalidIR
    | .trap flag =>
      match lookup environment flag with
      | some (.bit overflow) =>
        if overflow then .arithmeticTrap else run fuel program environment remaining
      | _ => .invalidIR
    | .branch edge =>
      match jump program environment edge with
      | some (next, code) => run fuel program next code
      | none => .invalidIR
    | .conditional condition yes no =>
      match lookup environment condition with
      | some (.bit value) =>
        match jump program environment (if value then yes else no) with
        | some (next, code) => run fuel program next code
        | none => .invalidIR
      | _ => .invalidIR
    | .returned operand =>
      match lookup environment operand with
      | some (.boxed value) => .returned value
      | _ => .invalidIR

def execute (fuel : Nat) (program : Program) (subtotal discount : Int) : Outcome :=
  match findBlock program 0 with
  | none => .invalidIR
  | some entry =>
    match bind entry.parameters [.boxed subtotal, .boxed discount] [] with
    | none => .invalidIR
    | some environment => run fuel program environment entry.instructions

end ReferenceIR
