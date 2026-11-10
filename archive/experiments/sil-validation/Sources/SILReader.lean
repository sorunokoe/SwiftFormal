deriving instance DecidableEq for ReferenceIR.Operation
deriving instance DecidableEq for ReferenceIR.Edge
deriving instance DecidableEq for ReferenceIR.Instruction
deriving instance DecidableEq for ReferenceIR.Block
deriving instance DecidableEq for Except

namespace SILInput

open ReferenceIR

private def characters (text : String) : List Char :=
  text.toByteArray.data.toList.map (fun byte => Char.ofNat byte.toNat)

private def begins : List Char -> List Char -> Bool
  | [], _ => true
  | a :: rest, b :: tail => a == b && begins rest tail
  | _, _ => false

private def starts (text stem : String) : Bool := begins (characters stem) (characters text)

private def separator (c : Char) : Bool :=
  c.isWhitespace || ['(', ')', '{', '}', '[', ']', ',', ':', '=', '"', '/'].contains c

private def quoted : List Char -> List Char -> Except String (Prod String (List Char))
  | [], _ => .error "Unterminated quoted token"
  | '"' :: rest, accumulated => .ok (String.ofList accumulated.reverse, rest)
  | '\\' :: escaped :: rest, accumulated => quoted rest (escaped :: '\\' :: accumulated)
  | c :: rest, accumulated => quoted rest (c :: accumulated)

private def atom : List Char -> List Char -> Prod String (List Char)
  | [], accumulated => (String.ofList accumulated.reverse, [])
  | c :: rest, accumulated =>
    if separator c then (String.ofList accumulated.reverse, c :: rest)
    else atom rest (c :: accumulated)

private def tokenize : Nat -> List Char -> List String -> Except String (List String)
  | 0, _, _ => .error "Token budget exhausted"
  | _ + 1, [], accumulated => .ok accumulated.reverse
  | _ + 1, '/' :: '/' :: _, accumulated => .ok accumulated.reverse
  | fuel + 1, '"' :: rest, accumulated => do
    let (text, remaining) <- quoted rest []
    tokenize fuel remaining (("\"" ++ text ++ "\"") :: accumulated)
  | fuel + 1, c :: rest, accumulated =>
    if c.isWhitespace then tokenize fuel rest accumulated
    else if separator c then tokenize fuel rest (String.singleton c :: accumulated)
    else
      let (text, remaining) := atom (c :: rest) []
      tokenize fuel remaining (text :: accumulated)

private def digits : List Char -> Nat -> Except String Nat
  | [], value => .ok value
  | c :: rest, value =>
    if 48 <= c.toNat && c.toNat <= 57 then digits rest (value * 10 + c.toNat - 48)
    else .error "Expected decimal digits"

private def natural (text : String) : Except String Nat :=
  match characters text with
  | [] => .error "Expected a natural number"
  | '0' :: _ :: _ => .error "Noncanonical natural number"
  | characters => digits characters 0

private def integer (text : String) : Except String Int := do
  match characters text with
  | '-' :: rest => pure (-Int.ofNat (<- natural (String.ofList rest)))
  | _ => pure (Int.ofNat (<- natural text))

private def identifier (stem text : String) : Except String Nat :=
  if starts text stem then natural (String.ofList ((characters text).drop stem.utf8ByteSize))
  else .error ("Expected identifier prefix " ++ stem)

private def register (text : String) := identifier "%" text

private def isQuoted (text : String) : Bool :=
  text.utf8ByteSize >= 2 && begins ['"'] (characters text) && begins ['"'] (characters text).reverse

private def metadata (tokens : List String) : Except String Unit := do
  match tokens with
  | [] => pure ()
  | [",", "scope", scope] => let _ <- natural scope; pure ()
  | "," :: "loc" :: file :: ":" :: line :: ":" :: column :: rest =>
    unless isQuoted file do throw "Expected a quoted source location"
    let _ <- natural line
    let _ <- natural column
    match rest with
    | [] => pure ()
    | [",", "scope", scope] => let _ <- natural scope; pure ()
    | _ => throw "Unsupported location suffix"
  | _ => throw ("Unsupported instruction suffix: " ++ toString tokens)

private def arguments : List String -> Except String (Prod (List Nat) (List String))
  | ")" :: rest => .ok ([], rest)
  | operand :: "," :: rest => do
    let id <- register operand
    let (remaining, tail) <- arguments rest
    unless !remaining.isEmpty do throw "Trailing argument comma"
    pure (id :: remaining, tail)
  | operand :: ")" :: rest => do pure ([<- register operand], rest)
  | _ => .error "Malformed argument list"

private def edge : List String -> Except String (Prod Edge (List String))
  | block :: "(" :: rest => do
    let id <- identifier "bb" block
    let (values, tail) <- arguments rest
    pure ({ block := id, arguments := values }, tail)
  | block :: rest => do pure ({ block := <- identifier "bb" block, arguments := [] }, rest)
  | [] => .error "Missing branch destination"

private def parameters : List String ->
    Except String (Prod (List (Prod Nat String)) (List String))
  | ")" :: rest => .ok ([], rest)
  | operand :: ":" :: type :: rest => do
    let id <- register operand
    unless ["$Int64", "$Builtin.Int64", "$Builtin.Int1"].contains type do
      throw "Unsupported block parameter type"
    match rest with
    | ")" :: tail => pure ([(id, type)], tail)
    | "," :: tail =>
      let (remaining, suffix) <- parameters tail
      unless !remaining.isEmpty do throw "Trailing parameter comma"
      pure ((id, type) :: remaining, suffix)
    | _ => throw "Malformed block parameters"
  | _ => .error "Malformed block parameters"

private def blockHeader (tokens : List String) : Except String (Prod Nat Block) := do
  let (name, values) <- match tokens with
    | [name, ":"] => pure (name, [])
    | name :: "(" :: rest => do
      let (values, tail) <- parameters rest
      unless tail == [":"] do throw "Unexpected block header suffix"
      pure (name, values)
    | _ => throw "Malformed block header"
  let id <- identifier "bb" name
  if id == 0 then
    unless values.map Prod.snd == ["$Int64", "$Int64"] do throw "Invalid entry parameters"
  let ids := values.map Prod.fst
  unless ids.eraseDups.length == ids.length do throw "Duplicate block parameter"
  pure (id, { parameters := ids, instructions := [] })

private def assignment (tokens : List String) : Except String Operation := do
  match tokens with
  | "integer_literal" :: type :: "," :: value :: rest =>
    metadata rest
    if type == "$Builtin.Int1" then
      match value with
      | "-1" => pure (.bit true)
      | "0" => pure (.bit false)
      | _ => throw "Unsupported bit literal"
    else if type == "$Builtin.Int64" then
      let number <- integer value
      unless decide (ReferenceIR.Fits number) do throw "Int64 literal out of range"
      pure (.literal number)
    else throw "Unsupported literal type"
  | "struct_extract" :: operand :: "," :: "#Int64._value" :: rest =>
    metadata rest
    pure (.unbox (<- register operand))
  | "struct" :: "$Int64" :: "(" :: operand :: ")" :: rest =>
    metadata rest
    pure (.box (<- register operand))
  | "tuple_extract" :: operand :: "," :: projection :: rest =>
    metadata rest
    let index <- natural projection
    unless index < 2 do throw "Unsupported tuple projection"
    pure (.project (<- register operand) index)
  | "builtin" :: name :: "(" :: rest =>
    let (operands, tail) <- arguments rest
    match name, operands, tail with
    | "\"cmp_slt_Int64\"", [left, right], ":" :: "$Builtin.Int1" :: suffix =>
      metadata suffix
      pure (.lessThan left right)
    | "\"sadd_with_overflow_Int64\"", [left, right, flag],
        ":" :: "$" :: "(" :: "Builtin.Int64" :: "," :: "Builtin.Int1" :: ")" :: suffix =>
      metadata suffix
      pure (.add left right flag)
    | "\"ssub_with_overflow_Int64\"", [left, right, flag],
        ":" :: "$" :: "(" :: "Builtin.Int64" :: "," :: "Builtin.Int1" :: ")" :: suffix =>
      metadata suffix
      pure (.subtract left right flag)
    | _, _, _ => throw "Unsupported builtin, arity, or result type"
  | _ => throw ("Unsupported value instruction: " ++ toString tokens)

private def instruction (tokens : List String) : Except String Instruction := do
  match tokens with
  | "debug_value" :: operand :: "," :: "let" :: "," :: "name" :: name :: rest =>
    let _ <- register operand
    unless isQuoted name do throw "Expected a quoted debug name"
    match rest with
    | "," :: "argno" :: argument :: suffix =>
      let _ <- natural argument
      metadata suffix
    | _ => metadata rest
    pure .debug
  | "cond_fail" :: flag :: "," :: "\"arithmetic overflow\"" :: rest =>
    metadata rest
    pure (.trap (<- register flag))
  | "br" :: rest =>
    let (destination, suffix) <- edge rest
    metadata suffix
    pure (.branch destination)
  | "cond_br" :: condition :: "," :: rest =>
    let (yes, tail) <- edge rest
    match tail with
    | "," :: remaining =>
      let (no, suffix) <- edge remaining
      metadata suffix
      pure (.conditional (<- register condition) yes no)
    | _ => throw "Missing conditional branch destination"
  | "return" :: operand :: rest =>
    metadata rest
    pure (.returned (<- register operand))
  | result :: "=" :: rest => pure (.assign (<- register result) (<- assignment rest))
  | _ => throw ("Unsupported executable line: " ++ toString tokens)

private def isTerminator : Instruction -> Bool
  | .branch _ | .conditional _ _ _ | .returned _ => true
  | _ => false

private def completeBlock (block : Block) : Except String Unit :=
  match block.instructions.getLast? with
  | some value => if isTerminator value then .ok () else .error "Missing terminator"
  | none => .error "Empty block"

private def braces (initial : Nat) (tokens : List String) : Except String Nat :=
  tokens.foldlM (fun depth token =>
    if token == "{" then pure (depth + 1)
    else if token == "}" then
      if depth == 0 then throw "Unbalanced closing brace" else pure (depth - 1)
    else pure depth) initial

structure State where
  stageSeen : Bool := false
  byteCount : Nat := 0
  pending : List UInt8 := []
  depth : Nat := 0
  active : Bool := false
  result : Option Program := none
  finished : Program := []
  current : Option (Prod Nat Block) := none
  deriving DecidableEq

private def flush (state : State) : Except String Program := do
  match state.current with
  | none => throw "Missing selected function block"
  | some (id, block) =>
    completeBlock block
    pure ((id, block) :: state.finished)

private def skipQuoted : List Char -> Except String (List Char)
  | [] => .error "Unterminated quoted token"
  | '"' :: rest => .ok rest
  | '\\' :: _ :: rest => skipQuoted rest
  | _ :: rest => skipQuoted rest

private def scanBraces : Nat -> Nat -> List Char -> Except String Nat
  | 0, _, _ => .error "Brace scan budget exhausted"
  | _ + 1, depth, [] => .ok depth
  | _ + 1, depth, '/' :: '/' :: _ => .ok depth
  | fuel + 1, depth, '"' :: rest => do scanBraces fuel depth (<- skipQuoted rest)
  | fuel + 1, depth, '{' :: rest => scanBraces fuel (depth + 1) rest
  | _ + 1, 0, '}' :: _ => .error "Unbalanced closing brace"
  | fuel + 1, depth + 1, '}' :: rest => scanBraces fuel depth rest
  | fuel + 1, depth, _ :: rest => scanBraces fuel depth rest

private def beginsWord : List Char -> List Char -> Bool
  | [], [] => true
  | [], c :: _ => separator c
  | a :: word, b :: line => a == b && beginsWord word line
  | _, _ => false

private def consume (symbol : String) (state : State) (line : List UInt8) : Except String State := do
  unless line.length <= 4096 do throw "Line exceeds the experiment limit"
  let chars := line.map (fun byte => Char.ofNat byte.toNat)
  let head := chars.dropWhile Char.isWhitespace
  if state.stageSeen && !state.active &&
      !beginsWord (characters "sil") head && !beginsWord (characters "sil_stage") head then
    let depth <- scanBraces (line.length + 1) state.depth chars
    return { state with depth := depth }
  if line.any (fun byte => byte.toNat >= 128) then throw "Selected SIL syntax must be ASCII"
  let tokens <- tokenize (line.length + 1) chars []
  if !state.stageSeen then
    unless tokens == ["sil_stage", "canonical"] do throw "Expected canonical SIL"
    return { state with stageSeen := true }
  if tokens.isEmpty then return state
  let depth <- braces state.depth tokens
  if state.active then
    if tokens == ["}"] then
      unless state.depth == 1 && depth == 0 do throw "Invalid function closing brace"
      let blocks <- flush state
      return { state with depth := depth, active := false, result := some blocks.reverse, finished := [], current := none }
    if starts (tokens.headD "") "bb" then
      let (id, block) <- blockHeader tokens
      let finished <- match state.current with
        | none =>
          unless id == 0 do throw "First block must be bb0"
          pure state.finished
        | some _ => flush state
      unless !(finished.map Prod.fst).contains id do throw "Duplicate block"
      return { state with depth := depth, current := some (id, block), finished := finished }
    let operation <- instruction tokens
    match state.current with
    | none => throw "Instruction outside a block"
    | some (id, block) =>
      if block.instructions.getLast?.any isTerminator then throw "Instruction after terminator"
      let next := { block with instructions := block.instructions ++ [operation] }
      return { state with depth := depth, current := some (id, next) }
  else if tokens.head? == some "sil" && tokens.contains ("@" ++ symbol) then
    unless state.depth == 0 && state.result.isNone do throw "Duplicate or nested selected function"
    unless tokens == ["sil", "@" ++ symbol, ":", "$@convention", "(", "thin", ")",
      "(", "Int64", ",", "Int64", ")", "->", "Int64", "{"] do
      throw "Unsupported selected function signature"
    return { state with depth := depth, active := true }
  else if tokens.head? == some "sil_stage" then
    throw "Duplicate SIL stage"
  else
    return { state with depth := depth }

private def feed (symbol : String) : State -> List UInt8 -> Nat -> List UInt8 -> Except String State
  | state, current, _, [] => .ok { state with pending := current }
  | state, current, _, 10 :: rest => do
    let next <- consume symbol state current.reverse
    feed symbol next [] 0 rest
  | state, current, length, byte :: rest =>
    if length >= 4096 then .error "Line exceeds the experiment limit"
    else feed symbol state (byte :: current) (length + 1) rest

def step (symbol : String) (state : State) (chunk : List UInt8) : Except String State := do
  let bytes := state.byteCount + chunk.length
  unless bytes <= 262144 do throw "SIL exceeds the experiment limit"
  feed symbol { state with byteCount := bytes } state.pending state.pending.length chunk

def finish (state : State) : Except String Program := do
  unless state.stageSeen do throw "Missing SIL stage"
  unless state.depth == 0 && !state.active do throw "Unclosed function or declaration"
  match state.result with
  | some program => pure program
  | none => throw "Selected symbol is missing"

-- Rewrite the checked decoding theorem rather than rerunning the whole reader during elaboration.
@[irreducible] def readChunks (chunks : List (List UInt8)) (symbol : String) : Except String Program := do
  let state <- chunks.foldlM (step symbol) {}
  let final <- if state.pending.isEmpty then pure state else consume symbol state state.pending.reverse
  finish final

theorem bind_ok {A B : Type} (value : A) (next : A -> Except String B) :
    (Except.ok value >>= next) = next value := rfl

theorem checked_cons (symbol : String) (initial next final : State)
    (chunk : List UInt8) (rest : List (List UInt8))
    (first : step symbol initial chunk = .ok next)
    (remaining : rest.foldlM (step symbol) next = .ok final) :
    (chunk :: rest).foldlM (step symbol) initial = .ok final := by
  simp only [List.foldlM_cons, first, bind_ok, remaining]

def executeChunks (fuel : Nat) (chunks : List (List UInt8)) (symbol : String)
    (subtotal discount : Int) : Outcome :=
  match readChunks chunks symbol with
  | .ok program => ReferenceIR.execute fuel program subtotal discount
  | .error _ => .invalidIR

end SILInput
