#!/bin/sh
# usage: visitor-churn.sh DIR  -- for each reader instruction, fingerprint the SILPrinter visit<Id> body per ref
# (whitespace-normalised); prints the refs at which the body changed. Shared helpers (operand printing,
# alloc_ref base, function headers) are NOT covered: pair this with format-tokens.py.
DIR=$1; S=$DIR/scripts; REFS="swift-6.0-RELEASE swift-6.1-RELEASE swift-6.2-RELEASE swift-6.3-RELEASE swift-6.4.0-RELEASE main"
python3 -I $S/extract-sil-vocab.py --json $DIR/dl/main/include/swift/SIL/SILNodes.def $DIR/dl/main/include/swift/AST/Builtins.def > $DIR/out/vocab-main.json
for name in debug_value debug_step dealloc_stack destroy_addr end_access strong_release fix_lifetime dealloc_ref dealloc_stack_ref retain_value release_value strong_retain begin_apply end_apply abort_apply begin_cow_mutation end_cow_mutation begin_dealloc_ref cond_fail store load string_literal struct builtin integer_literal metatype tuple struct_extract struct_element_addr tuple_extract tuple_element_addr function_ref apply alloc_stack begin_access upcast unchecked_ref_cast alloc_ref global_value ref_tail_addr index_addr ref_element_addr thin_to_thick_function partial_apply convert_function convert_escape_to_noescape mark_dependence enum unchecked_enum_data select_enum select_enum_addr init_enum_data_addr unchecked_take_enum_data_addr unchecked_inplace_enum_data_addr inject_enum_addr copy_addr switch_enum switch_enum_addr br cond_br return unreachable; do
  id=$(python3 -I -c 'import json,sys; d=json.load(open(sys.argv[1]))["instructions"]; print(d[sys.argv[2]]["id"])' $DIR/out/vocab-main.json $name)
  line="$name ($id):"; prev=""; changes=""
  for r in $REFS; do
    h=$(python3 -I $S/cfunc.py $DIR/dl/$r/lib/SIL/IR/SILPrinter.cpp "visit$id" 2>/dev/null | sed 's/^[0-9]*: //' | tr -d ' \t' | md5 | cut -c1-6)
    [ -n "$prev" ] && [ "$h" != "$prev" ] && changes="$changes ->$r"
    prev=$h
  done
  echo "$line${changes:- unchanged}"
done
# Shared helpers that shape many instructions' text.
for fn in 'SILPrinter &operator<<(SILValuePrinterInfo i)' needPrintTypeFor printAllocRefInstBase printValueDecl 'SILFunction::print' 'SILGlobalVariable::print' 'SILWitnessTable::print' 'SILWitnessTable::Entry::print' printDebugLocRef printDebugScopeRef printDebugVar printBranchArgs printSILFunctionNameAndType; do
  prev=""; changes=""
  for r in $REFS; do
    h=$(python3 -I $S/cfunc.py $DIR/dl/$r/lib/SIL/IR/SILPrinter.cpp "$fn" 2>/dev/null | sed 's/^[0-9]*: //' | tr -d ' \t' | md5 | cut -c1-6)
    [ -n "$prev" ] && [ "$h" != "$prev" ] && changes="$changes ->$r"
    prev=$h
  done
  echo "helper $fn:${changes:- unchanged}"
done
