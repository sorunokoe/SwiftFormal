// Excerpt of lib/SIL/IR/SILPrinter.cpp at swift-6.3-RELEASE (see Scripts/pin-upgrade/fixtures/README.md).
// Long helpers are reduced to their signature: the self-test needs them to exist, not their bodies.

class SILPrinter : public SILInstructionVisitor<SILPrinter> {
  void printSILArgument(const SILArgument *arg) { /* elided */ }
  void print(const SILBasicBlock *BB) { /* elided */ }
  void printInstOpCode(const SILInstruction *I) { /* elided */ }
  void print(const SILInstruction *I) { /* elided */ }
  SILPrinter &operator<<(SILValuePrinterInfo i) { /* elided */ }

  bool needPrintTypeFor(SILValue V) {
    if (SILPrintTypes)
      return true;

    if (!V)
      return false;

    if (isa<SILUndef>(V))
      return true;

    // Make sure to print the type if the operand's definition was not printed so far
    return printedBlocks.count(V->getParentBlock()) == 0;
  }

  void printDebugLocRef(SILLocation Loc, const SourceManager &SM, bool PrintComma = true) { /* elided */ }
  void printDebugScopeRef(const SILDebugScope *DS, const SourceManager &SM, bool PrintComma = true) { /* elided */ }
  void printDebugVar(std::optional<SILDebugVariable> Var, const SourceManager *SM = nullptr) { /* elided */ }

  void printAllocRefInstBase(AllocRefInstBase *ARI) {
    if (ARI->isObjC())
      *this << "[objc] ";
    if (ARI->canAllocOnStack())
      *this << "[stack] ";
    auto Types = ARI->getTailAllocatedTypes();
    auto Counts = ARI->getTailAllocatedCounts();
    for (unsigned Idx = 0, NumTypes = Types.size(); Idx < NumTypes; ++Idx) {
      *this << "[tail_elems " << Types[Idx] << " * "
            << getIDAndType(Counts[Idx].get()) << "] ";
    }
  }

  void visitDebugValueInst(DebugValueInst *DVI) {
    if (DVI->poisonRefs())
      *this << "[poison] ";
    if (DVI->hasTrace())
      *this << "[trace] ";
    *this << getIDAndType(DVI->getOperand());
    printDebugVar(DVI->getVarInfo(false),
                  &DVI->getModule().getASTContext().SourceMgr);
  }

  void visitUncheckedTakeEnumDataAddrInst(UncheckedTakeEnumDataAddrInst *UDAI) {
    *this << getIDAndType(UDAI->getOperand()) << ", "
          << SILDeclRef(UDAI->getElement(), SILDeclRef::Kind::EnumElement);
  }

  void visitRefCountingInst(RefCountingInst *I) {
    if (I->isNonAtomic())
      *this << "[nonatomic] ";
    *this << getIDAndType(I->getOperand(0));
  }

  void visitReturnInst(ReturnInst *RI) {
    *this << getIDAndType(RI->getOperand());
  }

  void printBranchArgs(OperandValueArrayRef args) {
    if (args.empty()) return;

    *this << '(';
    llvm::interleave(
        args, [&](SILValue v) { *this << getIDAndType(v); },
        [&] { *this << ", "; });
    *this << ')';
  }

  void visitBranchInst(BranchInst *UBI) {
    *this << Ctx.getID(UBI->getDestBB());
    printBranchArgs(UBI->getArgs());
  }

  void visitCondBranchInst(CondBranchInst *CBI) {
    *this << Ctx.getID(CBI->getCondition()) << ", "
          << Ctx.getID(CBI->getTrueBB());
    printBranchArgs(CBI->getTrueArgs());
    *this << ", " << Ctx.getID(CBI->getFalseBB());
    printBranchArgs(CBI->getFalseArgs());
    if (CBI->getTrueBBCount())
      *this << " !true_count(" << CBI->getTrueBBCount().getValue() << ")";
    if (CBI->getFalseBBCount())
      *this << " !false_count(" << CBI->getFalseBBCount().getValue() << ")";
  }

  void printSILFunctionNameAndType(llvm::raw_ostream &OS, const SILFunction *function) { /* elided */ }
  void printValueDecl(ValueDecl *decl, raw_ostream &OS) { /* elided */ }
};

void SILFunction::print(SILPrintContext &PrintCtx) const { /* elided */ }
void SILGlobalVariable::print(llvm::raw_ostream &OS, bool Verbose) const { /* elided */ }
void SILWitnessTable::print(llvm::raw_ostream &OS, bool Verbose) const { /* elided */ }
void SILWitnessTable::Entry::print(llvm::raw_ostream &out, bool verbose, const PrintOptions &options) const { /* elided */ }
