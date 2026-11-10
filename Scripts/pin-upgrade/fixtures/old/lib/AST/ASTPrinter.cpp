// Excerpt of lib/AST/ASTPrinter.cpp at swift-6.3-RELEASE (see Scripts/pin-upgrade/fixtures/README.md).
void printFunctionExtInfo(SILFunctionType *fnType) { /* elided */ }

StringRef swift::getStringForParameterConvention(ParameterConvention conv) {
  switch (conv) {
  case ParameterConvention::Indirect_In: return "@in ";
  case ParameterConvention::Indirect_In_Guaranteed:  return "@in_guaranteed ";
  case ParameterConvention::Indirect_Inout: return "@inout ";
  case ParameterConvention::Indirect_InoutAliasable: return "@inout_aliasable ";
  case ParameterConvention::Direct_Owned: return "@owned ";
  case ParameterConvention::Direct_Unowned: return "";
  case ParameterConvention::Direct_Guaranteed: return "@guaranteed ";
  }
  llvm_unreachable("bad parameter convention");
}

static StringRef getStringForResultConvention(ResultConvention conv) { /* elided */ }
