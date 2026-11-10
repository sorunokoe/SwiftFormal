"""Fixed, small SIL fixtures; never used to select production compiler input."""

from verify import SYMBOL, chunks, quote_lean


HEADER = f"sil @{SYMBOL} : $@convention(thin) (Int64, Int64) -> Int64 {{"
BODY = """bb0(%0 : $Int64, %1 : $Int64):
  debug_value %0, let, name "subtotal", argno 1
  debug_value %1, let, name "discount", argno 2
  %4 = struct_extract %0, #Int64._value
  %5 = struct_extract %1, #Int64._value
  %6 = builtin "cmp_slt_Int64"(%4, %5) : $Builtin.Int1
  cond_br %6, bb1, bb2
bb1:
  %8 = integer_literal $Builtin.Int64, 0
  %9 = struct $Int64 (%8)
  br bb3(%9)
bb2:
  %11 = struct_extract %0, #Int64._value
  %12 = struct_extract %1, #Int64._value
  %13 = integer_literal $Builtin.Int1, -1
  %14 = builtin "ssub_with_overflow_Int64"(%11, %12, %13) : $(Builtin.Int64, Builtin.Int1)
  %15 = tuple_extract %14, 0
  %16 = tuple_extract %14, 1
  cond_fail %16, "arithmetic overflow"
  %18 = struct $Int64 (%15)
  br bb3(%18)
bb3(%20 : $Int64):
  return %20
"""
MODULE = "sil_stage canonical\n" + HEADER + "\n" + BODY + "}\n"


def changed(old, new):
    if old not in MODULE or old == new:
        raise ValueError("Ineffective control mutation")
    return MODULE.replace(old, new, 1)


def inventory():
    positives = {
        "baseline": MODULE,
        "whitespace_and_comments": MODULE.replace("  ", "\t") + "// ignored { \"\n",
        "quoted_metadata": changed("return %20", 'return %20, loc "a//{b}\\\".swift":7:9, scope 1 // }'),
        "symbol_mentions": (
            "sil_stage canonical\n"
            + f"sil_scope 1 {{ parent @{SYMBOL} }}\n"
            + f"// sil @{SYMBOL} {{\n"
            + "sil @other : $@convention(thin) () -> () {\n"
            + f"bb0:\n  %0 = function_ref @{SYMBOL}\n"
            + '  %1 = string_literal utf8 "{//}\\\""\n}\n'
            + MODULE.split("\n", 1)[1]
        ),
        "no_final_newline": MODULE.rstrip("\n"),
    }
    mutations = {
        "swapped_operands": changed('(%11, %12, %13)', '(%12, %11, %13)'),
        "swapped_branches": changed("cond_br %6, bb1, bb2", "cond_br %6, bb2, bb1"),
        "wrong_block_argument": changed("br bb3(%9)", "br bb3(%0)"),
        "addition_not_subtraction": changed("ssub_with_overflow_Int64", "sadd_with_overflow_Int64"),
        "wrong_overflow_projection": changed("%16 = tuple_extract %14, 1", "%16 = tuple_extract %14, 0"),
        "wrong_trap_operand": changed("cond_fail %16", "cond_fail %13"),
        "missing_trap": changed('  cond_fail %16, "arithmetic overflow"\n', ""),
    }
    rejected = {
        "unknown_instruction": changed("  return %20", "  retain_value %20\n  return %20"),
        "unknown_builtin": changed("ssub_with_overflow_Int64", "smul_with_overflow_Int64"),
        "unknown_type": changed("%8 = integer_literal $Builtin.Int64", "%8 = integer_literal $Builtin.Int32"),
        "wrong_signature": changed("(Int64, Int64) -> Int64", "(Int64, Int64) -> Int32"),
        "wrong_stage": changed("sil_stage canonical", "sil_stage raw"),
        "duplicate_stage": MODULE + "sil_stage canonical\n",
        "missing_symbol": changed("@" + SYMBOL, "@other"),
        "duplicate_symbol": MODULE + MODULE.split("\n", 1)[1],
        "nested_symbol": "sil_stage canonical\nstruct Outer {\n" + MODULE.split("\n", 1)[1] + "}\n",
        "unbalanced_declaration": MODULE + "struct Unclosed {\n",
        "missing_terminator": changed("  return %20\n", ""),
        "instruction_after_terminator": changed("  return %20", "  return %20\n  %21 = integer_literal $Builtin.Int64, 0"),
        "invalid_suffix": changed("  return %20", "  return %20, unknown_attribute"),
        "malformed_quote": changed('name "subtotal"', 'name "subtotal'),
        "noncanonical_identifier": changed("%4 = struct_extract %0", "%04 = struct_extract %0"),
        "duplicate_block": changed("bb2:", "bb1:"),
        "unsupported_projection": changed("%16 = tuple_extract %14, 1", "%16 = tuple_extract %14, 2"),
        "out_of_range_literal": changed("$Builtin.Int64, 0", "$Builtin.Int64, 9223372036854775808"),
    }
    return {"positive": positives, "changed": mutations, "rejected": rejected}


def render(group, cases, reference, reader, program):
    prefix = f"""import Lean
{reference}
{reader}
namespace ReaderControls
{program}
def symbol : String := {quote_lean(SYMBOL)}
def changedSuccessfully (input : List (List UInt8)) : Bool :=
  match SILInput.readChunks input symbol with
  | .ok decoded => decide (Not (decoded = program))
  | .error _ => false
def rejected (input : List (List UInt8)) : Bool :=
  match SILInput.readChunks input symbol with
  | .ok _ => false
  | .error _ => true
"""
    names = []
    for name, text in cases.items():
        data = ", ".join("[" + ", ".join(map(str, part)) + "]" for part in chunks(text.encode()))
        expression = {
            "positive": f"SILInput.readChunks {name}Input symbol = Except.ok program",
            "changed": f"changedSuccessfully {name}Input = true",
            "rejected": f"rejected {name}Input = true",
        }[group]
        prefix += f"""
def {name}Input : List (List UInt8) := [{data}]
set_option maxRecDepth 8192 in
set_option maxHeartbeats 4000000 in
theorem {name} : {expression} := by decide +kernel
#print axioms ReaderControls.{name}
"""
        names.append(f"ReaderControls.{name}")
    return prefix + "\nend ReaderControls\n", names
